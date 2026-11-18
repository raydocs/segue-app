import XCTest

@testable import SegueKit

final class HelperIPCTests: XCTestCase {
    func testProtocolVersionStartsAtOne() {
        XCTAssertEqual(HelperProtocolVersion.current, 1)
    }

    func testArmFixture() throws {
        let envelope = try Fixtures.envelope("helper-arm")
        XCTAssertEqual(envelope.version, 1)
        XCTAssertEqual(envelope.kind, .arm)
        let arm = try XCTUnwrap(envelope.arm)
        XCTAssertEqual(arm.schemaVersion, 1)
        XCTAssertEqual(arm.generation, 4)
        XCTAssertEqual(arm.intent, .userConnect)
        XCTAssertEqual(arm.anchorRevision, 3)
        XCTAssertEqual(arm.manifestDigest, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
        XCTAssertEqual(arm.egress, [EgressEndpoint(ip: "192.0.2.10", port: 443)])
        XCTAssertEqual(arm.exitIfaces, ["utun4"])
        XCTAssertFalse(arm.strict)
        XCTAssertEqual(arm.evidence.policyVersion, 7)
        XCTAssertEqual(arm.evidence.posture, "connecting")
        XCTAssertNil(envelope.disarm)
        XCTAssertNil(envelope.status)
        try assertRoundTrip(envelope)
    }

    func testDisarmFixture() throws {
        let envelope = try Fixtures.envelope("helper-disarm")
        XCTAssertEqual(envelope.kind, .disarm)
        XCTAssertEqual(envelope.disarm?.intent, .userDisconnect)
        XCTAssertEqual(envelope.disarm?.generation, 4)
        XCTAssertNil(envelope.arm)
        try assertRoundTrip(envelope)
    }

    func testStatusReadbackFixture() throws {
        let envelope = try Fixtures.envelope("helper-status")
        XCTAssertEqual(envelope.kind, .status)
        let status = try XCTUnwrap(envelope.status)
        XCTAssertTrue(status.armed)
        XCTAssertEqual(status.generation, 4)
        XCTAssertTrue(status.held)
        XCTAssertEqual(status.tunInterface, "utun4")
        XCTAssertEqual(status.rulesDigest, "abc123")
        XCTAssertEqual(status.evidence.tcpProofMs, 12)
        XCTAssertTrue(status.evidence.dnsReadback)
        XCTAssertNil(status.lastError)
        try assertRoundTrip(envelope)
    }

    func testStatusReadOmitsBodies() throws {
        let envelope = try Fixtures.envelope("helper-status-read")
        XCTAssertEqual(envelope, HelperEnvelope.statusRead())
        let data = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "status_read")
        XCTAssertNil(object["arm"])
        XCTAssertNil(object["disarm"])
        XCTAssertNil(object["status"])
    }

    func testRejectsWrongVersion() throws {
        XCTAssertThrowsError(try Fixtures.envelope("helper-version-2")) { error in
            XCTAssertEqual(error as? HelperProtocolError, .unsupportedVersion(2))
        }
    }

    func testRejectsUnknownDisarmIntent() {
        let json = #"{"version":1,"kind":"disarm","disarm":{"schemaVersion":1,"generation":1,"intent":"please"}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(HelperEnvelope.self, from: Data(json.utf8)))
    }

    func testRejectsArmWithoutBody() {
        let json = #"{"version":1,"kind":"arm"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(HelperEnvelope.self, from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? HelperProtocolError, .malformed)
        }
    }

    func testBuiltDisarmReasonsRoundTrip() throws {
        for reason in [DisarmReason.userDisconnect, .signOut, .quit] {
            let envelope = try HelperEnvelope.disarm(DisarmIntent(generation: 9, intent: reason))
            try assertRoundTrip(envelope)
            XCTAssertEqual(envelope.disarm?.intent, reason)
        }
    }

    private func assertRoundTrip(_ envelope: HelperEnvelope) throws {
        let data = try JSONEncoder().encode(envelope)
        let again = try JSONDecoder().decode(HelperEnvelope.self, from: data)
        XCTAssertEqual(again, envelope)
    }
}
