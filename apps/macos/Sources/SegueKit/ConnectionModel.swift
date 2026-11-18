import Combine
import Foundation

/// Menu state. Connected is copied from a control read-back. A failed call
/// leaves the previous read-back alone and does not flip the menu to connected.
@MainActor
public final class ConnectionModel: ObservableObject {
    public static let noStatusYet = "No status yet."

    @Published public private(set) var statusLine: String
    @Published public private(set) var showsConnected: Bool
    @Published public private(set) var isBusy: Bool
    @Published public internal(set) var lastError: String?
    @Published public private(set) var notice: String?

    public let configFolder: URL

    private let client: any ControlClient
    private let fileManager: FileManager
    private let homePath: String
    private var latest: KernelStatus?

    public init(
        client: any ControlClient,
        configFolder: URL,
        homePath: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.client = client
        self.configFolder = configFolder
        self.fileManager = fileManager
        self.homePath = homePath ?? fileManager.homeDirectoryForCurrentUser.path
        statusLine = Self.noStatusYet
        showsConnected = false
        isBusy = false
        lastError = nil
        notice = nil
    }

    public func connect() async {
        await run { try await self.client.connect() }
    }

    public func disconnect() async {
        await run { try await self.client.disconnect() }
    }

    public func refresh() async {
        await run { try await self.client.status() }
    }

    public func ensureConfigFolder() throws {
        try fileManager.createDirectory(at: configFolder, withIntermediateDirectories: true)
    }

    @discardableResult
    public func exportDiagnostics(
        to directory: URL,
        now: Date = Date(),
        secrets: [String] = [],
        peerAddresses: [String] = []
    ) throws -> URL {
        let document = DiagnosticsDocument(
            schemaVersion: DiagnosticsDocument.currentSchema,
            exportedAt: DiagnosticsWriter.timestamp(now),
            statusLine: statusLine,
            showsConnected: showsConnected,
            configFolder: configFolder.path,
            kernel: latest,
            helper: nil,
            lastError: lastError
        )
        return try DiagnosticsWriter.write(
            document: document,
            to: directory,
            now: now,
            home: homePath,
            secrets: secrets,
            peerAddresses: peerAddresses,
            fileManager: fileManager
        )
    }

    public func present(error message: String) {
        lastError = DiagnosticsRedactor.redact(message, home: homePath)
        notice = nil
    }

    public func present(notice message: String) {
        notice = message
        lastError = nil
    }

    private func run(_ operation: () async throws -> KernelStatus) async {
        guard !isBusy else {
            return
        }
        isBusy = true
        defer { isBusy = false }
        notice = nil
        do {
            let status = try await operation()
            apply(status)
        } catch {
            lastError = Self.userMessage(for: error)
        }
    }

    private func apply(_ status: KernelStatus) {
        latest = status
        showsConnected = status.showsConnected
        statusLine = status.statusLine
        lastError = nil
    }

    private static func userMessage(for error: Error) -> String {
        guard let error = error as? KernelControlError else {
            return "Couldn't reach the kernel on this Mac."
        }
        switch error {
        case .tokenFileUnreadable, .tokenFileInvalid:
            return "Couldn't read the kernel control token."
        case .tokenNotLoopback, .portMismatch:
            return "The kernel control address is not 127.0.0.1."
        case let .http(status, _) where status == 401:
            return "The kernel refused the control token."
        case let .http(status, _) where status == 403:
            return "The kernel refused the request."
        case .http:
            return "The kernel rejected the request."
        case .undecodableStatus:
            return "The kernel status was not understood."
        case .transport:
            return "Couldn't reach the kernel on this Mac."
        }
    }
}
