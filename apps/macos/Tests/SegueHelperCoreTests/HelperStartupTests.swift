import Darwin
import Foundation
import Security
import XCTest

@testable import SegueHelperCore

/// Runs the built `segue-core-helper` with every path under a temp directory
/// and a guard port above 1024. No root, no launchd, no PF.
final class HelperStartupTests: XCTestCase {
    func testDevHelperAnswersStatusAndArmedGuard() throws {
        guard let binary = Self.builtHelper() else {
            XCTFail("segue-core-helper was not built; run swift build before swift test")
            return
        }
        let requirement = try XCTUnwrap(
            Self.ownRequirement(),
            "this process has no designated requirement to admit itself"
        )
        // sockaddr_un is 104 bytes. NSTemporaryDirectory() plus a UUID does not fit.
        let root = URL(fileURLWithPath: "/tmp/segue-hs-\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suffix = "ailock-fixture.example.com"
        try Data("\(getuid())\n".utf8).write(to: root.appendingPathComponent("allowed-uid"))
        try Data("suffix \(suffix)\n".utf8).write(to: root.appendingPathComponent("ai-lock.txt"))
        try Data(
            "{\"armed\":true,\"generation\":1,\"name\":\"user_connect\"}\n".utf8
        ).write(to: root.appendingPathComponent("ai-lock.intent"))

        let port: UInt16 = 35354
        let socket = root.appendingPathComponent("run/service.sock").path
        let errURL = root.appendingPathComponent("helper.err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "--paths-root", root.path,
            "--guard-port", String(port),
            "--requirement", requirement,
        ]
        process.standardError = errHandle
        process.standardOutput = errHandle
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? errHandle.close()
        }

        let appeared = Self.waitUntil(seconds: 8) {
            FileManager.default.fileExists(atPath: socket) || !process.isRunning
        }
        XCTAssertTrue(appeared)
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        guard FileManager.default.fileExists(atPath: socket) else {
            XCTFail("socket missing; helper stderr:\n\(stderr)")
            return
        }

        let status = try Self.roundTrip(socket: socket, line: #"{"version":1,"kind":"status_read"}"#)
        XCTAssertTrue(status.contains("\"armed\":true"), status)

        for qtype in [UInt16(1), UInt16(28)] {
            let reply = try Self.queryGuard(port: port, name: "www.\(suffix)", qtype: qtype)
            XCTAssertEqual(reply.rcode, 0, "qtype \(qtype) stderr:\n\(stderr)")
            XCTAssertEqual(reply.ancount, 0, "qtype \(qtype)")
        }
    }

    private static func builtHelper() -> String? {
        if let env = ProcessInfo.processInfo.environment["SEGUE_HELPER_BIN"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let here = URL(fileURLWithPath: #filePath)
        let macos = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            macos.appendingPathComponent(".build/debug/segue-core-helper").path,
            macos.appendingPathComponent(".build/release/segue-core-helper").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func ownRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let requirement
        else {
            return nil
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(rawValue: 0), &text) == errSecSuccess,
              let text
        else {
            return nil
        }
        return text as String
    }

    private static func waitUntil(seconds: TimeInterval, _ body: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if body() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return body()
    }

    private static func roundTrip(socket: String, line: String) throws -> String {
        let fd = try unixSocket()
        defer { _ = Darwin.close(fd) }
        try connectUnixSocket(fd: fd, path: socket)
        setReceiveTimeout(fd, seconds: 3)
        try LineIO.writeLine(fd: fd, payload: Data(line.utf8))
        let data = try XCTUnwrap(try LineIO.readLine(fd: fd))
        return String(decoding: data, as: UTF8.self)
    }

    private static func queryGuard(port: UInt16, name: String, qtype: UInt16) throws -> (rcode: Int, ancount: Int) {
        let query = dnsQuery(name: name, qtype: qtype)
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = Darwin.close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        dest.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let sent = query.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &dest) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        XCTAssertEqual(sent, query.count)
        var buffer = [UInt8](repeating: 0, count: 512)
        let got = Darwin.recvfrom(fd, &buffer, buffer.count, 0, nil, nil)
        XCTAssertGreaterThanOrEqual(got, 12)
        let rcode = Int(buffer[3] & 0x0F)
        let ancount = Int(buffer[6]) << 8 | Int(buffer[7])
        return (rcode, ancount)
    }

    private static func dnsQuery(name: String, qtype: UInt16) -> Data {
        var packet = Data([0xAB, 0xCD, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0)
        packet.append(UInt8(qtype >> 8))
        packet.append(UInt8(qtype & 0xFF))
        packet.append(contentsOf: [0x00, 0x01])
        return packet
    }
}
