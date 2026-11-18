import Foundation

/// What the menu calls. The kernel client is one implementation; a helper
/// client can replace it later without the buttons knowing.
public protocol ControlClient: Sendable {
    func status() async throws -> KernelStatus
    func connect() async throws -> KernelStatus
    func disconnect() async throws -> KernelStatus
    func selectExit(_ exit: String) async throws -> KernelStatus
}

public enum KernelControlError: Error, Equatable {
    case tokenFileUnreadable
    case tokenFileInvalid
    case tokenNotLoopback
    case portMismatch(filePort: UInt16, requested: UInt16)
    case http(status: Int, message: String)
    case undecodableStatus
    case transport
}

public struct ControlCredentials: Equatable, Sendable {
    public let port: UInt16
    public let token: String

    public static func load(from file: URL) throws -> ControlCredentials {
        let values: URLResourceValues
        do {
            values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        } catch {
            throw KernelControlError.tokenFileUnreadable
        }
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 4096 else {
            throw KernelControlError.tokenFileInvalid
        }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw KernelControlError.tokenFileUnreadable
        }
        guard data.count <= 4096 else {
            throw KernelControlError.tokenFileInvalid
        }
        let decoded: ControlTokenFile
        do {
            decoded = try JSONDecoder().decode(ControlTokenFile.self, from: data)
        } catch {
            throw KernelControlError.tokenFileInvalid
        }
        guard Self.isBearerSafe(decoded.token) else {
            throw KernelControlError.tokenFileInvalid
        }
        switch LoopbackAddress.parse(decoded.addr) {
        case .none:
            throw KernelControlError.tokenFileInvalid
        case .notLoopback:
            throw KernelControlError.tokenNotLoopback
        case let .loopback(port):
            return ControlCredentials(port: port, token: decoded.token)
        }
    }

    /// Printable ASCII, no spaces or quotes, so the token cannot break the
    /// Authorization header or smuggle a second request.
    private static func isBearerSafe(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 256 else {
            return false
        }
        return token.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7e && scalar != "\"" && scalar != "\\"
        }
    }
}

enum LoopbackAddress {
    case loopback(UInt16)
    case notLoopback

    /// `127.0.0.1` and `localhost` only. Anything else, including `::1`, is
    /// refused: the client dials 127.0.0.1 and will not follow a file that
    /// points elsewhere.
    static func parse(_ raw: String) -> LoopbackAddress? {
        let addr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty, !addr.contains("@"), !addr.contains(" ") else {
            return nil
        }
        guard !addr.hasPrefix("[") else {
            return .notLoopback
        }
        guard let colon = addr.lastIndex(of: ":") else {
            return nil
        }
        let host = String(addr[..<colon])
        let portText = String(addr[addr.index(after: colon)...])
        guard let port = UInt16(portText), port > 0 else {
            return nil
        }
        if host == "127.0.0.1" || host.lowercased() == "localhost" {
            return .loopback(port)
        }
        return .notLoopback
    }
}

enum KernelControlSession {
    /// No cookies, no cache, no system proxy, and no redirect follow.
    /// A proxy or a redirect would send the bearer token off the machine.
    static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }
}

/// Refusing the redirect makes URLSession surface the 3xx instead of
/// reissuing the request, with the bearer token, at another host.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// `URLSession` client for `http://127.0.0.1:<port>`. The bearer token is
/// read from `tokenFile` on each call. `port` must match the loopback port
/// in that file.
public struct KernelControlClient: ControlClient, Sendable {
    public let port: UInt16
    public let tokenFile: URL
    public let session: URLSession

    public init(port: UInt16, tokenFile: URL, session: URLSession) {
        self.port = port
        self.tokenFile = tokenFile
        self.session = session
    }

    public func status() async throws -> KernelStatus {
        try await call(method: "GET", path: "/v1/status", body: nil)
    }

    public func connect() async throws -> KernelStatus {
        try await call(method: "POST", path: "/v1/connect", body: nil)
    }

    public func disconnect() async throws -> KernelStatus {
        try await call(method: "POST", path: "/v1/disconnect", body: nil)
    }

    public func selectExit(_ exit: String) async throws -> KernelStatus {
        let body = try JSONEncoder().encode(ExitSelection(exit: exit))
        return try await call(method: "POST", path: "/v1/exit", body: body)
    }

    private func call(method: String, path: String, body: Data?) async throws -> KernelStatus {
        let creds = try ControlCredentials.load(from: tokenFile)
        guard creds.port == port else {
            throw KernelControlError.portMismatch(filePort: creds.port, requested: port)
        }
        return try await Self.perform(
            port: port,
            token: creds.token,
            session: session,
            method: method,
            path: path,
            body: body
        )
    }

    static func perform(
        port: UInt16,
        token: String,
        session: URLSession,
        method: String,
        path: String,
        body: Data?
    ) async throws -> KernelStatus {
        guard var components = URLComponents(string: "http://127.0.0.1") else {
            throw KernelControlError.transport
        }
        components.port = Int(port)
        components.path = path
        guard let url = components.url, url.host == "127.0.0.1" else {
            throw KernelControlError.transport
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw KernelControlError.transport
        }
        guard let http = response as? HTTPURLResponse else {
            throw KernelControlError.transport
        }
        if let responseURL = http.url, responseURL.host != "127.0.0.1" {
            throw KernelControlError.transport
        }
        guard http.statusCode == 200 else {
            throw KernelControlError.http(
                status: http.statusCode,
                message: safeErrorMessage(from: data, token: token)
            )
        }
        do {
            return try JSONDecoder().decode(KernelStatus.self, from: data)
        } catch {
            throw KernelControlError.undecodableStatus
        }
    }

    private static func safeErrorMessage(from data: Data, token: String) -> String {
        let decoded = (try? JSONDecoder().decode(KernelErrorBody.self, from: data))?.error
        guard var message = decoded, !message.isEmpty else {
            return "request failed"
        }
        if message.contains(token) || message.contains("\n") || message.contains("\r") || message.count > 200 {
            message = "request failed"
        }
        return message
    }
}

/// Reads the token file on every call and dials the loopback port it publishes.
/// One session for the life of the value. Creating it does not open a connection.
public final class ResolvingKernelControlClient: ControlClient, @unchecked Sendable {
    public let tokenFile: URL
    private let session: URLSession
    private let ownsSession: Bool

    public init(tokenFile: URL) {
        self.tokenFile = tokenFile
        session = KernelControlSession.make()
        ownsSession = true
    }

    public init(tokenFile: URL, session: URLSession) {
        self.tokenFile = tokenFile
        self.session = session
        ownsSession = false
    }

    deinit {
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
    }

    public func status() async throws -> KernelStatus {
        try await call(method: "GET", path: "/v1/status", body: nil)
    }

    public func connect() async throws -> KernelStatus {
        try await call(method: "POST", path: "/v1/connect", body: nil)
    }

    public func disconnect() async throws -> KernelStatus {
        try await call(method: "POST", path: "/v1/disconnect", body: nil)
    }

    public func selectExit(_ exit: String) async throws -> KernelStatus {
        let body = try JSONEncoder().encode(ExitSelection(exit: exit))
        return try await call(method: "POST", path: "/v1/exit", body: body)
    }

    private func call(method: String, path: String, body: Data?) async throws -> KernelStatus {
        let creds = try ControlCredentials.load(from: tokenFile)
        return try await KernelControlClient.perform(
            port: creds.port,
            token: creds.token,
            session: session,
            method: method,
            path: path,
            body: body
        )
    }
}
