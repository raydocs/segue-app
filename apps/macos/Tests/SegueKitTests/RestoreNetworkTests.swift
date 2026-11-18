import XCTest

@testable import SegueKit

/// Restore network: the helper is asked first, the release daemon is the
/// fallback when the helper cannot answer (`docs/design/macos.md` §3).
@MainActor
final class RestoreNetworkTests: XCTestCase {
    private let home = "/Users/example"

    func testStuckHelperFallsBackToTheReleaseDaemon() async throws {
        let parts = try await makeParts(
            helperDisarm: { _ in
                // Accepts the request, never answers in time. Self-bounded so
                // the abandoned race does not linger past the test run.
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return Self.disarmedHelper
            }
        )
        parts.model.requestRestoreNetwork()
        await parts.model.confirmRestoreNetwork()

        // The helper was asked, and the release daemon finished the job.
        XCTAssertEqual(parts.helper.disarmIntents.map(\.intent), [.userDisconnect])
        XCTAssertEqual(parts.release.restoreCalls, 1)
        XCTAssertEqual(parts.model.notice, ConnectionModel.networkRestoredNotice)
        XCTAssertNil(parts.model.lastError)
        XCTAssertFalse(parts.model.showsConnected)
        XCTAssertFalse(parts.model.isBusy)
        XCTAssertFalse(parts.model.restoreNeedsConfirmation)
        // The kernel is disconnected either way.
        XCTAssertEqual(parts.client.disconnectCalls, 1)
    }

    func testAnsweringHelperMeansNoReleaseDaemon() async throws {
        let parts = try await makeParts(helperDisarm: { _ in Self.disarmedHelper })
        await parts.model.confirmRestoreAfterAsking()

        XCTAssertEqual(parts.helper.disarmIntents.count, 1)
        XCTAssertEqual(parts.release.restoreCalls, 0)
        XCTAssertNil(parts.model.notice)
        XCTAssertFalse(parts.model.showsConnected)
        XCTAssertEqual(parts.client.disconnectCalls, 1)
    }

    func testDeadHelperSocketFallsBackToo() async throws {
        let parts = try await makeParts(helperDisarm: { _ in
            throw HelperClientError.transport
        })
        await parts.model.confirmRestoreAfterAsking()

        XCTAssertEqual(parts.release.restoreCalls, 1)
        XCTAssertEqual(parts.model.notice, ConnectionModel.networkRestoredNotice)
    }

    func testUninstalledHelperFallsBackToo() async throws {
        let parts = try await makeParts(helperDisarm: { _ in
            throw HelperClientError.notInstalled
        })
        await parts.model.confirmRestoreAfterAsking()

        XCTAssertEqual(parts.release.restoreCalls, 1)
        XCTAssertEqual(parts.model.notice, ConnectionModel.networkRestoredNotice)
    }

    func testDefinitiveRefusalDoesNotFallBack() async throws {
        let parts = try await makeParts(helperDisarm: { _ in
            throw HelperClientError.unauthorized
        })
        await parts.model.confirmRestoreAfterAsking()

        XCTAssertEqual(parts.release.restoreCalls, 0)
        XCTAssertEqual(parts.model.helperAvailability, .unauthorized)
        XCTAssertNil(parts.model.notice)
    }

    func testFailedReleaseSurfacesItsOwnError() async throws {
        let parts = try await makeParts(
            helperDisarm: { _ in throw HelperClientError.transport },
            releaseHandler: { throw ReleaseClientError.transport }
        )
        await parts.model.confirmRestoreAfterAsking()

        XCTAssertEqual(parts.release.restoreCalls, 1)
        XCTAssertNil(parts.model.notice)
        XCTAssertEqual(parts.model.lastError, "Couldn't reach the release daemon on this Mac.")
        XCTAssertFalse(parts.model.isBusy)
    }

    func testPartialReadBackIsNotCalledRestored() async throws {
        let parts = try await makeParts(
            helperDisarm: { _ in throw HelperClientError.transport },
            releaseHandler: { Self.partialReport }
        )
        await parts.model.confirmRestoreAfterAsking()

        XCTAssertEqual(parts.model.notice, ConnectionModel.networkPartiallyRestoredNotice)
    }

    func testPlainDisconnectNeverUsesTheReleaseDaemon() async throws {
        let parts = try await makeParts(helperDisarm: { _ in
            throw HelperClientError.transport
        })
        await parts.model.disconnect()

        XCTAssertEqual(parts.helper.disarmIntents.count, 1)
        XCTAssertEqual(parts.release.restoreCalls, 0)
        XCTAssertEqual(parts.model.lastError, "Couldn't reach the helper on this Mac.")
    }

    // MARK: - parts

    private struct Parts {
        var model: ConnectionModel
        var client: RestoreControlClient
        var helper: FakeHelper
        var release: FakeRelease
    }

    private func makeParts(
        helperDisarm: @escaping (DisarmIntent) async throws -> HelperStatus,
        releaseHandler: @escaping () async throws -> ReleaseReport = { RestoreNetworkTests.cleanReport }
    ) async throws -> Parts {
        let connected = try Fixtures.status("status-connected")
        var down = connected
        down.state = .disconnected
        down.revoked = false
        let client = RestoreControlClient()
        client.statusHandler = { connected }
        client.connectHandler = { connected }
        client.disconnectHandler = { down }
        let helper = FakeHelper()
        let up = Self.armedHelper
        helper.statusHandler = { up }
        helper.armHandler = { _ in up }
        helper.disarmHandler = helperDisarm
        let release = FakeRelease()
        release.restoreHandler = releaseHandler
        let model = ConnectionModel(
            client: client,
            configFolder: URL(fileURLWithPath: home),
            homePath: home,
            helper: helper,
            release: release,
            restoreHelperTimeout: 0.2,
            startsPolling: false
        )
        await model.connect()
        XCTAssertTrue(model.showsConnected)
        return Parts(model: model, client: client, helper: helper, release: release)
    }

    private static var armedHelper: HelperStatus {
        helperStatus(armed: true, utun: true)
    }

    private static var disarmedHelper: HelperStatus {
        helperStatus(armed: false, utun: false)
    }

    private static func helperStatus(armed: Bool, utun: Bool) -> HelperStatus {
        HelperStatus(
            armed: armed,
            generation: 4,
            held: armed,
            tunInterface: utun ? "utun4" : nil,
            rulesDigest: "abc123",
            evidence: StatusEvidence(tcpProofMs: nil, dnsReadback: utun),
            lastError: nil,
            aiLayer: nil,
            helper: HelperProcessReport(state: "running"),
            kernel: KernelReport(state: "running", pid: nil, lastExit: nil)
        )
    }

    private static var cleanReport: ReleaseReport {
        ReleaseReport(
            anchorLoaded: false,
            resolverFilesRemoved: ["api.example"],
            resolverFilesRemaining: [],
            dnsRestoredServices: ["Wi-Fi"],
            dnsMissingServices: [],
            dnsMode: "system",
            intentCleared: true,
            snapshotCleared: true,
            failures: [],
            outcome: ReleaseOutcome.restored
        )
    }

    private static var partialReport: ReleaseReport {
        ReleaseReport(
            anchorLoaded: true,
            resolverFilesRemoved: [],
            resolverFilesRemaining: ["api.example"],
            dnsRestoredServices: [],
            dnsMissingServices: [],
            dnsMode: "guard",
            intentCleared: false,
            snapshotCleared: false,
            failures: [ReleaseFailureSamples.anchorFlush],
            outcome: ReleaseOutcome.partial
        )
    }
}

/// Control client that counts disconnects; the handlers are set per test.
private final class RestoreControlClient: ControlClient, @unchecked Sendable {
    var statusHandler: () async throws -> KernelStatus
    var connectHandler: () async throws -> KernelStatus
    var disconnectHandler: () async throws -> KernelStatus
    private let lock = NSLock()
    private var disconnects = 0

    var disconnectCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return disconnects
    }

    init() {
        let fail: () async throws -> KernelStatus = { throw KernelControlError.transport }
        statusHandler = fail
        connectHandler = fail
        disconnectHandler = fail
    }

    func status() async throws -> KernelStatus {
        try await statusHandler()
    }

    func connect() async throws -> KernelStatus {
        try await connectHandler()
    }

    func disconnect() async throws -> KernelStatus {
        lock.lock()
        disconnects += 1
        lock.unlock()
        return try await disconnectHandler()
    }

    func selectExit(_ exit: String) async throws -> KernelStatus {
        throw KernelControlError.transport
    }
}

private enum ReleaseFailureSamples {
    static let anchorFlush = "anchor_flush_failed"
}

private final class FakeRelease: ReleaseControlling, @unchecked Sendable {
    var restoreHandler: () async throws -> ReleaseReport = { ReleaseReport(
        anchorLoaded: false,
        resolverFilesRemoved: [],
        resolverFilesRemaining: [],
        dnsRestoredServices: [],
        dnsMissingServices: [],
        dnsMode: "system",
        intentCleared: true,
        snapshotCleared: true,
        failures: [],
        outcome: ReleaseOutcome.restored
    ) }
    private let lock = NSLock()
    private var calls = 0

    var restoreCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func restore() async throws -> ReleaseReport {
        lock.lock()
        calls += 1
        lock.unlock()
        return try await restoreHandler()
    }
}

extension ConnectionModel {
    /// Ask, then confirm, as the menu's two clicks do.
    fileprivate func confirmRestoreAfterAsking() async {
        requestRestoreNetwork()
        XCTAssertTrue(restoreNeedsConfirmation)
        await confirmRestoreNetwork()
    }
}
