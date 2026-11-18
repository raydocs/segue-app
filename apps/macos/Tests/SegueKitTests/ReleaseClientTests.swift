import Darwin
import XCTest

@testable import SegueKit

final class ReleaseClientTests: XCTestCase {
    func testRestoreRoundTripOverSocketPair() async throws {
        let (clientFD, serverFD) = try releaseSocketPair()
        defer {
            _ = Darwin.close(clientFD)
            _ = Darwin.close(serverFD)
        }
        let report = Self.cleanReport()
        let server = ReleaseLineServer(fd: serverFD) { envelope in
            XCTAssertEqual(envelope.kind, .restore)
            return try! JSONEncoder().encode(ReleaseEnvelope.report(report))
        }
        let client = ReleaseClient(socket: DescriptorHelperSocket(fd: clientFD))
        let read = try await client.restore()
        XCTAssertEqual(read, report)
        XCTAssertEqual(server.received.map(\.kind), [.restore])
    }

    func testUnauthorizedAndVersionMismatch() async throws {
        let (clientFD, serverFD) = try releaseSocketPair()
        defer {
            _ = Darwin.close(clientFD)
            _ = Darwin.close(serverFD)
        }
        let denied = try JSONEncoder().encode(
            ReleaseEnvelope.failure(code: HelperErrorCode.unauthorized, message: "peer denied: uid")
        )
        let mismatched = Data(#"{"version":9,"kind":"report"}"#.utf8)
        let replies = ReleaseReplyList([denied, mismatched])
        _ = ReleaseLineServer(fd: serverFD) { _ in
            replies.removeFirst()
        }
        let client = ReleaseClient(socket: DescriptorHelperSocket(fd: clientFD))
        do {
            _ = try await client.restore()
            XCTFail("expected unauthorized")
        } catch let error as ReleaseClientError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected \(error)")
        }
        do {
            _ = try await client.restore()
            XCTFail("expected version mismatch")
        } catch let error as ReleaseClientError {
            XCTAssertEqual(error, .versionMismatch(9))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testReplyThatIsNotAReportIsMalformed() async throws {
        let (clientFD, serverFD) = try releaseSocketPair()
        defer {
            _ = Darwin.close(clientFD)
            _ = Darwin.close(serverFD)
        }
        // The daemon never echoes the request; if something does, it is not
        // a report the menu can trust.
        let echo = try JSONEncoder().encode(ReleaseEnvelope.restore())
        _ = ReleaseLineServer(fd: serverFD) { _ in echo }
        let client = ReleaseClient(socket: DescriptorHelperSocket(fd: clientFD))
        do {
            _ = try await client.restore()
            XCTFail("expected malformed")
        } catch let error as ReleaseClientError {
            XCTAssertEqual(error, .malformed)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private static func cleanReport() -> ReleaseReport {
        ReleaseReport(
            anchorLoaded: false,
            resolverFilesRemoved: ["api.example"],
            resolverFilesRemaining: [],
            dnsRestoredServices: ["Wi-Fi"],
            dnsMissingServices: [],
            dnsMode: "system",
            intentCleared: true,
            snapshotCleared: true,
            failures: [],
            outcome: "restored"
        )
    }
}

private func releaseSocketPair() throws -> (Int32, Int32) {
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

private final class ReleaseLineServer {
    private let lock = NSLock()
    private var requests: [ReleaseEnvelope] = []

    var received: [ReleaseEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    init(fd: Int32, reply: @escaping (ReleaseEnvelope) -> Data) {
        DispatchQueue.global().async { [self] in
            while let line = try? HelperLineIO.readLine(fd: fd) {
                guard let envelope = try? JSONDecoder().decode(ReleaseEnvelope.self, from: line) else {
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

private final class ReleaseReplyList: @unchecked Sendable {
    private var values: [Data]
    init(_ values: [Data]) { self.values = values }
    func removeFirst() -> Data { values.removeFirst() }
}
