import Darwin
import Foundation

public enum UnixSocketError: Error, Equatable {
    case pathTooLong(Int)
    case notASocket
    case failed(String, Int32)
}

public enum LineIOError: Error, Equatable {
    case read(Int32)
    case write(Int32)
    case timeout
    case tooLong
}

public enum LineIO {
    public static let maxBytes = 64 * 1024

    public static func readLine(fd: Int32, limit: Int = maxBytes) throws -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n == 0 {
                if data.isEmpty { return nil }
                return data
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw LineIOError.timeout
                }
                throw LineIOError.read(errno)
            }
            if byte == 0x0A {
                if data.last == 0x0D { data.removeLast() }
                return data
            }
            if data.count >= limit {
                throw LineIOError.tooLong
            }
            data.append(byte)
        }
    }

    public static func writeLine(fd: Int32, payload: Data) throws {
        var bytes = payload
        bytes.append(0x0A)
        try writeAll(fd, bytes)
    }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw LineIOError.write(errno)
                }
                if n == 0 {
                    throw LineIOError.write(EPIPE)
                }
                sent += n
            }
        }
    }
}

public func unixSocket() throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw UnixSocketError.failed("socket", errno)
    }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var nosig: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout.size(ofValue: nosig)))
    return fd
}

public func setNonBlocking(_ fd: Int32, _ enabled: Bool) {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0 else { return }
    let updated = enabled ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK)
    _ = fcntl(fd, F_SETFL, updated)
}

public func setReceiveTimeout(_ fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

public func bindUnixSocket(fd: Int32, path: String) throws {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
    guard path.utf8.count <= maxLen else {
        throw UnixSocketError.pathTooLong(path.utf8.count)
    }
    let rc: Int32 = path.withCString { cString in
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPointer in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dest in
                _ = strncpy(dest, cString, maxLen)
            }
        }
        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                Darwin.bind(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
    guard rc == 0 else {
        throw UnixSocketError.failed("bind", errno)
    }
}

public func connectUnixSocket(fd: Int32, path: String) throws {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
    guard path.utf8.count <= maxLen else {
        throw UnixSocketError.pathTooLong(path.utf8.count)
    }
    let rc: Int32 = path.withCString { cString in
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPointer in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dest in
                _ = strncpy(dest, cString, maxLen)
            }
        }
        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                Darwin.connect(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
    guard rc == 0 else {
        throw UnixSocketError.failed("connect", errno)
    }
}

public func unlinkSocketFile(_ path: String) throws {
    var info = stat()
    let exists = path.withCString { lstat($0, &info) }
    guard exists == 0 else { return }
    guard (info.st_mode & S_IFMT) == S_IFSOCK else {
        throw UnixSocketError.notASocket
    }
    _ = path.withCString { unlink($0) }
}
