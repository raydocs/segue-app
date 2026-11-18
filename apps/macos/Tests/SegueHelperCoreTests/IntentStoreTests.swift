import XCTest

@testable import SegueHelperCore

final class IntentStoreTests: XCTestCase {
    func testSaveIsMode0600AndDirectory0700() throws {
        let root = try temporaryDirectory("segue-intent")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Segue/ai-lock.intent")
        let store = IntentStore(fileURL: url)
        let armed = StoredIntent(armed: true, generation: 4, name: "user_connect")
        try store.save(armed)
        XCTAssertEqual(try posixMode(at: url), 0o600)
        XCTAssertEqual(try posixMode(at: url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try store.load(), armed)

        let disarmed = StoredIntent(armed: false, generation: 5, name: "user_disconnect")
        try store.save(disarmed)
        XCTAssertEqual(try posixMode(at: url), 0o600)
        XCTAssertEqual(try store.load(), disarmed)
    }

    func testMissingAndCorruptLoad() throws {
        let root = try temporaryDirectory("segue-intent")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ai-lock.intent")
        let store = IntentStore(fileURL: url)
        XCTAssertNil(try store.load())
        try Data("not-json".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
    }
}

final class HelperPathsTests: XCTestCase {
    func testProductionDefaults() {
        XCTAssertEqual(HelperPaths.production.socketPath, "/var/run/segue/service.sock")
        XCTAssertEqual(
            HelperPaths.production.intentPath,
            "/Library/Application Support/Segue/ai-lock.intent"
        )
    }

    func testParseOverridesFlags() {
        let paths = HelperPaths.parse([
            "segue-core-helper",
            "--socket", "/tmp/segue.sock",
            "--intent", "/tmp/ai-lock.intent",
            "--kernel", "/tmp/segue-kernel",
            "--config", "/tmp/kernel.json",
            "--state-dir", "/tmp/state",
            "--allowed-uids", "/tmp/uids",
            "--unknown", "skip-me",
        ])
        XCTAssertEqual(paths.socketPath, "/tmp/segue.sock")
        XCTAssertEqual(paths.intentPath, "/tmp/ai-lock.intent")
        XCTAssertEqual(paths.kernelPath, "/tmp/segue-kernel")
        XCTAssertEqual(paths.configPath, "/tmp/kernel.json")
        XCTAssertEqual(paths.stateDir, "/tmp/state")
        XCTAssertEqual(paths.allowedUIDFile, "/tmp/uids")
    }
}
