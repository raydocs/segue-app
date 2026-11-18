import XCTest

@testable import SegueKit

@MainActor
final class ConnectionModelTests: XCTestCase {
    private let home = "/Users/example"

    func testStartsWithoutClaimingConnected() {
        let model = makeModel(client: FakeControlClient())
        XCTAssertEqual(model.statusLine, ConnectionModel.noStatusYet)
        XCTAssertFalse(model.showsConnected)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.lastError)
    }

    func testConnectAppliesReadback() async throws {
        let fake = FakeControlClient()
        let connected = try Fixtures.status("status-connected")
        fake.connectHandler = { connected }
        let model = makeModel(client: fake)
        await model.connect()
        XCTAssertTrue(model.showsConnected)
        XCTAssertEqual(model.statusLine, "Connected. Reconnect or update.")
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(fake.connectCalls, 1)
    }

    func testReconnectingReadbackIsNotConnected() async throws {
        let fake = FakeControlClient()
        let status = try Fixtures.status("status-reconnecting")
        fake.connectHandler = { status }
        let model = makeModel(client: fake)
        await model.connect()
        XCTAssertFalse(model.showsConnected)
        XCTAssertEqual(model.statusLine, "Reconnecting.")
    }

    func testFailureDoesNotClaimConnected() async {
        let fake = FakeControlClient()
        let secret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        fake.connectHandler = {
            throw KernelControlError.http(status: 401, message: "bad token \(secret)")
        }
        let model = makeModel(client: fake)
        await model.connect()
        XCTAssertFalse(model.showsConnected)
        XCTAssertEqual(model.statusLine, ConnectionModel.noStatusYet)
        XCTAssertEqual(model.lastError, "The kernel refused the control token.")
        XCTAssertFalse(model.lastError?.contains(secret) ?? true)
        XCTAssertFalse(model.isBusy)
    }

    func testFailureKeepsPreviousReadback() async throws {
        let fake = FakeControlClient()
        let connected = try Fixtures.status("status-connected")
        fake.connectHandler = { connected }
        fake.disconnectHandler = { throw KernelControlError.transport }
        let model = makeModel(client: fake)
        await model.connect()
        await model.disconnect()
        XCTAssertTrue(model.showsConnected)
        XCTAssertEqual(model.statusLine, "Connected. Reconnect or update.")
        XCTAssertEqual(model.lastError, "Couldn't reach the kernel on this Mac.")
    }

    func testDisconnectAppliesReadback() async throws {
        let fake = FakeControlClient()
        var disconnected = try Fixtures.status("status-disconnected")
        disconnected.revoked = false
        fake.disconnectHandler = { disconnected }
        let model = makeModel(client: fake)
        await model.disconnect()
        XCTAssertFalse(model.showsConnected)
        XCTAssertEqual(model.statusLine, "Not connected.")
    }

    func testPortMismatchMessageHidesTheAddress() async {
        let fake = FakeControlClient()
        fake.refreshHandler = {
            throw KernelControlError.portMismatch(filePort: 9277, requested: 1)
        }
        let model = makeModel(client: fake)
        await model.refresh()
        XCTAssertEqual(model.lastError, "The kernel control address is not 127.0.0.1.")
        XCTAssertFalse(model.lastError?.contains("9277") ?? true)
    }

    func testEnsureConfigFolderCreatesDirectory() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("segue-cfg-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        let model = ConnectionModel(
            client: FakeControlClient(),
            configFolder: folder,
            homePath: home
        )
        try model.ensureConfigFolder()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    private func makeModel(client: FakeControlClient) -> ConnectionModel {
        let folder = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Segue", isDirectory: true)
        return ConnectionModel(client: client, configFolder: folder, homePath: home)
    }
}

final class FakeControlClient: ControlClient, @unchecked Sendable {
    var statusHandler: () async throws -> KernelStatus
    var connectHandler: () async throws -> KernelStatus
    var disconnectHandler: () async throws -> KernelStatus
    var selectHandler: (String) async throws -> KernelStatus
    var refreshHandler: (() async throws -> KernelStatus)?
    private let lock = NSLock()
    private var connects = 0

    var connectCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return connects
    }

    init() {
        let fail: () async throws -> KernelStatus = { throw KernelControlError.transport }
        statusHandler = fail
        connectHandler = fail
        disconnectHandler = fail
        selectHandler = { _ in throw KernelControlError.transport }
    }

    func status() async throws -> KernelStatus {
        if let refreshHandler {
            return try await refreshHandler()
        }
        return try await statusHandler()
    }

    func connect() async throws -> KernelStatus {
        noteConnect()
        return try await connectHandler()
    }

    /// Synchronous so the lock is not taken from an async context.
    private func noteConnect() {
        lock.lock()
        connects += 1
        lock.unlock()
    }

    func disconnect() async throws -> KernelStatus {
        try await disconnectHandler()
    }

    func selectExit(_ exit: String) async throws -> KernelStatus {
        try await selectHandler(exit)
    }
}
