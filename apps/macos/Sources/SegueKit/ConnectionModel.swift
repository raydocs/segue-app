import Combine
import Foundation

/// How the helper socket looked on the last definitive reply.
public enum HelperAvailability: Equatable, Sendable {
    case unknown
    case ready
    case notInstalled
    case versionMismatch
    case unauthorized
}

/// Clock for the status poll. Production sleeps; tests resume the wait.
public protocol PollClock: Sendable {
    func wait(seconds: TimeInterval) async
}

public struct SystemPollClock: PollClock, Sendable {
    public init() {}

    public func wait(seconds: TimeInterval) async {
        let clamped = max(0, seconds)
        let nanos = UInt64((clamped * 1_000_000_000).rounded(.down))
        try? await Task.sleep(nanoseconds: nanos)
    }
}

/// Menu state. Connected is copied from read-backs only: the kernel reports
/// `connected`, the helper sees a utun, and the AI lock is armed. A failed
/// call leaves the previous read-back alone. Quitting does not disarm.
@MainActor
public final class ConnectionModel: ObservableObject {
    public static let noStatusYet = "No status yet."
    public static let notFullyConnectedLine = "Not fully connected."
    public static let helperNotInstalledLine = "Helper not installed."
    public static let helperInstallInstructions =
        "The Segue helper is not installed. Install it from the Segue disk image, then open this menu again. This app does not install the helper itself."
    public static let versionMismatchLine = "Helper version mismatch."
    public static let unauthorizedLine = "The helper refused this app."
    public static let unauthorizedReason = "The helper did not accept this app."

    /// While the menu is open. A closed menu backs off from 4s to 32s.
    public static let openPollInterval: TimeInterval = 2
    public static let closedPollMaxInterval: TimeInterval = 32

    @Published public private(set) var statusLine: String
    @Published public private(set) var reasonText: String
    @Published public private(set) var showsConnected: Bool
    @Published public private(set) var isBusy: Bool
    @Published public internal(set) var lastError: String?
    @Published public private(set) var notice: String?
    @Published public private(set) var helperAvailability: HelperAvailability
    @Published public private(set) var restoreNeedsConfirmation: Bool

    public let configFolder: URL

    private let client: any ControlClient
    private let helper: (any HelperControlling)?
    private let clock: (any PollClock)?
    private let fileManager: FileManager
    private let homePath: String
    private var latestKernel: KernelStatus?
    private var latestHelper: HelperStatus?
    private var mismatchedVersion: Int?
    private var samples: [ReadbackSample] = []
    private var menuOpen = false
    private var closedSteps = 0
    private var readSerial = 0
    private var pollGeneration = 0
    private var pollTask: Task<Void, Never>?
    private var pollingStopped = false

    private struct ReadbackSample: Codable, Equatable {
        var kernel: KernelStatus?
        var helper: HelperStatus?
    }

    public init(
        client: any ControlClient,
        configFolder: URL,
        homePath: String? = nil,
        fileManager: FileManager = .default,
        helper: (any HelperControlling)? = nil,
        clock: (any PollClock)? = nil,
        startsPolling: Bool = false
    ) {
        self.client = client
        self.helper = helper
        self.clock = clock
        self.configFolder = configFolder
        self.fileManager = fileManager
        self.homePath = homePath ?? fileManager.homeDirectoryForCurrentUser.path
        statusLine = Self.noStatusYet
        reasonText = ""
        showsConnected = false
        isBusy = false
        lastError = nil
        notice = nil
        helperAvailability = .unknown
        restoreNeedsConfirmation = false
        if startsPolling {
            restartPolling(refreshNow: true)
        }
    }

    public func connect() async {
        guard begin() else {
            return
        }
        defer { isBusy = false }
        let serial = beginRead()
        do {
            if let helper {
                let generation = (latestHelper?.generation ?? 0) + 1
                let status = try await helper.arm(HelperRequests.userConnect(generation: generation))
                guard serial == readSerial else {
                    return
                }
                helperAvailability = .ready
                mismatchedVersion = nil
                apply(helper: status)
            }
            let kernel = try await client.connect()
            guard serial == readSerial else {
                return
            }
            apply(kernel: kernel)
            lastError = nil
        } catch {
            guard serial == readSerial else {
                return
            }
            note(error)
        }
    }

    /// Explicit Disconnect. Sends `user_disconnect`. Does not ask twice.
    public func disconnect() async {
        await disarm(.userDisconnect)
    }

    /// Shows the confirm step. Does not disarm.
    public func requestRestoreNetwork() {
        restoreNeedsConfirmation = true
    }

    public func cancelRestoreNetwork() {
        restoreNeedsConfirmation = false
    }

    /// Confirm step for Restore network. Sends `user_disconnect` only now.
    public func confirmRestoreNetwork() async {
        guard restoreNeedsConfirmation, !isBusy else {
            return
        }
        restoreNeedsConfirmation = false
        await disarm(.userDisconnect)
    }

    /// Quit, force-quit, or a crash must not clear intent. This stops the
    /// poll and does not send disarm, including `quit`.
    public func applicationWillQuit() {
        pollingStopped = true
        pollGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
    }

    public func refresh() async {
        guard begin() else {
            return
        }
        defer { isBusy = false }
        await pollRefresh()
    }

    public func setMenuOpen(_ open: Bool) {
        guard open != menuOpen else {
            return
        }
        menuOpen = open
        closedSteps = 0
        restartPolling(refreshNow: true)
    }

    public func noteWake() {
        closedSteps = 0
        restartPolling(refreshNow: true)
    }

    public func noteNetworkChange() {
        closedSteps = 0
        restartPolling(refreshNow: true)
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
        try DiagnosticsWriter.write(
            document: makeDocument(now: now),
            to: directory,
            now: now,
            home: homePath,
            secrets: secrets,
            peerAddresses: peerAddresses,
            fileManager: fileManager
        )
    }

    /// Zip of the current read-back, the recent read-backs, and logs.
    /// Home paths, bearer tokens, and utun peer addresses are redacted.
    @discardableResult
    public func exportDiagnosticsZip(
        to directory: URL,
        logs: [DiagnosticsLog] = [],
        now: Date = Date(),
        secrets: [String] = [],
        peerAddresses: [String] = []
    ) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let status = try encoder.encode(makeDocument(now: now))
        let history = try encoder.encode(samples)
        var files: [(name: String, bytes: Data)] = [
            ("status.json", status),
            ("readbacks.json", history),
        ]
        var seen: Set<String> = []
        for log in configLogs() + logs {
            let name = "logs/" + ZipStore.safeLogName(log.name)
            if seen.contains(name) {
                continue
            }
            seen.insert(name)
            files.append((name, Data(log.body.utf8)))
        }
        return try DiagnosticsArchive.write(
            files: files,
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

    public static func versionMismatchReason(version: Int?) -> String {
        if let version {
            return "The helper speaks protocol version \(version); this app speaks version \(HelperProtocolVersion.current). Update them together."
        }
        return "This app and the helper do not speak the same protocol. Update them together."
    }

    private func disarm(_ reason: DisarmReason) async {
        guard begin() else {
            return
        }
        defer { isBusy = false }
        let serial = beginRead()
        do {
            if let helper {
                let generation = (latestHelper?.generation ?? 0) + 1
                let intent = DisarmIntent(generation: generation, intent: reason)
                let status = try await helper.disarm(intent)
                guard serial == readSerial else {
                    return
                }
                helperAvailability = .ready
                mismatchedVersion = nil
                apply(helper: status)
            }
            let kernel = try await client.disconnect()
            guard serial == readSerial else {
                return
            }
            apply(kernel: kernel)
            lastError = nil
        } catch {
            guard serial == readSerial else {
                return
            }
            note(error)
        }
    }

    private func begin() -> Bool {
        guard !isBusy else {
            return false
        }
        isBusy = true
        notice = nil
        return true
    }

    private func beginRead() -> Int {
        readSerial &+= 1
        return readSerial
    }

    private func pollRefresh() async {
        let serial = beginRead()
        let helperOK = await readHelper(serial: serial)
        let kernelOK = await readKernel(serial: serial)
        guard serial == readSerial else {
            return
        }
        if helperOK && kernelOK {
            lastError = nil
        }
    }

    private func readHelper(serial: Int) async -> Bool {
        guard let helper else {
            return true
        }
        do {
            let status = try await helper.readStatus()
            guard serial == readSerial else {
                return false
            }
            helperAvailability = .ready
            mismatchedVersion = nil
            apply(helper: status)
            return true
        } catch {
            guard serial == readSerial else {
                return false
            }
            note(error)
            return false
        }
    }

    private func readKernel(serial: Int) async -> Bool {
        do {
            let status = try await client.status()
            guard serial == readSerial else {
                return false
            }
            apply(kernel: status)
            return true
        } catch {
            guard serial == readSerial else {
                return false
            }
            if lastError == nil, !Self.hidesKernelError(helperAvailability) {
                lastError = Self.userMessage(for: error)
            }
            return false
        }
    }

    private func apply(kernel: KernelStatus) {
        latestKernel = kernel
        recompute()
        remember()
    }

    private func apply(helper: HelperStatus) {
        latestHelper = helper
        recompute()
        remember()
    }

    private func remember() {
        let sample = ReadbackSample(kernel: latestKernel, helper: latestHelper)
        if samples.last == sample {
            return
        }
        samples.append(sample)
        if samples.count > 20 {
            samples.removeFirst(samples.count - 20)
        }
    }

    private func recompute() {
        let utunUp = !(latestHelper?.tunInterface ?? "").isEmpty
        let armed = latestHelper?.armed == true
        let kernelConnected = latestKernel?.state == .connected && latestKernel?.revoked != true
        showsConnected = helperAvailability == .ready && kernelConnected && utunUp && armed

        switch helperAvailability {
        case .notInstalled:
            statusLine = Self.helperNotInstalledLine
            reasonText = Self.helperInstallInstructions
            showsConnected = false
            return
        case .versionMismatch:
            statusLine = Self.versionMismatchLine
            reasonText = Self.versionMismatchReason(version: mismatchedVersion)
            showsConnected = false
            return
        case .unauthorized:
            statusLine = Self.unauthorizedLine
            reasonText = Self.unauthorizedReason
            showsConnected = false
            return
        case .unknown, .ready:
            break
        }

        guard let kernel = latestKernel else {
            statusLine = Self.noStatusYet
            reasonText = helper == nil ? "" : "No helper status yet."
            return
        }
        if kernel.revoked {
            statusLine = kernel.statusLine
            reasonText = "This device was revoked."
            showsConnected = false
            return
        }
        if showsConnected {
            statusLine = kernel.statusLine
            reasonText = ""
            return
        }
        if kernel.state == .connected {
            statusLine = Self.notFullyConnectedLine
        } else {
            statusLine = kernel.statusLine
        }
        reasonText = gapReason(utunUp: utunUp, armed: armed)
    }

    private func gapReason(utunUp: Bool, armed: Bool) -> String {
        if latestHelper == nil {
            if helper != nil && helperAvailability == .unknown {
                return "No helper status yet."
            }
            return ""
        }
        var reasons: [String] = []
        if !utunUp {
            reasons.append("The helper does not see a tunnel.")
        }
        if !armed {
            reasons.append("The AI lock is not armed.")
        }
        return reasons.joined(separator: " ")
    }

    private func note(_ error: Error) {
        guard let helperError = error as? HelperClientError else {
            lastError = Self.userMessage(for: error)
            return
        }
        switch helperError {
        case .notInstalled:
            helperAvailability = .notInstalled
            mismatchedVersion = nil
            latestHelper = nil
            lastError = nil
            recompute()
        case let .versionMismatch(version):
            helperAvailability = .versionMismatch
            mismatchedVersion = version
            latestHelper = nil
            lastError = nil
            recompute()
        case .unauthorized:
            helperAvailability = .unauthorized
            mismatchedVersion = nil
            latestHelper = nil
            lastError = nil
            recompute()
        case .malformed, .rejected, .transport:
            lastError = Self.userMessage(for: error)
        }
    }

    private func makeDocument(now: Date) -> DiagnosticsDocument {
        DiagnosticsDocument(
            schemaVersion: DiagnosticsDocument.currentSchema,
            exportedAt: DiagnosticsWriter.timestamp(now),
            statusLine: statusLine,
            showsConnected: showsConnected,
            configFolder: configFolder.path,
            kernel: latestKernel,
            helper: latestHelper,
            lastError: lastError
        )
    }

    private func configLogs() -> [DiagnosticsLog] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: configFolder.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let names = try? fileManager.contentsOfDirectory(atPath: configFolder.path)
        else {
            return []
        }
        var logs: [DiagnosticsLog] = []
        for name in names where name.hasSuffix(".log") {
            let url = configFolder.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ]),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size <= DiagnosticsArchive.maxLogBytes,
                  let data = try? Data(contentsOf: url)
            else {
                continue
            }
            logs.append(DiagnosticsLog(name: name, body: String(decoding: data, as: UTF8.self)))
        }
        return logs
    }

    private func restartPolling(refreshNow: Bool) {
        guard !pollingStopped, let clock else {
            return
        }
        pollGeneration &+= 1
        let generation = pollGeneration
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if refreshNow {
                await self.pollRefresh()
            }
            await self.pollLoop(generation: generation, clock: clock)
        }
    }

    private func pollLoop(generation: Int, clock: any PollClock) async {
        while generation == pollGeneration && !Task.isCancelled {
            let interval = nextInterval()
            await clock.wait(seconds: interval)
            if generation != pollGeneration || Task.isCancelled {
                return
            }
            await pollRefresh()
        }
    }

    private func nextInterval() -> TimeInterval {
        if menuOpen {
            return Self.openPollInterval
        }
        closedSteps = min(closedSteps + 1, 4)
        let interval = Self.openPollInterval * Double(1 << closedSteps)
        return min(interval, Self.closedPollMaxInterval)
    }

    private static func hidesKernelError(_ availability: HelperAvailability) -> Bool {
        switch availability {
        case .notInstalled, .versionMismatch, .unauthorized:
            return true
        case .unknown, .ready:
            return false
        }
    }

    private static func userMessage(for error: Error) -> String {
        if let helperError = error as? HelperClientError {
            switch helperError {
            case .notInstalled:
                return helperNotInstalledLine
            case .versionMismatch:
                return versionMismatchLine
            case .unauthorized:
                return unauthorizedLine
            case .malformed:
                return "The helper reply was not understood."
            case .rejected:
                return "The helper rejected the request."
            case .transport:
                return "Couldn't reach the helper on this Mac."
            }
        }
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
