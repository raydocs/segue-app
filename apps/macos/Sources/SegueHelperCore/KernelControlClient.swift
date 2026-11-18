import Darwin
import Foundation

/// What `GET /v1/status` on the kernel's control API reports. `state` is
/// `connected`, `reconnecting`, or `disconnected`; `tunInterface` is the
/// utun name while one is open, `routes` is `installed` once the split
/// defaults are in (`crates/segue-kernel/src/control.rs`).
public struct KernelControlStatus: Equatable, Sendable {
    public var state: String
    public var tunInterface: String?
    public var routes: String?

    public init(state: String, tunInterface: String? = nil, routes: String? = nil) {
        self.state = state
        self.tunInterface = tunInterface
        self.routes = routes
    }

    /// The kernel's own definition of usable: a carrier session and a
    /// tunnel interface. This is what "connected" means for the helper.
    public var tunnelUp: Bool {
        state == "connected" && tunInterface != nil
    }
}

/// Reads the kernel's control token file (`{"addr": "...", "token": "..."}`,
/// rewritten by every kernel start, mode 0600) and speaks the loopback
/// control API. The token never leaves the helper.
public protocol KernelControlClient: AnyObject {
    /// One `GET /v1/status`. Nil when the token file is missing, the
    /// kernel is not answering, or the reply does not parse.
    func readStatus() -> KernelControlStatus?
    /// Fire-and-forget `POST /v1/connect`: the kernel establishes a
    /// carrier now instead of waiting for the first proxied flow, so
    /// `state` can turn `connected` without traffic.
    func connect()
}

/// TCP client for the loopback control API. One request per connection,
/// `Host: localhost` and a Bearer token, no `Origin` — the kernel refuses
/// anything that looks like a browser or a non-loopback host.
public final class LiveKernelControlClient: KernelControlClient {
    private let tokenFilePath: String
    private let timeout: TimeInterval

    public init(tokenFilePath: String, timeout: TimeInterval = 1) {
        self.tokenFilePath = tokenFilePath
        self.timeout = timeout
    }

    public func readStatus() -> KernelControlStatus? {
        guard let body = call(method: "GET", path: "/v1/status") else { return nil }
        return Self.parseStatus(body)
    }

    public func connect() {
        _ = call(method: "POST", path: "/v1/connect")
    }

    // MARK: - request

    private func call(method: String, path: String) -> [String: Any]? {
        guard let token = Self.readToken(path: tokenFilePath) else { return nil }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { _ = Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = token.port.bigEndian
        address.sin_addr = token.address
        setNonBlocking(fd, true)
        let pending = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if pending != 0 {
            guard errno == EINPROGRESS, awaitWritable(fd) else { return nil }
        }
        var pendingError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &pendingError, &length) == 0,
              pendingError == 0
        else { return nil }
        setNonBlocking(fd, false)
        setReceiveTimeout(fd, seconds: Int(timeout.rounded(.up)))
        let head = "\(method) \(path) HTTP/1.1\r\n" +
            "Host: localhost\r\n" +
            "Authorization: Bearer \(token.secret)\r\n" +
            "Connection: close\r\n\r\n"
        guard sendAll(fd, text: head) else { return nil }
        // The kernel answers one request per connection and closes after
        // it, so EOF ends the reply.
        guard let reply = readUntilEOF(fd), reply.status == 200 else { return nil }
        return reply.body
    }

    private func awaitWritable(_ fd: Int32) -> Bool {
        var set = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        return poll(&set, 1, Int32(timeout * 1000)) > 0
    }

    private func sendAll(_ fd: Int32, text: String) -> Bool {
        text.withCString { pointer in
            var sent = 0
            let total = text.utf8.count
            while sent < total {
                let wrote = send(fd, pointer + sent, total - sent, 0)
                guard wrote > 0 else { return false }
                sent += wrote
            }
            return true
        }
    }

    private func readUntilEOF(_ fd: Int32) -> (status: Int, body: [String: Any])? {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let got = recv(fd, &chunk, chunk.count, 0)
            guard got > 0 else { break }
            buffer.append(contentsOf: chunk[0..<got])
            guard buffer.count <= 64 * 1024 else { return nil }
        }
        return Self.parseResponse(buffer)
    }

    // MARK: - parse

    static func parseResponse(_ buffer: [UInt8]) -> (status: Int, body: [String: Any])? {
        guard let text = String(bytes: buffer, encoding: .utf8),
              let split = text.range(of: "\r\n\r\n")
        else { return nil }
        let head = String(text[..<split.lowerBound])
        let bodyText = String(text[split.upperBound...])
        guard let statusLine = head.components(separatedBy: "\r\n").first,
              let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "")
        else { return nil }
        guard let data = bodyText.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return (status, object)
    }

    static func parseStatus(_ body: [String: Any]) -> KernelControlStatus? {
        guard let state = body["state"] as? String else { return nil }
        let tun = body["tun"] as? [String: Any]
        return KernelControlStatus(
            state: state,
            tunInterface: tun?["interface"] as? String,
            routes: tun?["routes"] as? String
        )
    }

    private static func readToken(path: String) -> (address: in_addr, port: UInt16, secret: String)? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let addr = object["addr"] as? String,
              let secret = object["token"] as? String,
              !secret.isEmpty
        else { return nil }
        // "127.0.0.1:PORT" (an "[::1]:PORT" form is tolerated; the config
        // validation only ever allows loopback).
        var host = addr
        var port: UInt16 = 0
        if let open = addr.firstIndex(of: "["), let close = addr.lastIndex(of: "]") {
            host = String(addr[addr.index(after: open)..<close])
            port = UInt16(addr[addr.index(after: close)...].dropFirst()) ?? 0
        } else if let colon = addr.lastIndex(of: ":") {
            host = String(addr[..<colon])
            port = UInt16(addr[addr.index(after: colon)...]) ?? 0
        }
        var address = in_addr()
        guard port > 0, inet_pton(AF_INET, host, &address) == 1 else { return nil }
        return (address, port, secret)
    }
}
