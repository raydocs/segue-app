import Darwin
import SegueHelperProtocol
import XCTest

@testable import SegueHelperCore

final class HelperSocketServerTests: XCTestCase {
    func testStatusArmAndDisarmOnATempSocket() throws {
        let harness = try HelperHarness()
        defer { harness.stop() }

        let first = try harness.roundTrip(#"{"version":1,"kind":"status_read"}"#)
        XCTAssertEqual(first.kind, .status)
        let status = try XCTUnwrap(first.status)
        XCTAssertFalse(status.armed)
        XCTAssertEqual(status.generation, 0)
        XCTAssertFalse(status.held)
        XCTAssertNil(status.tunInterface)
        XCTAssertFalse(status.evidence.dnsReadback)
        XCTAssertEqual(status.aiLayer, AILayerState.system)
        XCTAssertEqual(status.dnsMode, AILayerState.system)
        XCTAssertEqual(status.anchorLoaded, false)
        XCTAssertEqual(status.resolverFilesPresent, false)
        XCTAssertEqual(status.guardListening, false)
        XCTAssertEqual(status.helper?.state, "running")
        XCTAssertEqual(status.kernel?.state, "stopped")
        XCTAssertNil(status.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.intentURL.path))
        XCTAssertEqual(harness.launcher.procs.count, 0)

        let armed = try harness.roundTrip(HelperFixtures.minified("helper-arm"))
        XCTAssertEqual(armed.status?.armed, true)
        XCTAssertEqual(armed.status?.generation, 4)
        XCTAssertEqual(armed.status?.held, true)
        XCTAssertEqual(armed.status?.aiLayer, AILayerState.guardMode)
        XCTAssertEqual(armed.status?.dnsMode, "guard")
        XCTAssertEqual(armed.status?.anchorLoaded, true)
        XCTAssertEqual(armed.status?.resolverFilesPresent, true)
        XCTAssertEqual(armed.status?.guardListening, true)
        // Arm starts the kernel: the guard goes in first, then the child.
        XCTAssertEqual(armed.status?.kernel?.state, "running")
        XCTAssertEqual(armed.status?.kernel?.pid, harness.launcher.latest.pid)
        XCTAssertEqual(harness.launcher.procs.count, 1)
        XCTAssertEqual(try posixMode(at: harness.intentURL), 0o600)
        let stored = try IntentStore(fileURL: harness.intentURL).load()
        XCTAssertEqual(stored, StoredIntent(armed: true, generation: 4, name: "user_connect"))

        let unknown = try harness.roundTrip(HelperFixtures.minified("helper-version-2"))
        XCTAssertEqual(unknown.kind, .error)
        XCTAssertEqual(unknown.error?.code, HelperErrorCode.unsupportedVersion)
        XCTAssertEqual(unknown.version, 1)

        let junk = try harness.roundTrip("not-json")
        XCTAssertEqual(junk.error?.code, HelperErrorCode.malformed)

        let still = try harness.roundTrip(#"{"version":1,"kind":"status_read"}"#)
        XCTAssertEqual(still.status?.armed, true)
        XCTAssertEqual(still.status?.generation, 4)

        let disarmed = try harness.roundTrip(HelperFixtures.minified("helper-disarm"))
        XCTAssertEqual(disarmed.status?.armed, false)
        XCTAssertEqual(disarmed.status?.generation, 4)
        XCTAssertEqual(disarmed.status?.held, false)
        XCTAssertEqual(disarmed.status?.aiLayer, AILayerState.system)
        XCTAssertEqual(disarmed.status?.dnsMode, AILayerState.system)
        XCTAssertEqual(disarmed.status?.anchorLoaded, false)
        XCTAssertEqual(disarmed.status?.resolverFilesPresent, false)
        XCTAssertEqual(disarmed.status?.guardListening, false)
        XCTAssertEqual(try posixMode(at: harness.intentURL), 0o600)
        XCTAssertEqual(
            try IntentStore(fileURL: harness.intentURL).load()?.name,
            "user_disconnect"
        )
        // The layer released before the kernel stopped: the child saw
        // SIGTERM only after the restore ran, and nothing relaunched.
        XCTAssertEqual(disarmed.status?.kernel?.state, "stopped")
        XCTAssertEqual(harness.launcher.procs.count, 1)
        XCTAssertEqual(harness.launcher.latest.signals, [SIGTERM])
    }

    func testDeniedPeerDoesNotPersist() throws {
        let harness = try HelperHarness()
        defer { harness.stop() }
        harness.peers.set(PeerIdentity(uid: getuid() &+ 1, codeSigningSatisfied: true))
        let client = try LineClient(path: harness.socketPath)
        defer { client.close() }
        let denied = try decodeEnvelope(client.read())
        XCTAssertEqual(denied.error?.code, HelperErrorCode.unauthorized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.intentURL.path))

        harness.peers.set(PeerIdentity(uid: getuid(), codeSigningSatisfied: false))
        let again = try LineClient(path: harness.socketPath)
        defer { again.close() }
        let unsigned = try decodeEnvelope(again.read())
        XCTAssertEqual(unsigned.error?.code, HelperErrorCode.unauthorized)
        XCTAssertTrue(unsigned.error?.message.contains("code_signing") == true)

        harness.peers.set(PeerIdentity(uid: getuid(), codeSigningSatisfied: true))
        let allowed = try harness.roundTrip(#"{"version":1,"kind":"status_read"}"#)
        XCTAssertEqual(allowed.status?.aiLayer, AILayerState.system)
        XCTAssertEqual(allowed.status?.kernel?.state, "stopped")
    }

    func testStatusReportsKernelFailed() throws {
        let harness = try HelperHarness()
        defer { harness.stop() }
        try harness.supervisor.start()
        for _ in 1...10 {
            harness.launcher.latest.finish(.code(1))
        }
        harness.launcher.latest.finish(.code(1))
        let reply = try harness.roundTrip(#"{"version":1,"kind":"status_read"}"#)
        XCTAssertEqual(reply.status?.kernel?.state, "kernel_failed")
        XCTAssertEqual(reply.status?.lastError, "kernel_failed")
        XCTAssertEqual(reply.status?.aiLayer, AILayerState.system)
        XCTAssertFalse(reply.status?.armed ?? true)
    }
}
