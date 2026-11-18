import Darwin
import Foundation
import XCTest

@testable import SegueHelperCore

/// One-connection TCP server on loopback that speaks just enough HTTP for
/// the kernel's control API: read one request head, answer JSON, close.
private final class ControlStub {
    private let fd: Int32
    let port: UInt16
    private var done = DispatchSemaphore(value: 0)
    private(set) var requests: [String] = []
    private let reply: String

    init(reply: String) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.failed("socket", errno) }
        var on = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            _ = Darwin.close(fd)
            throw UnixSocketError.failed("bind", errno)
        }
        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &name) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        // sin_port is already in network order; ntohs for the number.
        self.fd = fd
        self.port = UInt16(bigEndian: name.sin_port)
        self.reply = reply
    }

    func start() {
        let thread = Thread { [weak self] in
            self?.serve()
        }
        thread.name = "control-stub"
        thread.start()
    }

    func stop() {
        _ = Darwin.close(fd)
        _ = done.wait(timeout: .now() + 2)
    }

    private func serve() {
        // Two connections: one for the status read, one for the connect
        // post. The thread then exits, so `stop` never waits on a close
        // that would not wake a blocked accept.
        for _ in 0..<2 {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { break }
            answer(client)
        }
        done.signal()
    }

    private func answer(_ client: Int32) {
        defer { _ = Darwin.close(client) }
        setReceiveTimeout(client, seconds: 2)
        var head = ""
        var chunk = [UInt8](repeating: 0, count: 1024)
        while !head.contains("\r\n\r\n") {
            let got = recv(client, &chunk, chunk.count, 0)
            guard got > 0 else { return }
            head += String(bytes: chunk[0..<got], encoding: .utf8) ?? ""
        }
        requests.append(head)
        let body = reply
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" +
            "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        response.withCString { pointer in
            var sent = 0
            let total = response.utf8.count
            while sent < total {
                let wrote = send(client, pointer + sent, total - sent, 0)
                guard wrote > 0 else { return }
                sent += wrote
            }
        }
        _ = Darwin.shutdown(client, SHUT_WR)
    }
}

final class KernelControlClientTests: XCTestCase {
    private static let statusBody = #"""
    {"state":"connected","posture":"connected","tun":{"interface":"utun7","routes":"installed"}}
    """#

    func testParseStatusFromTheControlBody() throws {
        let data = Data(Self.statusBody.utf8)
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        )
        let status = try XCTUnwrap(LiveKernelControlClient.parseStatus(object))
        XCTAssertEqual(status.state, "connected")
        XCTAssertEqual(status.tunInterface, "utun7")
        XCTAssertEqual(status.routes, "installed")
        XCTAssertTrue(status.tunnelUp)
    }

    func testParseStatusWithoutATun() throws {
        let object = ["state": "reconnecting", "tun": [String: Any]()] as [String: Any]
        let status = try XCTUnwrap(LiveKernelControlClient.parseStatus(object))
        XCTAssertEqual(status.state, "reconnecting")
        XCTAssertFalse(status.tunnelUp)
    }

    func testParseResponseReadsTheBodyPastTheHead() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"
        let parsed = LiveKernelControlClient.parseResponse(Array(raw.utf8))
        XCTAssertEqual(parsed?.status, 200)
        XCTAssertEqual(parsed?.body.isEmpty, true)
    }

    func testMissingTokenFileAnswersNil() {
        let client = LiveKernelControlClient(tokenFilePath: "/nonexistent/segue-control.json")
        XCTAssertNil(client.readStatus())
    }

    func testRoundTripAgainstALoopbackServer() throws {
        let stub = try ControlStub(reply: Self.statusBody)
        stub.start()
        defer { stub.stop() }
        let root = try temporaryDirectory("segue-control")
        defer { try? FileManager.default.removeItem(at: root) }
        let tokenFile = root.appendingPathComponent("control.json")
        let token = #"{"addr":"127.0.0.1:\#(stub.port)","token":"cafebabe"}"#
        try Data(token.utf8).write(to: tokenFile)

        let client = LiveKernelControlClient(tokenFilePath: tokenFile.path, timeout: 2)
        let status = try XCTUnwrap(client.readStatus())
        XCTAssertEqual(status.state, "connected")
        XCTAssertEqual(status.tunInterface, "utun7")

        client.connect()
        XCTAssertEqual(stub.requests.count, 2, "connect is a second request")
        XCTAssertTrue(
            stub.requests.allSatisfy { $0.contains("Authorization: Bearer cafebabe") },
            "\(stub.requests)"
        )
        XCTAssertTrue(stub.requests.first?.contains("GET /v1/status") == true)
        XCTAssertTrue(stub.requests.last?.contains("POST /v1/connect") == true)
        // The kernel refuses non-loopback Host headers and browser Origin
        // headers; the client must send neither reason to reject it.
        XCTAssertTrue(stub.requests.allSatisfy { $0.contains("Host: localhost") })
        XCTAssertFalse(stub.requests.contains(where: { $0.contains("Origin") }))
    }
}
