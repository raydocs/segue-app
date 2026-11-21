import XCTest

@testable import SegueKit

@MainActor
final class ConnectionModelTests: XCTestCase {
    private let home = "/Users/example"

    func testStartsWithoutClaimingConnected() {
        let model = makeModel(client: FakeControlClient())
        XCTAssertEqual(model.statusLine, ConnectionModel.noStatusYet)
        XCTAssertFalse(model.showsConnected)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.helperAvailability, .unknown)
    }

    func testConnectAppliesReadback() async throws {
        let fake = FakeControlClient()
        let connected = try Fixtures.status("status-connected")
        fake.connectHandler = { connected }
        let helper = FakeHelper()
        let up = Self.helperStatus(armed: true, utun: true)
        helper.armHandler = { _ in up }
        let model = makeModel(client: fake, helper: helper)
        await model.connect()
        XCTAssertTrue(model.showsConnected)
        XCTAssertEqual(model.statusLine, "Connected. Reconnect or update.")
        XCTAssertEqual(model.reasonText, "")
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertEqual(helper.armIntents.map(\.intent), [.userConnect])
    }

    func testReconnectingReadbackIsNotConnected() async throws {
        let fake = FakeControlClient()
        let status = try Fixtures.status("status-reconnecting")
        fake.connectHandler = { status }
        let model = makeModel(client: fake)
        await model.connect()
        XCTAssertFalse(model.showsConnected)
        XCTAssertEqual(model.statusLine, "Reconnecting.")
    }

    func testFailureDoesNotClaimConnected() async {
        let fake = FakeControlClient()
        let secret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        fake.connectHandler = {
            throw KernelControlError.http(status: 401, message: "bad token \(secret)")
        }
        let model = makeModel(client: fake)
        await model.connect()
        XCTAssertFalse(model.showsConnected)
        XCTAssertEqual(model.statusLine, ConnectionModel.noStatusYet)
        XCTAssertEqual(model.lastError, "The kernel refused the control token.")
        XCTAssertFalse(model.lastError?.contains(secret) ?? true)
        XCTAssertFalse(model.isBusy)
    }

    func testFailureKeepsPreviousReadback() async throws {
        let parts = try await connectFully()
        parts.helper.disarmHandler = { _ in throw HelperClientError.transport }
        await parts.model.disconnect()
        XCTAssertTrue(parts.model.showsConnected)
        XCTAssertEqual(parts.model.statusLine, "Connected. Reconnect or update.")
        XCTAssertEqual(parts.model.lastError, "Couldn't reach the helper on this Mac.")
        XCTAssertFalse(parts.model.isBusy)
    }

    func testDisconnectAppliesReadback() async throws {
        let fake = FakeControlClient()
        var disconnected = try Fixtures.status("status-disconnected")
        disconnected.revoked = false
        fake.disconnectHandler = { disconnected }
        let model = makeModel(client: fake)
        await model.disconnect()
        XCTAssertFalse(model.showsConnected)
        XCTAssertEqual(model.statusLine, "Not connected.")
    }

    func testDisconnectDisarmsWithUserDisconnect() async throws {
        let parts = try await connectFully()
        await parts.model.disconnect()
        XCTAssertEqual(parts.helper.disarmIntents.map(\.intent), [.userDisconnect])
        XCTAssertFalse(parts.helper.disarmIntents.contains { $0.intent == .quit })
        XCTAssertFalse(parts.model.showsConnected)
    }

    func testPortMismatchMessageHidesTheAddress() async {
        let fake = FakeControlClient()
        fake.refreshHandler = {
            throw KernelControlError.portMismatch(filePort: 9277, requested: 1)
        }
        let model = makeModel(client: fake)
        await model.refresh()
        XCTAssertEqual(model.lastError, "The kernel control address is not 127.0.0.1.")
        XCTAssertFalse(model.lastError?.contains("9277") ?? true)
    }

    func testEnsureConfigFolderCreatesDirectory() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("segue-cfg-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        let model = ConnectionModel(
            client: FakeControlClient(),
            configFolder: folder,
            homePath: home
        )
        try model.ensureConfigFolder()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testConnectedRequiresKernelUtunAndArmed() async throws {
        let base = try Fixtures.status("status-connected")
        let states: [KernelState] = [.connected, .reconnecting, .disconnected]
        for state in states {
            for utun in [true, false] {
                for armed in [true, false] {
                    var kernel = base
                    kernel.state = state
                    kernel.revoked = false
                    let snapshot = kernel
                    let helperSnapshot = Self.helperStatus(armed: armed, utun: utun)
                    let fake = FakeControlClient()
                    fake.statusHandler = { snapshot }
                    let helper = FakeHelper()
                    helper.statusHandler = { helperSnapshot }
                    let model = makeModel(client: fake, helper: helper)
                    await model.refresh()
                    let expected = state == .connected && utun && armed
                    XCTAssertEqual(
                        model.showsConnected,
                        expected,
                        "state=\(state) utun=\(utun) armed=\(armed)"
                    )
                    if expected {
                        XCTAssertEqual(model.statusLine, "Connected. Reconnect or update.")
                    } else if state == .connected {
                        XCTAssertEqual(model.statusLine, ConnectionModel.notFullyConnectedLine)
                    }
                }
            }
        }
    }

    func testRevokedDeviceIsNotConnected() async throws {
        var kernel = try Fixtures.status("status-connected")
        kernel.revoked = true
        kernel.state = .connected
        let snapshot = kernel
        let fake = FakeControlClient()
        fake.statusHandler = { snapshot }
        let helper = FakeHelper()
        let up = Self.helperStatus(armed: true, utun: true)
        helper.statusHandler = { up }
        let model = makeModel(client: fake, helper: helper)
        await model.refresh()
        XCTAssertFalse(model.showsConnected)
        XCTAssertTrue(model.isRevoked)
        XCTAssertFalse(model.isGuarding)
        XCTAssertEqual(model.helperKernelState, "running")
        XCTAssertEqual(model.statusLine, "This device was revoked.")
    }

    func testReadyDisarmedHelperWithoutKernelClearsNoHelperReason() async {
        let fake = FakeControlClient()
        fake.statusHandler = { throw KernelControlError.tokenFileUnreadable }
        let helper = FakeHelper()
        let disarmed = HelperStatus(
            armed: false,
            generation: 1,
            held: false,
            tunInterface: nil,
            rulesDigest: "",
            evidence: StatusEvidence(tcpProofMs: nil, dnsReadback: false),
            lastError: nil,
            aiLayer: "off",
            helper: HelperProcessReport(state: "running"),
            kernel: KernelReport(state: "stopped", pid: nil, lastExit: nil)
        )
        helper.statusHandler = { disarmed }
        let model = makeModel(client: fake, helper: helper)
        await model.refresh()
        XCTAssertEqual(model.helperAvailability, .ready)
        XCTAssertFalse(model.helperArmed)
        XCTAssertFalse(model.isGuarding)
        XCTAssertEqual(model.helperKernelState, "stopped")
        XCTAssertEqual(model.reasonText, "")
    }

    func testQuitDoesNotDisarm() async throws {
        let parts = try await connectFully()
        let armed = parts.helper.armIntents.count
        parts.model.applicationWillQuit()
        XCTAssertEqual(parts.helper.armIntents.map(\.intent), [.userConnect])
        XCTAssertEqual(parts.helper.armIntents.count, armed)
        XCTAssertTrue(parts.helper.disarmIntents.isEmpty)
        XCTAssertTrue(parts.model.showsConnected)
    }

    func testRestoreAsksThenDisarms() async throws {
        let parts = try await connectFully()
        parts.model.requestRestoreNetwork()
        XCTAssertTrue(parts.model.restoreNeedsConfirmation)
        XCTAssertTrue(parts.helper.disarmIntents.isEmpty)
        XCTAssertTrue(parts.model.showsConnected)
        await parts.model.confirmRestoreNetwork()
        XCTAssertFalse(parts.model.restoreNeedsConfirmation)
        XCTAssertEqual(parts.helper.disarmIntents.map(\.intent), [.userDisconnect])
        XCTAssertFalse(parts.model.showsConnected)
    }

    func testRestoreCancelDoesNotDisarm() async throws {
        let parts = try await connectFully()
        parts.model.requestRestoreNetwork()
        parts.model.cancelRestoreNetwork()
        XCTAssertFalse(parts.model.restoreNeedsConfirmation)
        XCTAssertTrue(parts.helper.disarmIntents.isEmpty)
        await parts.model.confirmRestoreNetwork()
        XCTAssertTrue(parts.helper.disarmIntents.isEmpty)
        XCTAssertTrue(parts.model.showsConnected)
    }

    func testNotInstalledState() async throws {
        let parts = try await connectFully()
        parts.helper.statusHandler = { throw HelperClientError.notInstalled }
        await parts.model.refresh()
        XCTAssertEqual(parts.model.helperAvailability, .notInstalled)
        XCTAssertFalse(parts.model.showsConnected)
        XCTAssertEqual(parts.model.statusLine, ConnectionModel.helperNotInstalledLine)
        XCTAssertEqual(parts.model.reasonText, ConnectionModel.helperInstallInstructions)
        XCTAssertNil(parts.model.lastError)
    }

    func testVersionMismatchState() async throws {
        let parts = try await connectFully()
        parts.helper.statusHandler = { throw HelperClientError.versionMismatch(9) }
        await parts.model.refresh()
        XCTAssertEqual(parts.model.helperAvailability, .versionMismatch)
        XCTAssertFalse(parts.model.showsConnected)
        XCTAssertEqual(parts.model.statusLine, ConnectionModel.versionMismatchLine)
        XCTAssertTrue(parts.model.reasonText.contains("version 9"))
        XCTAssertTrue(parts.model.reasonText.contains("version \(HelperProtocolVersion.current)"))
        XCTAssertNil(parts.model.lastError)
    }

    func testUnauthorizedState() async throws {
        let parts = try await connectFully()
        parts.helper.statusHandler = { throw HelperClientError.unauthorized }
        await parts.model.refresh()
        XCTAssertEqual(parts.model.helperAvailability, .unauthorized)
        XCTAssertFalse(parts.model.showsConnected)
        XCTAssertEqual(parts.model.statusLine, ConnectionModel.unauthorizedLine)
        XCTAssertEqual(parts.model.reasonText, ConnectionModel.unauthorizedReason)
    }

    func testTransportFailureKeepsConnectedReadback() async throws {
        let parts = try await connectFully()
        parts.helper.statusHandler = { throw HelperClientError.transport }
        await parts.model.refresh()
        XCTAssertTrue(parts.model.showsConnected)
        XCTAssertEqual(parts.model.helperAvailability, .ready)
        XCTAssertEqual(parts.model.lastError, "Couldn't reach the helper on this Mac.")
    }

    func testPollingBacksOffWhenMenuCloses() async throws {
        XCTAssertEqual(ConnectionModel.openPollInterval, 2)
        let clock = ManualPollClock()
        let fake = FakeControlClient()
        let model = makeModel(client: fake, clock: clock, startsPolling: true)
        defer { model.applicationWillQuit() }

        let closed = await clock.nextInterval()
        XCTAssertEqual(closed, 4)

        model.setMenuOpen(true)
        let opened = await clock.nextInterval()
        XCTAssertEqual(opened, ConnectionModel.openPollInterval)
        clock.fire()
        let stillOpen = await clock.nextInterval()
        XCTAssertEqual(stillOpen, ConnectionModel.openPollInterval)

        model.setMenuOpen(false)
        let backedOff = await clock.nextInterval()
        XCTAssertEqual(backedOff, 4)
        clock.fire()
        let doubled = await clock.nextInterval()
        XCTAssertEqual(doubled, 8)
        clock.fire()
        let doubledAgain = await clock.nextInterval()
        XCTAssertEqual(doubledAgain, 16)
        clock.fire()
        let capped = await clock.nextInterval()
        XCTAssertEqual(capped, 32)
        clock.fire()
        let stillCapped = await clock.nextInterval()
        XCTAssertEqual(stillCapped, ConnectionModel.closedPollMaxInterval)

        model.noteWake()
        let afterWake = await clock.nextInterval()
        XCTAssertEqual(afterWake, 4)
        model.noteNetworkChange()
        let afterNetwork = await clock.nextInterval()
        XCTAssertEqual(afterNetwork, 4)
    }

    private func connectFully() async throws -> (model: ConnectionModel, helper: FakeHelper) {
        let fake = FakeControlClient()
        let connected = try Fixtures.status("status-connected")
        var down = connected
        down.state = .disconnected
        down.revoked = false
        fake.connectHandler = { connected }
        fake.statusHandler = { connected }
        fake.disconnectHandler = { down }
        let helper = FakeHelper()
        let up = Self.helperStatus(armed: true, utun: true)
        helper.statusHandler = { up }
        helper.armHandler = { _ in up }
        helper.disarmHandler = { intent in
            Self.helperStatus(armed: false, utun: false, generation: intent.generation)
        }
        let model = makeModel(client: fake, helper: helper)
        await model.connect()
        return (model, helper)
    }

    func testSelectExitAppliesReadbackAndKeepsStateOnFailure() async throws {
        let initial = try Fixtures.status("status-connected-live-exits")
        var switched = initial
        switched.exitChoice = "jp-tokyo"
        switched.currentExit = "jp-tokyo"
        let switchedSnapshot = switched

        let fake = FakeControlClient()
        fake.connectHandler = { initial }
        fake.selectHandler = { exit in
            XCTAssertEqual(exit, "jp-tokyo")
            return switchedSnapshot
        }
        let helper = FakeHelper()
        let up = Self.helperStatus(armed: true, utun: true)
        helper.armHandler = { _ in up }
        helper.statusHandler = { up }

        let model = makeModel(client: fake, helper: helper)
        await model.connect()
        XCTAssertTrue(model.showsConnected)
        XCTAssertEqual(model.exitChoice, "auto")
        XCTAssertEqual(model.currentExit, "us-west")
        XCTAssertEqual(model.exitDetails.count, 3)
        XCTAssertEqual(model.exitDetails[1].quality?.srttMs, 68)
        XCTAssertEqual(model.policyVersion, 41)
        XCTAssertTrue(model.policyValid)
        XCTAssertEqual(model.tunInterface, "utun4")
        XCTAssertNotNil(model.connectedSince)

        await model.selectExit("jp-tokyo")
        XCTAssertEqual(model.exitChoice, "jp-tokyo")
        XCTAssertEqual(model.currentExit, "jp-tokyo")
        XCTAssertNil(model.lastError)

        fake.selectHandler = { _ in throw KernelControlError.transport }
        await model.selectExit("sg-edge")
        XCTAssertEqual(model.exitChoice, "jp-tokyo")
        XCTAssertEqual(model.currentExit, "jp-tokyo")
        XCTAssertEqual(model.lastError, "Couldn't reach the kernel on this Mac.")
    }

    private func makeModel(
        client: FakeControlClient,
        helper: FakeHelper? = nil,
        clock: (any PollClock)? = nil,
        startsPolling: Bool = false
    ) -> ConnectionModel {
        let folder = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Segue", isDirectory: true)
        return ConnectionModel(
            client: client,
            configFolder: folder,
            homePath: home,
            helper: helper,
            clock: clock,
            startsPolling: startsPolling
        )
    }

    private static func helperStatus(armed: Bool, utun: Bool, generation: UInt64 = 4) -> HelperStatus {
        HelperStatus(
            armed: armed,
            generation: generation,
            held: armed,
            tunInterface: utun ? "utun4" : nil,
            rulesDigest: "abc123",
            evidence: StatusEvidence(tcpProofMs: utun ? 12 : nil, dnsReadback: utun),
            lastError: nil,
            aiLayer: armed ? "armed" : "not_implemented",
            helper: HelperProcessReport(state: "running"),
            kernel: KernelReport(state: "running", pid: nil, lastExit: nil)
        )
    }
}

final class FakeControlClient: ControlClient, @unchecked Sendable {
    var statusHandler: () async throws -> KernelStatus
    var connectHandler: () async throws -> KernelStatus
    var disconnectHandler: () async throws -> KernelStatus
    var selectHandler: (String) async throws -> KernelStatus
    var refreshHandler: (() async throws -> KernelStatus)?
    private let lock = NSLock()
    private var connects = 0

    var connectCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return connects
    }

    init() {
        let fail: () async throws -> KernelStatus = { throw KernelControlError.transport }
        statusHandler = fail
        connectHandler = fail
        disconnectHandler = fail
        selectHandler = { _ in throw KernelControlError.transport }
    }

    func status() async throws -> KernelStatus {
        if let refreshHandler {
            return try await refreshHandler()
        }
        return try await statusHandler()
    }

    func connect() async throws -> KernelStatus {
        noteConnect()
        return try await connectHandler()
    }

    /// Synchronous so the lock is not taken from an async context.
    private func noteConnect() {
        lock.lock()
        connects += 1
        lock.unlock()
    }

    func disconnect() async throws -> KernelStatus {
        try await disconnectHandler()
    }

    func selectExit(_ exit: String) async throws -> KernelStatus {
        try await selectHandler(exit)
    }
}

final class FakeHelper: HelperControlling, @unchecked Sendable {
    var statusHandler: () async throws -> HelperStatus
    var armHandler: (ArmIntent) async throws -> HelperStatus
    var disarmHandler: (DisarmIntent) async throws -> HelperStatus
    private let lock = NSLock()
    private var arms: [ArmIntent] = []
    private var disarms: [DisarmIntent] = []

    var armIntents: [ArmIntent] {
        lock.lock()
        defer { lock.unlock() }
        return arms
    }

    var disarmIntents: [DisarmIntent] {
        lock.lock()
        defer { lock.unlock() }
        return disarms
    }

    init() {
        let fail: () async throws -> HelperStatus = { throw HelperClientError.transport }
        statusHandler = fail
        armHandler = { _ in throw HelperClientError.transport }
        disarmHandler = { _ in throw HelperClientError.transport }
    }

    func readStatus() async throws -> HelperStatus {
        try await statusHandler()
    }

    func arm(_ intent: ArmIntent) async throws -> HelperStatus {
        recordArm(intent)
        return try await armHandler(intent)
    }

    func disarm(_ intent: DisarmIntent) async throws -> HelperStatus {
        recordDisarm(intent)
        return try await disarmHandler(intent)
    }

    private func recordArm(_ intent: ArmIntent) {
        lock.lock()
        arms.append(intent)
        lock.unlock()
    }

    private func recordDisarm(_ intent: DisarmIntent) {
        lock.lock()
        disarms.append(intent)
        lock.unlock()
    }
}

/// Records each wait and blocks until `fire` or cancellation.
final class ManualPollClock: PollClock, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    private var cursor = 0
    private var intervalWaiter: CheckedContinuation<TimeInterval, Never>?
    private var current: OnceGate?

    func wait(seconds: TimeInterval) async {
        let gate = OnceGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate.store(continuation)
                self.noteWaiting(seconds: seconds, gate: gate)
            }
        } onCancel: {
            gate.signal()
        }
    }

    func nextInterval() async -> TimeInterval {
        await withCheckedContinuation { continuation in
            lock.lock()
            if cursor < recorded.count {
                let value = recorded[cursor]
                cursor += 1
                lock.unlock()
                continuation.resume(returning: value)
                return
            }
            intervalWaiter = continuation
            lock.unlock()
        }
    }

    func fire() {
        lock.lock()
        let gate = current
        lock.unlock()
        gate?.signal()
    }

    private func noteWaiting(seconds: TimeInterval, gate: OnceGate) {
        let notify: CheckedContinuation<TimeInterval, Never>?
        lock.lock()
        recorded.append(seconds)
        current = gate
        notify = intervalWaiter
        if notify != nil {
            cursor += 1
            intervalWaiter = nil
        }
        lock.unlock()
        guard let notify else {
            return
        }
        Task { @MainActor in
            notify.resume(returning: seconds)
        }
    }

    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var fired = false

        func store(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func signal() {
            lock.lock()
            if fired {
                lock.unlock()
                return
            }
            fired = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }
}
