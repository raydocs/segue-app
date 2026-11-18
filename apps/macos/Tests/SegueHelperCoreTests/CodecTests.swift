import Foundation
import SegueHelperProtocol
import XCTest

final class CodecTests: XCTestCase {
    func testFixtureRoundTrips() throws {
        for name in ["helper-arm", "helper-disarm", "helper-status", "helper-status-read"] {
            let data = try HelperFixtures.data(name)
            let envelope = try JSONDecoder().decode(HelperEnvelope.self, from: data)
            let again = try JSONDecoder().decode(
                HelperEnvelope.self,
                from: JSONEncoder().encode(envelope)
            )
            XCTAssertEqual(again, envelope, name)
        }
    }

    func testStatusFixtureLeavesStageFieldsUnset() throws {
        let envelope = try JSONDecoder().decode(
            HelperEnvelope.self,
            from: HelperFixtures.data("helper-status")
        )
        let status = try XCTUnwrap(envelope.status)
        XCTAssertNil(status.aiLayer)
        XCTAssertNil(status.helper)
        XCTAssertNil(status.kernel)
        XCTAssertEqual(status.tunInterface, "utun4")
    }

    func testRejectsVersionTwo() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(
            HelperEnvelope.self,
            from: HelperFixtures.data("helper-version-2")
        )) { error in
            XCTAssertEqual(error as? HelperProtocolError, .unsupportedVersion(2))
        }
    }

    func testRejectsArmWithoutBody() {
        let json = Data(#"{"version":1,"kind":"arm"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(HelperEnvelope.self, from: json)) { error in
            XCTAssertEqual(error as? HelperProtocolError, .malformed)
        }
    }

    func testFailureAndExtendedStatusRoundTrip() throws {
        let failure = HelperEnvelope.failure(
            code: HelperErrorCode.unsupportedVersion,
            message: "unsupported protocol version 2"
        )
        let failureAgain = try JSONDecoder().decode(
            HelperEnvelope.self,
            from: JSONEncoder().encode(failure)
        )
        XCTAssertEqual(failureAgain, failure)

        let status = HelperEnvelope.status(HelperStatus(
            armed: true,
            generation: 4,
            held: false,
            tunInterface: nil,
            rulesDigest: "",
            evidence: StatusEvidence(tcpProofMs: nil, dnsReadback: false),
            lastError: nil,
            aiLayer: AILayerState.notImplemented,
            helper: HelperProcessReport(state: "running"),
            kernel: KernelReport(state: "stopped", pid: nil, lastExit: nil)
        ))
        let again = try JSONDecoder().decode(HelperEnvelope.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(again, status)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any]
        )
        let body = try XCTUnwrap(object["status"] as? [String: Any])
        XCTAssertEqual(body["ai_layer"] as? String, "not_implemented")
        XCTAssertNil(body["arm"])
    }
}
