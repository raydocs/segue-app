import Darwin
import Foundation

/// One request, one reply, on the helper's unix socket.
///
/// Production connects to `SeguePaths.helperSocketPath`. Tests pass a
/// socketpair or a socket in a temp directory. One transaction is in flight
/// per socket value; callers that share a connection serialize themselves.
public protocol HelperSocket: Sendable {
    func transact(_ request: Data) async throws -> Data
}

public enum HelperSocketFailure: Error, Equatable {
    case notInstalled
    case accessDenied
    case closed
    case timedOut
    case failed
}

enum HelperLineIO {
    static let maxBytes = 64 * 1024

    static func readLine(fd: Int32, limit: Int = maxBytes) throws -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 {
                if data.isEmpty {
                    return nil
                }
                return data
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                    throw HelperSocketFailure.timedOut
                }
                throw HelperSocketFailure.failed
            }
            if byte == 0x0A {
                if data.last == 0x0D {
                    data.removeLast()
                }
                return data
            }
            if data.count >= limit {
                throw HelperSocketFailure.failed
            }
            data.append(byte)
        }
    }

    static func writeLine(fd: Int32, _ payload: Data) throws {
        var bytes = payload
        if bytes.last != 0x0A {
            bytes.append(0x0A)
        }
        try writeAll(fd, bytes)
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw HelperSocketFailure.failed
                }
                if count == 0 {
                    throw HelperSocketFailure.closed
                }
                sent += count
            }
        }
    }
}

/// Connects to a filesystem unix socket, exchanges one line, and closes.
public final class UnixHelperSocket: HelperSocket, @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "segue.helper.socket")

    public init(path: String) {
        self.path = path
    }

    public func transact(_ request: Data) async throws -> Data {
        let path = self.path
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let reply = try UnixHelperSocket.exchange(path: path, request: request)
                    continuation.resume(returning: reply)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func exchange(path: String, request: Data) throws -> Data {
        try requireSocketPath(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HelperSocketFailure.failed
        }
        defer { _ = Darwin.close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var noSignal: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )
        setTimeout(fd, seconds: 3)
        try connect(fd, path: path)
        try HelperLineIO.writeLine(fd: fd, request)
        guard let line = try HelperLineIO.readLine(fd: fd) else {
            throw HelperSocketFailure.closed
        }
        return line
    }

    private static func requireSocketPath(_ path: String) throws {
        var info = stat()
        let result = path.withCString { stat($0, &info) }
        if result == 0 {
            return
        }
        switch errno {
        case EACCES, EPERM:
            throw HelperSocketFailure.accessDenied
        default:
            throw HelperSocketFailure.notInstalled
        }
    }

    private static func connect(_ fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            throw HelperSocketFailure.failed
        }
        path.withCString { cString in
            withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
                pathPointer.withMemoryRebound(to: CChar.self, capacity: capacity) { dest in
                    _ = strncpy(dest, cString, capacity - 1)
                    dest[capacity - 1] = 0
                }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                Darwin.connect(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            return
        }
        switch errno {
        case ENOENT, ECONNREFUSED, ENOTSOCK, ENOTDIR, ECONNRESET:
            throw HelperSocketFailure.notInstalled
        case EACCES, EPERM:
            throw HelperSocketFailure.accessDenied
        case EAGAIN, EWOULDBLOCK, ETIMEDOUT:
            throw HelperSocketFailure.timedOut
        default:
            throw HelperSocketFailure.failed
        }
    }

    private static func setTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// An already-connected descriptor, such as one end of a socketpair.
final class DescriptorHelperSocket: HelperSocket, @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "segue.helper.fd")

    init(fd: Int32) {
        self.fd = fd
    }

    func transact(_ request: Data) async throws -> Data {
        let fd = self.fd
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try HelperLineIO.writeLine(fd: fd, request)
                    guard let line = try HelperLineIO.readLine(fd: fd) else {
                        throw HelperSocketFailure.closed
                    }
                    continuation.resume(returning: line)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
