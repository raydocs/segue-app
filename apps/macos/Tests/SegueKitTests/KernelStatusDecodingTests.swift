import XCTest

@testable import SegueKit

final class KernelStatusDecodingTests: XCTestCase {
    func testConnectedFixture() throws {
        let status = try Fixtures.status("status-connected")
        XCTAssertEqual(status.state, .connected)
        XCTAssertEqual(status.posture, .connected)
        XCTAssertEqual(status.exitChoice, "ny")
        XCTAssertEqual(status.currentExit, "ny")
        XCTAssertEqual(status.exits, ["la", "ny"])
        XCTAssertFalse(status.revoked)
        XCTAssertEqual(status.controlRefused, [ControlRefusal(exit: "la", code: 1)])
        XCTAssertEqual(status.policy.source, .signed)
        XCTAssertTrue(status.policy.valid)
        XCTAssertEqual(status.policy.version, 7)
        XCTAssertEqual(status.policy.expiresAt, 1_893_456_000)
        XCTAssertEqual(status.policy.highWater, 7)
        XCTAssertEqual(status.tun.interfaceName, "utun4")
        XCTAssertEqual(status.tun.routes, .installed)
        XCTAssertTrue(status.showsConnected)
        XCTAssertEqual(status.statusLine, "Connected. Reconnect or update.")

        var quiet = status
        quiet.controlRefused = []
        XCTAssertEqual(quiet.statusLine, "Connected.")
        quiet.tun.routes = .absent
        XCTAssertFalse(quiet.showsConnected)
        XCTAssertEqual(quiet.statusLine, "The tunnel is not up.")
    }

    func testConnectedLiveExitQualityFixture() throws {
        let status = try Fixtures.status("status-connected-live-exits")
        XCTAssertEqual(status.state, .connected)
        XCTAssertEqual(status.exitChoice, "auto")
        XCTAssertEqual(status.currentExit, "us-west")
        XCTAssertEqual(status.exits, ["us-west", "jp-tokyo", "sg-edge"])
        XCTAssertEqual(status.exitDetails.count, 3)
        XCTAssertEqual(status.exitDetails[0].name, "us-west")
        XCTAssertEqual(status.exitDetails[0].quality?.srttMs, 142)
        XCTAssertEqual(status.exitDetails[0].quality?.loss, 0.0)
        XCTAssertEqual(status.exitDetails[0].quality?.stalls, 0)
        XCTAssertEqual(status.exitDetails[1].name, "jp-tokyo")
        XCTAssertEqual(status.exitDetails[1].quality?.srttMs, 68)
        XCTAssertNil(status.exitDetails[2].quality?.srttMs)
        XCTAssertEqual(status.exitDetails[2].quality?.stalls, 1)

        // Round-trip through JSON retains quality objects.
        let encoded = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(KernelStatus.self, from: encoded)
        XCTAssertEqual(decoded, status)
    }

    func testReconnectingFixture() throws {
        let status = try Fixtures.status("status-reconnecting")
        XCTAssertEqual(status.state, .reconnecting)
        XCTAssertEqual(status.posture, .connecting)
        XCTAssertEqual(status.exitChoice, "auto")
        XCTAssertEqual(status.currentExit, "la")
        XCTAssertEqual(status.policy.source, .inline)
        XCTAssertNil(status.policy.version)
        XCTAssertNil(status.policy.expiresAt)
        XCTAssertEqual(status.policy.highWater, 0)
        XCTAssertNil(status.tun.interfaceName)
        XCTAssertEqual(status.tun.routes, .absent)
        XCTAssertFalse(status.showsConnected)
        XCTAssertEqual(status.statusLine, "Reconnecting.")

        var withTun = status
        withTun.tun = TunState(interfaceName: "utun4", routes: .installed)
        XCTAssertFalse(withTun.showsConnected)
    }

    func testDisconnectedFixture() throws {
        let status = try Fixtures.status("status-disconnected")
        XCTAssertEqual(status.state, .disconnected)
        XCTAssertNil(status.currentExit)
        XCTAssertTrue(status.revoked)
        XCTAssertFalse(status.policy.valid)
        XCTAssertEqual(status.policy.highWater, 4)
        XCTAssertEqual(status.statusLine, "This device was revoked.")
        XCTAssertFalse(status.showsConnected)

        var clear = status
        clear.revoked = false
        XCTAssertEqual(clear.statusLine, "Not connected.")
    }

    func testErrorBodyFixture() throws {
        let body = try JSONDecoder().decode(KernelErrorBody.self, from: Fixtures.data(named: "error-bad-token"))
        XCTAssertEqual(body.error, "bad token")
    }

    func testTokenFileFixture() throws {
        let url = try fixtureURL("token-file")
        let creds = try ControlCredentials.load(from: url)
        XCTAssertEqual(creds.port, 9277)
        XCTAssertEqual(creds.token, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    }

    func testUnknownStateFails() throws {
        var text = String(decoding: try Fixtures.data(named: "status-connected"), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"connected\"", with: "\"potato\"")
        XCTAssertThrowsError(try JSONDecoder().decode(KernelStatus.self, from: Data(text.utf8)))
    }

    func testMissingTunFails() throws {
        var object = try JSONSerialization.jsonObject(with: Fixtures.data(named: "status-connected")) as! [String: Any]
        object.removeValue(forKey: "tun")
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(KernelStatus.self, from: data))
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let data = try Fixtures.data(named: name)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("segue-fixture-\(name)-\(UUID().uuidString).json")
        try data.write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
