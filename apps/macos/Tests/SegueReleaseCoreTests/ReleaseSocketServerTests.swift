import Darwin
import Foundation
import SegueHelperCore
import SegueHelperProtocol
import XCTest

@testable import SegueReleaseCore

final class ReleaseSocketServerTests: XCTestCase {
    func testRestoreOverTheSocketClearsAnArmedMachineWithoutTheHelper() throws {
        let harness = try ReleaseHarness()
        defer { harness.stop() }
        try ArmedState.install(harness.commands, paths: harness.paths)

        let reply = try harness.roundTrip(#"{"version":1,"kind":"restore"}"#)
        XCTAssertEqual(reply.kind, .report)
        let report = try XCTUnwrap(reply.report)
        XCTAssertEqual(report.outcome, ReleaseOutcome.restored)
        XCTAssertFalse(report.anchorLoaded)
        XCTAssertEqual(report.resolverFilesRemaining, [])
        XCTAssertEqual(report.dnsMode, AILayerState.system)
        XCTAssertTrue(report.intentCleared)
        // A second request on a fresh connection answers the same way.
        let again = try harness.roundTrip(#"{"version":1,"kind":"restore"}"#)
        XCTAssertEqual(again.report?.outcome, ReleaseOutcome.restored)
    }

    func testDeniedPeerIsRefusedWithoutSideEffects() throws {
        let harness = try ReleaseHarness()
        defer { harness.stop() }
        try ArmedState.install(harness.commands, paths: harness.paths)

        harness.peers.set(PeerIdentity(uid: getuid() &+ 1, codeSigningSatisfied: true))
        let stranger = try ReleaseLineClient(path: harness.socketPath)
        defer { stranger.close() }
        let denied = try decodeReleaseEnvelope(stranger.read())
        XCTAssertEqual(denied.kind, .error)
        XCTAssertEqual(denied.error?.code, HelperErrorCode.unauthorized)
        // Nothing was touched: the machine is exactly as armed as before.
        XCTAssertTrue(harness.commands.anchorLoaded)
        XCTAssertNotNil(harness.commands.files[harness.paths.resolverDirectory + "/api.example"])
        XCTAssertNotNil(harness.commands.files[harness.paths.snapshotPath])
        XCTAssertFalse(harness.commands.invocations.contains { $0.contains("-F all") })

        harness.peers.set(PeerIdentity(uid: getuid(), codeSigningSatisfied: false))
        let unsigned = try ReleaseLineClient(path: harness.socketPath)
        defer { unsigned.close() }
        let rejected = try decodeReleaseEnvelope(unsigned.read())
        XCTAssertEqual(rejected.error?.code, HelperErrorCode.unauthorized)
        XCTAssertTrue(rejected.error?.message.contains("code_signing") == true)

        // The allowed peer still gets its restore afterwards.
        harness.peers.set(PeerIdentity(uid: getuid(), codeSigningSatisfied: true))
        let reply = try harness.roundTrip(#"{"version":1,"kind":"restore"}"#)
        XCTAssertEqual(reply.report?.outcome, ReleaseOutcome.restored)
    }

    func testUnknownVersionAndJunkAreErrorsNotCrashes() throws {
        let harness = try ReleaseHarness()
        defer { harness.stop() }

        let unknown = try harness.roundTrip(#"{"version":2,"kind":"restore"}"#)
        XCTAssertEqual(unknown.kind, .error)
        XCTAssertEqual(unknown.error?.code, HelperErrorCode.unsupportedVersion)
        XCTAssertEqual(unknown.version, ReleaseProtocolVersion.current)

        let junk = try harness.roundTrip("not-json")
        XCTAssertEqual(junk.error?.code, HelperErrorCode.malformed)

        // A reply-shaped request is not a verb the daemon accepts.
        let echoed = try harness.roundTrip(
            #"{"version":1,"kind":"report","report":{"anchor_loaded":false,"resolver_files_removed":[],"resolver_files_remaining":[],"dns_restored_services":[],"dns_missing_services":[],"dns_mode":"system","intent_cleared":true,"snapshot_cleared":true,"failures":[],"outcome":"restored"}}"#
        )
        XCTAssertEqual(echoed.error?.code, HelperErrorCode.malformed)

        // The daemon is still alive and serving.
        let reply = try harness.roundTrip(#"{"version":1,"kind":"restore"}"#)
        XCTAssertEqual(reply.report?.outcome, ReleaseOutcome.restored)
    }
}
