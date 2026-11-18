import XCTest

@testable import SegueKit

final class KernelControlClientTests: XCTestCase {
    private var directory: URL!
    private let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private let port: UInt16 = 9277

    override func setUp() async throws {
        directory = try temporaryDirectory("segue-ctl")
        StubURLProtocol.setHandler(nil)
    }

    override func tearDown() async throws {
        StubURLProtocol.setHandler(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    func testStatusSendsBearerToLoopback() async throws {
        let file = try writeTokenFile(addr: "127.0.0.1:\(port)", token: token, in: directory)
        let payload = try Fixtures.data(named: "status-connected")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.url?.port, Int(self.port))
            XCTAssertEqual(request.url?.path, "/v1/status")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.token)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Host"), "127.0.0.1:\(self.port)")
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            return (200, payload)
        }
        let client = KernelControlClient(port: port, tokenFile: file, session: stubSession())
        let status = try await client.status()
        XCTAssertTrue(status.showsConnected)
        XCTAssertEqual(status.tun.interfaceName, "utun4")
    }

    func testLocalhostAddrStillDials127() async throws {
        let file = try writeTokenFile(addr: "localhost:\(port)", token: token, in: directory)
        let payload = try Fixtures.data(named: "status-reconnecting")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            return (200, payload)
        }
        let client = KernelControlClient(port: port, tokenFile: file, session: stubSession())
        let status = try await client.status()
        XCTAssertEqual(status.state, .reconnecting)
    }

    func testConnectAndExitBodies() async throws {
        let file = try writeTokenFile(addr: "127.0.0.1:\(port)", token: token, in: directory)
        let payload = try Fixtures.data(named: "status-disconnected")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/connect")
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            return (200, payload)
        }
        let client = KernelControlClient(port: port, tokenFile: file, session: stubSession())
        _ = try await client.connect()

        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/v1/exit")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = requestBody(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(object["exit"], "ny")
            return (200, payload)
        }
        _ = try await client.selectExit("ny")
    }

    func testHTTPErrorDoesNotEchoToken() async throws {
        let file = try writeTokenFile(addr: "127.0.0.1:\(port)", token: token, in: directory)
        let body = Data(#"{"error":"bad token \#(token)"}"#.utf8)
        StubURLProtocol.setHandler { _ in (401, body) }
        let client = KernelControlClient(port: port, tokenFile: file, session: stubSession())
        do {
            _ = try await client.status()
            XCTFail("expected http error")
        } catch let KernelControlError.http(status, message) {
            XCTAssertEqual(status, 401)
            XCTAssertFalse(message.contains(token))
            XCTAssertEqual(message, "request failed")
        }
    }

    func testErrorFixtureMessage() async throws {
        let file = try writeTokenFile(addr: "127.0.0.1:\(port)", token: token, in: directory)
        let body = try Fixtures.data(named: "error-bad-token")
        StubURLProtocol.setHandler { _ in (401, body) }
        let client = KernelControlClient(port: port, tokenFile: file, session: stubSession())
        do {
            _ = try await client.disconnect()
            XCTFail("expected http error")
        } catch let KernelControlError.http(status, message) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "bad token")
        }
    }

    func testPortMismatchDoesNotDial() async throws {
        let file = try writeTokenFile(addr: "127.0.0.1:\(port)", token: token, in: directory)
        var called = false
        StubURLProtocol.setHandler { _ in
            called = true
            return (200, Data("{}".utf8))
        }
        let client = KernelControlClient(port: 1, tokenFile: file, session: stubSession())
        do {
            _ = try await client.status()
            XCTFail("expected mismatch")
        } catch let error as KernelControlError {
            XCTAssertEqual(error, .portMismatch(filePort: port, requested: 1))
        }
        XCTAssertFalse(called)
    }

    func testNonLoopbackDoesNotDial() async throws {
        let file = try writeTokenFile(addr: "203.0.113.5:80", token: token, in: directory)
        var called = false
        StubURLProtocol.setHandler { _ in
            called = true
            return (200, Data())
        }
        let client = KernelControlClient(port: 80, tokenFile: file, session: stubSession())
        do {
            _ = try await client.status()
            XCTFail("expected refusal")
        } catch let error as KernelControlError {
            XCTAssertEqual(error, .tokenNotLoopback)
        }
        XCTAssertFalse(called)
    }

    func testIPv6LoopbackIsNotDialed() async throws {
        let file = try writeTokenFile(addr: "[::1]:\(port)", token: token, in: directory)
        var called = false
        StubURLProtocol.setHandler { _ in
            called = true
            return (200, Data())
        }
        let resolving = ResolvingKernelControlClient(tokenFile: file, session: stubSession())
        do {
            _ = try await resolving.status()
            XCTFail("expected refusal")
        } catch let error as KernelControlError {
            XCTAssertEqual(error, .tokenNotLoopback)
        }
        XCTAssertFalse(called)
    }

    func testNewlineTokenIsRejected() throws {
        let url = directory.appendingPathComponent("control.json")
        let raw = "{\"addr\":\"127.0.0.1:9\",\"token\":\"abcdefgh\\nijklmnop\"}"
        try Data(raw.utf8).write(to: url)
        XCTAssertThrowsError(try ControlCredentials.load(from: url)) { error in
            XCTAssertEqual(error as? KernelControlError, .tokenFileInvalid)
        }
    }

    func testResolvingClientUsesFilePort() async throws {
        let file = try writeTokenFile(addr: "127.0.0.1:\(port)", token: token, in: directory)
        let payload = try Fixtures.data(named: "status-connected")
        StubURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.port, Int(self.port))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.token)")
            return (200, payload)
        }
        let client = ResolvingKernelControlClient(tokenFile: file, session: stubSession())
        let status = try await client.connect()
        XCTAssertEqual(status.currentExit, "ny")
    }

    func testMissingTokenFile() async throws {
        let missing = directory.appendingPathComponent("absent.json")
        let client = KernelControlClient(port: port, tokenFile: missing, session: stubSession())
        do {
            _ = try await client.status()
            XCTFail("expected unreadable")
        } catch let error as KernelControlError {
            XCTAssertEqual(error, .tokenFileUnreadable)
        }
    }
}
