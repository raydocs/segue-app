import Darwin
import Foundation
import Security
import XCTest

@testable import SegueHelperCore

final class PeerAuthorizationTests: XCTestCase {
    private let requirement = SegueCodeSigning.requirement

    func testAllowsOnlyListedUIDWithSigning() {
        let policy = PeerPolicy(allowedUIDs: [501, 502], requirement: requirement)
        XCTAssertEqual(
            authorize(peer: PeerIdentity(uid: 502, codeSigningSatisfied: true), policy: policy),
            .allow
        )
    }

    func testRejectsUIDBeforeSigning() {
        let policy = PeerPolicy(allowedUIDs: [501], requirement: requirement)
        XCTAssertEqual(
            authorize(peer: PeerIdentity(uid: 1, codeSigningSatisfied: true), policy: policy),
            .deny(.uid)
        )
        XCTAssertEqual(
            authorize(peer: PeerIdentity(uid: 1, codeSigningSatisfied: false), policy: policy),
            .deny(.uid)
        )
    }

    func testRejectsFailedSigningWhenUIDMatches() {
        let policy = PeerPolicy(allowedUIDs: [501], requirement: requirement)
        XCTAssertEqual(
            authorize(peer: PeerIdentity(uid: 501, codeSigningSatisfied: false), policy: policy),
            .deny(.codeSigning)
        )
    }

    func testEmptyAllowListAndBlankRequirementDeny() {
        XCTAssertEqual(
            authorize(
                peer: PeerIdentity(uid: 501, codeSigningSatisfied: true),
                policy: PeerPolicy(allowedUIDs: [], requirement: requirement)
            ),
            .deny(.uid)
        )
        XCTAssertEqual(
            authorize(
                peer: PeerIdentity(uid: 501, codeSigningSatisfied: true),
                policy: PeerPolicy(allowedUIDs: [501], requirement: "  ")
            ),
            .deny(.codeSigning)
        )
        XCTAssertEqual(
            authorize(
                peer: PeerIdentity(uid: 501, codeSigningSatisfied: true),
                policy: PeerPolicy(allowedUIDs: [501], requirement: "")
            ),
            .deny(.codeSigning)
        )
    }

    func testRequirementNamesSegueAndParses() throws {
        XCTAssertTrue(requirement.contains("identifier \"com.raydocs.segue\""))
        XCTAssertTrue(requirement.contains("leaf[subject.OU] = \"YY57758GS7\""))
        XCTAssertTrue(requirement.contains("entitlement[\"com.apple.security.get-task-allow\"] absent"))
        var parsed: SecRequirement?
        let status = SecRequirementCreateWithString(
            requirement as CFString,
            SecCSFlags(rawValue: 0),
            &parsed
        )
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertNotNil(parsed)
        _ = try DarwinPeerCredentials(requirement: requirement)
    }

    func testAllowedUIDFileSkipsCommentsAndJunk() {
        let text = """
        # the logged-in user
        501

        nope
        502
        """
        XCTAssertEqual(parseAllowedUIDs(text), [501, 502])
        XCTAssertEqual(parseAllowedUIDs(""), [])
        XCTAssertEqual(parseAllowedUIDs("# only\n\n"), [])
    }
}
