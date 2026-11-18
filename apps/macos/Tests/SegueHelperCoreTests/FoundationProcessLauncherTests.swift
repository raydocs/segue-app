import XCTest

@testable import SegueHelperCore

/// The real launcher, against `/bin/sh`: the capture files must hold what
/// the child printed, mode 0600, and rotate at the cap. A capture path
/// that cannot exist must not stop the child.
final class FoundationProcessLauncherTests: XCTestCase {
    private func runShell(
        _ command: String,
        stdout: String?,
        stderr: String?
    ) throws -> RunningProcess {
        let launcher = FoundationProcessLauncher()
        return try launcher.launch(
            LaunchRequest(
                arguments: ["/bin/sh", "-c", command],
                stdoutPath: stdout,
                stderrPath: stderr
            )
        ) { _, _ in }
    }

    func testCapturesBothStreamsAppendingAtMode0600() throws {
        let root = try temporaryDirectory("segue-launcher")
        let out = root.appendingPathComponent("kernel.stdout")
        let err = root.appendingPathComponent("kernel.stderr")
        try Data("before-out\n".utf8).write(to: out)
        try Data("before-err\n".utf8).write(to: err)

        let first = try runShell("echo hello-out; echo hello-err 1>&2", stdout: out.path, stderr: err.path)
        XCTAssertTrue(first.waitUntilExited(timeout: 5))

        let outText = try String(contentsOf: out, encoding: .utf8)
        let errText = try String(contentsOf: err, encoding: .utf8)
        XCTAssertEqual(outText, "before-out\nhello-out\n")
        XCTAssertEqual(errText, "before-err\nhello-err\n")
        XCTAssertEqual(try posixMode(at: out), 0o600)
        XCTAssertEqual(try posixMode(at: err), 0o600)
    }

    func testRotatesAFileThatReachedTheCap() throws {
        let root = try temporaryDirectory("segue-launcher-rotate")
        let out = root.appendingPathComponent("kernel.stdout")
        let rotated = root.appendingPathComponent("kernel.stdout.1")
        try Data(repeating: 0x61, count: KernelOutputFile.rotateBytes + 1).write(to: out)

        let proc = try runShell("echo after-rotation", stdout: out.path, stderr: nil)
        XCTAssertTrue(proc.waitUntilExited(timeout: 5))

        let outText = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(outText, "after-rotation\n", "the launch starts a fresh file")
        XCTAssertEqual(try Data(contentsOf: rotated).count, KernelOutputFile.rotateBytes + 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotated.path + ".1"))
    }

    func testAnUnwritableCapturePathStillLaunchesTheChild() throws {
        let root = try temporaryDirectory("segue-launcher-null")
        // No such directory: the open fails, the child runs anyway with
        // /dev/null streams.
        let missing = root.appendingPathComponent("no-such-dir/kernel.stdout").path
        let proc = try runShell("echo still-alive", stdout: missing, stderr: missing)
        XCTAssertTrue(proc.waitUntilExited(timeout: 5))
        XCTAssertFalse(proc.isRunning)
    }
}
