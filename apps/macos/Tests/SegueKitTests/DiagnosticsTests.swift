import XCTest

@testable import SegueKit

final class DiagnosticsTests: XCTestCase {
    private let home = "/Users/example"
    private let secret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    func testRedactsHomeTokenAndPeerButKeepsInterface() {
        let raw = #"""
        {"token":"\#(secret)","path":"\#(home)/Library/Application Support/Segue","tun":"utun4","note":"utun peer 192.0.2.55","also":"Bearer \#(secret)","ifconfig":"inet 192.0.2.1 --> 192.0.2.8","encoded":"%2FUsers%2Fexample/Library","other":"/Users/example2/keep"}
        """#
        let out = DiagnosticsRedactor.redact(raw, home: home, secrets: [secret], peerAddresses: ["192.0.2.8"])
        XCTAssertFalse(out.contains(secret))
        XCTAssertFalse(out.contains(home + "/"))
        XCTAssertFalse(out.contains("%2FUsers%2Fexample"))
        XCTAssertFalse(out.contains("192.0.2.55"))
        XCTAssertFalse(out.contains("192.0.2.8"))
        XCTAssertTrue(out.contains("utun4"))
        XCTAssertTrue(out.contains("<home>"))
        XCTAssertTrue(out.contains("<redacted>"))
        XCTAssertTrue(out.contains("<peer>"))
        XCTAssertTrue(out.contains("/Users/example2/keep"))
        XCTAssertTrue(out.contains("192.0.2.1"))
    }

    func testListedPeerWithoutContext() {
        let out = DiagnosticsRedactor.redact(
            "saw 192.0.2.8 and left 192.0.2.9",
            home: home,
            peerAddresses: ["192.0.2.8"]
        )
        XCTAssertFalse(out.contains("192.0.2.8"))
        XCTAssertTrue(out.contains("192.0.2.9"))
        XCTAssertTrue(out.contains("<peer>"))
    }

    func testExportFileIsRedactedJSON() async throws {
        let directory = try temporaryDirectory("segue-export")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let model = await MainActor.run { () -> ConnectionModel in
            let fake = FakeControlClient()
            let folder = URL(fileURLWithPath: self.home, isDirectory: true)
                .appendingPathComponent("Library/Application Support/Segue", isDirectory: true)
            let model = ConnectionModel(client: fake, configFolder: folder, homePath: self.home)
            model.lastError = "Bearer \(self.secret) utun peer 2001:db8::7"
            return model
        }
        let when = Date(timeIntervalSince1970: 0)
        let url = try await MainActor.run {
            try model.exportDiagnostics(to: directory, now: when, secrets: [secret])
        }
        XCTAssertEqual(url.lastPathComponent, "segue-diagnostics-19700101T000000Z.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains(home))
        XCTAssertFalse(text.contains("2001:db8::7"))
        XCTAssertTrue(text.contains("<home>"))
        XCTAssertTrue(text.contains("<redacted>"))
        XCTAssertTrue(text.contains("<peer>"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(text.utf8)))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? -1) & 0o777, 0o600)
    }

    func testExportRejectsMissingDirectory() async throws {
        let model = await MainActor.run {
            ConnectionModel(
                client: FakeControlClient(),
                configFolder: URL(fileURLWithPath: "/Users/example/Library/Application Support/Segue"),
                homePath: home
            )
        }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("segue-missing-\(UUID().uuidString)", isDirectory: true)
        do {
            _ = try await MainActor.run {
                try model.exportDiagnostics(to: missing)
            }
            XCTFail("expected missing directory")
        } catch let error as DiagnosticsError {
            XCTAssertEqual(error, .directoryMissing)
        }
    }
}
