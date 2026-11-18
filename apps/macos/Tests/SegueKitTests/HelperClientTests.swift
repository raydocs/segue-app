import Darwin
import XCTest

@testable import SegueKit

final class HelperClientTests: XCTestCase {
    func testStatusArmAndDisarmOverSocketPair() async throws {
        let (clientFD, serverFD) = try socketPair()
        defer {
            _ = Darwin.close(clientFD)
            _ = Darwin.close(serverFD)
        }
        let server = LineServer(fd: serverFD) { envelope in
            let armed = envelope.kind == .arm
            let tun = envelope.kind == .disarm ? nil : "utun4"
            let status = HelperStatus(
                armed: armed,
                generation: envelope.arm?.generation ?? envelope.disarm?.generation ?? 1,
                held: armed,
                tunInterface: tun,
                rulesDigest: "abc",
                evidence: StatusEvidence(tcpProofMs: nil, dnsReadback: false),
                lastError: nil
            )
            return try! JSONEncoder().encode(HelperEnvelope.status(status))
        }
        let client = HelperClient(socket: DescriptorHelperSocket(fd: clientFD))
        let read = try await client.readStatus()
        XCTAssertFalse(read.armed)
        XCTAssertEqual(read.tunInterface, "utun4")

        let arm = try await client.arm(HelperRequests.userConnect(generation: 3))
        XCTAssertTrue(arm.armed)
        XCTAssertEqual(arm.generation, 3)

        for reason in [DisarmReason.userDisconnect, .quit, .signOut] {
            let reply = try await client.disarm(DisarmIntent(generation: 8, intent: reason))
            XCTAssertFalse(reply.armed)
            XCTAssertNil(reply.tunInterface)
            XCTAssertEqual(reply.generation, 8)
        }

        let kinds = server.received.map(\.kind)
        XCTAssertEqual(kinds, [.statusRead, .arm, .disarm, .disarm, .disarm])
        XCTAssertEqual(server.received[1].arm?.intent, .userConnect)
        XCTAssertEqual(
            server.received.dropFirst(2).map { $0.disarm?.intent },
            [.userDisconnect, .quit, .signOut]
        )
    }

    func testVersionMismatchAndUnauthorized() async throws {
        let (clientFD, serverFD) = try socketPair()
        defer {
            _ = Darwin.close(clientFD)
            _ = Darwin.close(serverFD)
        }
        let mismatched = Data(#"{"version":2,"kind":"status"}"#.utf8)
        let denied = try JSONEncoder().encode(
            HelperEnvelope.failure(code: HelperErrorCode.unauthorized, message: "peer denied: requirement")
        )
        let replies = ReplyList([mismatched, denied])
        let server = LineServer(fd: serverFD) { _ in
            replies.removeFirst()
        }
        _ = server
        let client = HelperClient(socket: DescriptorHelperSocket(fd: clientFD))
        do {
            _ = try await client.readStatus()
            XCTFail("expected version mismatch")
        } catch let error as HelperClientError {
            XCTAssertEqual(error, .versionMismatch(2))
        } catch {
            XCTFail("unexpected \(error)")
        }
        do {
            _ = try await client.readStatus()
            XCTFail("expected unauthorized")
        } catch let error as HelperClientError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testMissingSocketIsNotInstalled() async {
        let path = "/tmp/segue-absent-\(UUID().uuidString).sock"
        let client = HelperClient.connectedToHelperSocket(path: path)
        do {
            _ = try await client.readStatus()
            XCTFail("expected not installed")
        } catch let error as HelperClientError {
            XCTAssertEqual(error, .notInstalled)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTempDirectorySocketRoundTrip() async throws {
        let path = "/tmp/segue-\(UUID().uuidString.prefix(8)).sock"
        defer { _ = unlink(path) }
        let ready = DispatchSemaphore(value: 0)
        let listenFD = try listen(at: path, ready: ready)
        defer {
            _ = Darwin.close(listenFD)
            _ = unlink(path)
        }
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        let client = HelperClient.connectedToHelperSocket(path: path)
        let status = try await client.readStatus()
        XCTAssertTrue(status.armed)
        XCTAssertEqual(status.tunInterface, "utun9")
    }

    private func listen(at path: String, ready: DispatchSemaphore) throws -> Int32 {
        _ = unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.ENODEV)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { cString in
            withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
                pathPointer.withMemoryRebound(to: CChar.self, capacity: capacity) { dest in
                    _ = strncpy(dest, cString, capacity - 1)
                }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                Darwin.bind(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            _ = Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        DispatchQueue.global().async {
            ready.signal()
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else {
                return
            }
            defer { _ = Darwin.close(client) }
            guard let line = try? HelperLineIO.readLine(fd: client) else {
                return
            }
            _ = line
            let status = HelperStatus(
                armed: true,
                generation: 1,
                held: true,
                tunInterface: "utun9",
                rulesDigest: "",
                evidence: StatusEvidence(tcpProofMs: nil, dnsReadback: false),
                lastError: nil
            )
            let body = try? JSONEncoder().encode(HelperEnvelope.status(status))
            if let body {
                try? HelperLineIO.writeLine(fd: client, body)
            }
        }
        return fd
    }
}

private func socketPair() throws -> (Int32, Int32) {
    var fds = [Int32](repeating: -1, count: 2)
    let result = fds.withUnsafeMutableBufferPointer { buffer in
        Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
    }
    guard result == 0 else {
        throw POSIXError(.EIO)
    }
    for fd in fds {
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
    }
    return (fds[0], fds[1])
}

private final class LineServer {
    private let lock = NSLock()
    private var requests: [HelperEnvelope] = []

    var received: [HelperEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    init(fd: Int32, reply: @escaping (HelperEnvelope) -> Data) {
        DispatchQueue.global().async { [self] in
            while let line = try? HelperLineIO.readLine(fd: fd) {
                guard let envelope = try? JSONDecoder().decode(HelperEnvelope.self, from: line) else {
                    return
                }
                lock.lock()
                requests.append(envelope)
                lock.unlock()
                try? HelperLineIO.writeLine(fd: fd, reply(envelope))
            }
        }
    }
}

private final class ReplyList: @unchecked Sendable {
    private var values: [Data]
    init(_ values: [Data]) { self.values = values }
    func removeFirst() -> Data { values.removeFirst() }
}
