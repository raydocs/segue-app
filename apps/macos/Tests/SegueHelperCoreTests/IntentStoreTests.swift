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
        XCTAssertEqual(
            HelperPaths.production.kernelLogPath,
            "/Library/Application Support/Segue/kernel.log"
        )
        XCTAssertEqual(
            HelperPaths.production.controlTokenPath,
            "/Library/Application Support/Segue/kernel/control.json"
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
            "--kernel-log", "/tmp/kernel.log",
            "--control-token", "/tmp/control.json",
            "--allowed-uids", "/tmp/uids",
            "--unknown", "skip-me",
        ])
        XCTAssertEqual(paths.socketPath, "/tmp/segue.sock")
        XCTAssertEqual(paths.intentPath, "/tmp/ai-lock.intent")
        XCTAssertEqual(paths.kernelPath, "/tmp/segue-kernel")
        XCTAssertEqual(paths.configPath, "/tmp/kernel.json")
        XCTAssertEqual(paths.stateDir, "/tmp/state")
        XCTAssertEqual(paths.kernelLogPath, "/tmp/kernel.log")
        XCTAssertEqual(paths.controlTokenPath, "/tmp/control.json")
        XCTAssertEqual(paths.allowedUIDFile, "/tmp/uids")
        XCTAssertEqual(paths.guardPort, 5354)
        XCTAssertEqual(paths.pfConfPath, "/etc/pf.conf")
        XCTAssertEqual(paths.resolverDirectory, "/etc/resolver")
        XCTAssertEqual(paths.pfctlPath, "/sbin/pfctl")
        XCTAssertEqual(paths.requirement, "")
    }

    func testPathsRootThenExplicitFlags() {
        let paths = HelperPaths.parse([
            "segue-core-helper",
            "--paths-root", "/tmp/segue-dev",
            "--socket", "/tmp/explicit.sock",
            "--guard-port", "15354",
            "--ai-lock", "/tmp/segue-dev/ai-lock.fixture.txt",
            "--pfctl", "/tmp/segue-dev/bin/pfctl",
            "--requirement", "identifier \"com.example.dev\"",
        ])
        XCTAssertEqual(paths.socketPath, "/tmp/explicit.sock")
        XCTAssertEqual(paths.intentPath, "/tmp/segue-dev/ai-lock.intent")
        XCTAssertEqual(paths.kernelPath, "/tmp/segue-dev/bin/segue-kernel")
        XCTAssertEqual(paths.configPath, "/tmp/segue-dev/kernel.json")
        XCTAssertEqual(paths.stateDir, "/tmp/segue-dev/kernel")
        XCTAssertEqual(paths.kernelLogPath, "/tmp/segue-dev/kernel.log")
        XCTAssertEqual(paths.controlTokenPath, "/tmp/segue-dev/kernel/control.json")
        XCTAssertEqual(paths.allowedUIDFile, "/tmp/segue-dev/allowed-uid")
        XCTAssertEqual(paths.aiLockPath, "/tmp/segue-dev/ai-lock.fixture.txt")
        XCTAssertEqual(paths.pfConfPath, "/tmp/segue-dev/etc/pf.conf")
        XCTAssertEqual(paths.resolverDirectory, "/tmp/segue-dev/etc/resolver")
        XCTAssertEqual(paths.pfctlPath, "/tmp/segue-dev/bin/pfctl")
        XCTAssertEqual(paths.guardPort, 15354)
        XCTAssertEqual(paths.requirement, "identifier \"com.example.dev\"")
    }
}
