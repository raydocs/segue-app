import Foundation
import SegueAILayer
import SegueHelperCore
import SegueHelperProtocol
import XCTest

@testable import SegueReleaseCore

final class ReleaseRestorerTests: XCTestCase {
    func testRestoreClearsAnArmedMachine() throws {
        let harness = try ReleaseHarness()
        defer { harness.stop() }
        try ArmedState.install(harness.commands, paths: harness.paths)

        let report = harness.restorer.restore()

        XCTAssertEqual(report.outcome, ReleaseOutcome.restored)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(report.anchorLoaded)
        XCTAssertFalse(harness.commands.anchorLoaded)
        XCTAssertEqual(report.resolverFilesRemoved, ["api.example", "chat.example"])
        XCTAssertEqual(report.resolverFilesRemaining, [])
        // The foreign file, same servers but no marker, survives.
        XCTAssertEqual(
            harness.commands.files[harness.paths.resolverDirectory + "/other.example"],
            "nameserver 127.0.0.1\nport 5354\n"
        )
        // Saved servers are back: explicit on Wi-Fi, DHCP-empty on Ethernet.
        XCTAssertEqual(harness.commands.servers("Wi-Fi"), ["192.0.2.1"])
        XCTAssertEqual(harness.commands.servers("Ethernet"), [])
        XCTAssertEqual(report.dnsRestoredServices, ["Ethernet", "Wi-Fi"])
        XCTAssertEqual(report.dnsMissingServices, [])
        XCTAssertEqual(report.dnsMode, AILayerState.system)
        XCTAssertNil(harness.commands.files[harness.paths.snapshotPath])
        XCTAssertTrue(report.snapshotCleared)
        // The persisted intent is clear, so a helper restart will not re-arm.
        XCTAssertTrue(report.intentCleared)
        let stored = try IntentStore(fileURL: URL(fileURLWithPath: harness.intentPath)).load()
        XCTAssertEqual(stored?.armed, false)
        XCTAssertTrue(harness.commands.invocations.contains {
            $0.contains("-a segue.ailock -F all")
        })
    }

    func testRestoreIsIdempotent() throws {
        let harness = try ReleaseHarness()
        defer { harness.stop() }
        try ArmedState.install(harness.commands, paths: harness.paths)

        let first = harness.restorer.restore()
        XCTAssertEqual(first.outcome, ReleaseOutcome.restored)

        harness.commands.discardLog()
        let second = harness.restorer.restore()
        XCTAssertEqual(second.outcome, ReleaseOutcome.restored)
        XCTAssertTrue(second.failures.isEmpty)
        XCTAssertFalse(second.anchorLoaded)
        XCTAssertEqual(second.resolverFilesRemoved, [])
        XCTAssertEqual(second.resolverFilesRemaining, [])
        XCTAssertEqual(second.dnsMode, AILayerState.system)
        XCTAssertTrue(second.intentCleared)
        XCTAssertTrue(second.snapshotCleared)
        // Nothing to write: no flush, no removal, no DNS assignment.
        XCTAssertFalse(harness.commands.invocations.contains { $0.contains("-F all") })
        XCTAssertFalse(harness.commands.invocations.contains { $0.hasPrefix("remove ") })
        XCTAssertFalse(harness.commands.invocations.contains { $0.contains("-setdnsservers") })
        // The foreign file is still there after both passes.
        XCTAssertNotNil(harness.commands.files[harness.paths.resolverDirectory + "/other.example"])
    }

    func testRestoreOnACleanMachineWritesNothing() throws {
        let harness = try ReleaseHarness()
        defer { harness.stop() }

        let report = harness.restorer.restore()
        XCTAssertEqual(report.outcome, ReleaseOutcome.restored)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(report.anchorLoaded)
        XCTAssertEqual(report.resolverFilesRemoved, [])
        XCTAssertEqual(report.dnsMode, AILayerState.system)
        XCTAssertTrue(report.intentCleared)
        XCTAssertTrue(report.snapshotCleared)
        XCTAssertFalse(harness.commands.invocations.contains { $0.hasPrefix("remove ") })
        XCTAssertFalse(harness.commands.invocations.contains { $0.contains("-setdnsservers") })
    }

    func testFailedDNSRestoreKeepsTheSnapshotAndReportsPartial() throws {
        let harness = try ReleaseHarness()
        defer { harness.stop() }
        try ArmedState.install(harness.commands, paths: harness.paths)
        // The service the snapshot wants to rewrite refuses the write.
        harness.commands.failNext = "-setdnsservers Wi-Fi"

        let report = harness.restorer.restore()

        XCTAssertEqual(report.outcome, ReleaseOutcome.partial)
        XCTAssertEqual(report.failures, [ReleaseFailure.label(ReleaseFailure.dnsRestore, "Wi-Fi")])
        // The anchor and the files are still cleared; the snapshot survives
        // because the original servers were not put back.
        XCTAssertFalse(report.anchorLoaded)
        XCTAssertEqual(report.resolverFilesRemaining, [])
        XCTAssertFalse(report.snapshotCleared)
        XCTAssertNotNil(harness.commands.files[harness.paths.snapshotPath])
        // The other service was still put back; only Wi-Fi refused.
        XCTAssertEqual(report.dnsRestoredServices, ["Ethernet"])
        XCTAssertEqual(harness.commands.servers("Wi-Fi"), ["127.0.0.1"])
        XCTAssertEqual(harness.commands.servers("Ethernet"), [])
    }

    func testUnflushableAnchorReportsPartialAndKeepsItsWord() throws {
        let harness = try ReleaseHarness()
        defer { harness.stop() }
        try ArmedState.install(harness.commands, paths: harness.paths)
        harness.commands.failNext = "-F all"

        let report = harness.restorer.restore()

        XCTAssertEqual(report.outcome, ReleaseOutcome.partial)
        XCTAssertTrue(report.failures.contains(ReleaseFailure.anchorFlush))
        // The read-back tells the truth: the anchor is still loaded.
        XCTAssertTrue(report.anchorLoaded)
        XCTAssertEqual(report.resolverFilesRemaining, [])
        XCTAssertEqual(report.dnsRestoredServices, ["Ethernet", "Wi-Fi"])
        XCTAssertTrue(report.intentCleared)
    }

    func testMissingServicesInSnapshotAreReportedNotRestored() throws {
        let harness = try ReleaseHarness()
        defer { harness.stop() }
        try ArmedState.install(harness.commands, paths: harness.paths)
        // The service disappeared after the capture.
        harness.commands.dropService(named: "Ethernet")

        let report = harness.restorer.restore()

        XCTAssertEqual(report.outcome, ReleaseOutcome.restored)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.dnsMissingServices, ["Ethernet"])
        XCTAssertEqual(report.dnsRestoredServices, ["Wi-Fi"])
        XCTAssertTrue(report.snapshotCleared)
    }
}
