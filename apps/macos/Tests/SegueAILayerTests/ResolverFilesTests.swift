import XCTest

@testable import SegueAILayer

final class ResolverFilesTests: XCTestCase {
    func testRendersOneFilePerSuffixWithTheGuardPort() throws {
        let files = try ResolverFiles.render(suffixes: ["api.example", "chat.example"], port: 5354)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files["api.example"], "nameserver 127.0.0.1\nport 5354\n")
        XCTAssertEqual(files["chat.example"], "nameserver 127.0.0.1\nport 5354\n")
    }

    func testSuffixesAreNormalizedIntoFilenames() throws {
        let files = try ResolverFiles.render(suffixes: ["API.Example."], port: 53)
        XCTAssertEqual(Set(files.keys), ["api.example"])
        XCTAssertEqual(files["api.example"], "nameserver 127.0.0.1\nport 53\n")
    }

    func testKernelListSuffixesAllRender() throws {
        let list = try AILockList.parse(try AIFixtures.text(named: "ai-lock"))
        let files = try ResolverFiles.render(suffixes: list.suffixes, port: 5354)
        XCTAssertEqual(files.count, list.suffixes.count)
        XCTAssertNotNil(files["anthropic.com"])
        XCTAssertNotNil(files["claude.ai"])
    }

    func testSuffixesThatAreNotPlainNamesAreRejected() {
        for bad in ["", "a/b.example", "under_score.example", "..", "a..b.example"] {
            XCTAssertThrowsError(
                try ResolverFiles.render(suffixes: [bad], port: 5354),
                "expected rejection for \(bad)"
            ) { error in
                XCTAssertEqual(error as? ResolverFileError, .invalidSuffix(bad))
            }
        }
    }

    func testPortZeroIsRejected() {
        XCTAssertThrowsError(
            try ResolverFiles.render(suffixes: ["api.example"], port: 0)
        ) { error in
            XCTAssertEqual(error as? ResolverFileError, .invalidPort(0))
        }
    }
}

final class DNSSnapshotTests: XCTestCase {
    private let wiFi = DNSServiceRecord(
        serviceID: "B6E0-1", name: "Wi-Fi", servers: ["192.168.1.1"])
    private let ethernet = DNSServiceRecord(
        serviceID: "ETH-9", name: "Ethernet", servers: ["2001:db8::1", "198.51.100.53"])

    func testCaptureRoundTripsAsData() throws {
        let snapshot = DNSSnapshot(services: [wiFi, ethernet])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DNSSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.schemaVersion, DNSSnapshot.currentSchema)
    }

    func testDuplicateServiceIDsKeepTheLastCapture() {
        let later = DNSServiceRecord(serviceID: "B6E0-1", name: "Wi-Fi", servers: ["10.0.0.1"])
        let snapshot = DNSSnapshot(services: [wiFi, later])
        XCTAssertEqual(snapshot.services, [later])
    }

    func testRestorePlanRewritesChangedServices() {
        let snapshot = DNSSnapshot(services: [wiFi, ethernet])
        let now = [
            // Wi-Fi was pointed at the guard; Ethernet was never touched.
            DNSServiceRecord(serviceID: "B6E0-1", name: "Wi-Fi", servers: ["127.0.0.1"]),
            ethernet,
        ]
        let plan = snapshot.restorePlan(current: now)
        XCTAssertEqual(plan.restores.map(\.record.serviceID), ["B6E0-1"])
        XCTAssertEqual(plan.restores.first?.record.servers, ["192.168.1.1"])
        XCTAssertEqual(plan.restores.first?.currentServers, ["127.0.0.1"])
        XCTAssertEqual(plan.alreadyCurrent.map(\.serviceID), ["ETH-9"])
        XCTAssertTrue(plan.missingServices.isEmpty)
        XCTAssertTrue(plan.newServices.isEmpty)
        XCTAssertFalse(plan.isEmpty)
    }

    func testRestorePlanFlagsMissingAndNewServices() {
        let snapshot = DNSSnapshot(services: [wiFi, ethernet])
        let now = [
            wiFi,
            DNSServiceRecord(serviceID: "NEW-2", name: "Thunderbolt", servers: ["192.0.2.53"]),
        ]
        let plan = snapshot.restorePlan(current: now)
        XCTAssertTrue(plan.restores.isEmpty)
        XCTAssertEqual(plan.missingServices.map(\.serviceID), ["ETH-9"])
        XCTAssertEqual(plan.newServices.map(\.serviceID), ["NEW-2"])
        XCTAssertFalse(plan.isEmpty, "a lost capture is worth reporting")
    }

    func testRestorePlanIsEmptyWhenEverythingMatches() {
        let snapshot = DNSSnapshot(services: [wiFi])
        XCTAssertTrue(snapshot.restorePlan(current: [wiFi]).isEmpty)
    }

    func testEmptyServersCaptureIsARestoreTarget() {
        // A service with no explicit resolvers (DHCP) snapshots as empty and
        // restores to empty, which must not read as "already changed".
        let dhcp = DNSServiceRecord(serviceID: "D-1", name: "Wi-Fi", servers: [])
        let snapshot = DNSSnapshot(services: [dhcp])
        let now = DNSServiceRecord(serviceID: "D-1", name: "Wi-Fi", servers: ["127.0.0.1"])
        let plan = snapshot.restorePlan(current: [now])
        XCTAssertEqual(plan.restores.first?.record.servers, [])
        XCTAssertEqual(plan.restores.first?.currentServers, ["127.0.0.1"])
    }

    func testBlankServerEntriesAreDroppedOnInit() {
        let record = DNSServiceRecord(serviceID: "S-1", name: "Wi-Fi", servers: ["  ", "192.0.2.53"])
        XCTAssertEqual(record.servers, ["192.0.2.53"])
    }
}
