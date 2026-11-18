import Darwin
import XCTest

@testable import SegueHelperCore

final class KernelSupervisorTests: XCTestCase {
    func testExitCodeMapping() {
        let rows: [(ProcessExit, String, Bool)] = [
            (.code(0), "clean_shutdown", false),
            (.code(1), "listener_failed", true),
            (.code(2), "bad_arguments", false),
            (.code(3), "config_rejected", false),
            (.code(4), "tun_setup_failed", true),
            (.code(99), "exit_99", true),
            (.signal(SIGTERM), "clean_shutdown", false),
            (.signal(SIGINT), "clean_shutdown", false),
            (.signal(SIGKILL), "signal_9", true),
        ]
        for (exit, name, restarts) in rows {
            let mapped = KernelExitCode(exit)
            XCTAssertEqual(mapped.stateName, name, "\(exit)")
            XCTAssertEqual(mapped.restarts, restarts, "\(exit)")
        }
    }

    func testLaunchArguments() throws {
        let (supervisor, launcher, _) = try makeSupervisor()
        try supervisor.start()
        XCTAssertEqual(launcher.requests, [[
            "/Library/PrivilegedHelperTools/segue-kernel",
            "run",
            "--state-dir",
            "/Library/Application Support/Segue/kernel",
            "--log",
            "/Library/Application Support/Segue/kernel.log",
            "/Library/Application Support/Segue/kernel.json",
        ]])
        XCTAssertEqual(supervisor.snapshot().state, "running")
        XCTAssertEqual(supervisor.snapshot().pid, launcher.latest.pid)
    }

    func testLaunchRequestCarriesTheCapturePaths() throws {
        let root = try temporaryDirectory("segue-capture")
        let launcher = FakeLauncher()
        let supervisor = KernelSupervisor(
            kernelPath: "/bin/segue-kernel",
            configPath: root.appendingPathComponent("kernel.json").path,
            stateDir: root.appendingPathComponent("kernel").path,
            launcher: launcher,
            logPath: root.appendingPathComponent("logs/kernel.log").path
        )
        try supervisor.start()
        XCTAssertEqual(launcher.launchRequests.count, 1)
        XCTAssertEqual(launcher.launchRequests[0].stdoutPath, root.appendingPathComponent("logs/kernel.stdout").path)
        XCTAssertEqual(launcher.launchRequests[0].stderrPath, root.appendingPathComponent("logs/kernel.stderr").path)
    }

    func testKernelFailedPublishesARedactedStderrTail() throws {
        let root = try temporaryDirectory("segue-tail")
        let launcher = FakeLauncher()
        let supervisor = KernelSupervisor(
            kernelPath: "/bin/segue-kernel",
            configPath: root.appendingPathComponent("kernel.json").path,
            stateDir: root.appendingPathComponent("kernel").path,
            launcher: launcher,
            logPath: root.appendingPathComponent("logs/kernel.log").path,
            restartLimit: 1
        )
        try FileManager.default.createDirectory(
            atPath: root.appendingPathComponent("logs").path,
            withIntermediateDirectories: true
        )
        // Older than the tail window, then the last words: a bearer token
        // and a keyed one, both of which diagnostics redaction must scrub.
        let early = "EARLY-MARK\n" + String(repeating: "padding line\n", count: 500)
        let lastWords = "tun setup failed: Bearer abcdefghijklmnop\n"
            + #"{"token":"0123456789abcdef"}"#
        try (early + lastWords).write(
            to: root.appendingPathComponent("logs/kernel.stderr"),
            atomically: true,
            encoding: .utf8
        )
        try supervisor.start()
        launcher.latest.finish(.code(1))
        launcher.latest.finish(.code(1))
        XCTAssertEqual(supervisor.snapshot().state, "kernel_failed")
        let tail = try XCTUnwrap(supervisor.snapshot().lastStderr)
        XCTAssertNil(tail.range(of: "abcdefghijklmnop"), "the bearer token is scrubbed")
        XCTAssertNil(tail.range(of: "0123456789abcdef"), "the keyed token is scrubbed")
        XCTAssertTrue(tail.contains("tun setup failed"), "the cause text stays")
        XCTAssertTrue(tail.utf8.count <= 2 * 1_024, "the tail is capped at 2 KiB")
        XCTAssertFalse(tail.contains("EARLY"), "only the end of the file is read")
    }

    func testStderrTailIsOnlyForKernelFailed() throws {
        let (supervisor, launcher, _) = try makeSupervisor()
        try supervisor.start()
        XCTAssertNil(supervisor.snapshot().lastStderr, "running: no tail")
        launcher.latest.finish(.code(4))
        XCTAssertNil(supervisor.snapshot().lastStderr, "restarted: no tail")
        launcher.latest.finish(.code(0))
        XCTAssertNil(supervisor.snapshot().lastStderr, "clean shutdown: no tail")
        supervisor.stop()
        XCTAssertNil(supervisor.snapshot().lastStderr, "stopped: no tail")
    }

    func testNonCrashExitsStayDown() throws {
        let expectations: [(ProcessExit, String)] = [
            (.code(0), "clean_shutdown"),
            (.code(2), "bad_arguments"),
            (.code(3), "config_rejected"),
            (.signal(SIGTERM), "clean_shutdown"),
        ]
        for (exit, state) in expectations {
            let (supervisor, launcher, _) = try makeSupervisor()
            try supervisor.start()
            launcher.latest.finish(exit)
            XCTAssertEqual(launcher.procs.count, 1, state)
            XCTAssertEqual(supervisor.snapshot().state, state)
            XCTAssertNil(supervisor.snapshot().pid)
        }
    }

    func testCrashRestartsAndRecordsLastExit() throws {
        let (supervisor, launcher, _) = try makeSupervisor()
        try supervisor.start()
        launcher.latest.finish(.code(4))
        XCTAssertEqual(launcher.procs.count, 2)
        XCTAssertEqual(supervisor.snapshot().state, "running")
        XCTAssertEqual(supervisor.snapshot().lastExit, "tun_setup_failed")
        launcher.latest.finish(.signal(SIGKILL))
        XCTAssertEqual(launcher.procs.count, 3)
        XCTAssertEqual(supervisor.snapshot().lastExit, "signal_9")
    }

    func testRestartBudgetThenStaysDown() throws {
        let (supervisor, launcher, clock) = try makeSupervisor()
        try supervisor.start()
        for _ in 1...10 {
            launcher.latest.finish(.code(1))
        }
        XCTAssertEqual(launcher.procs.count, 11)
        XCTAssertEqual(supervisor.snapshot().state, "running")
        launcher.latest.finish(.code(1))
        XCTAssertEqual(launcher.procs.count, 11)
        XCTAssertEqual(supervisor.snapshot().state, "kernel_failed")
        XCTAssertEqual(supervisor.snapshot().lastExit, "listener_failed")
        XCTAssertNil(supervisor.snapshot().pid)

        clock.advance(1_000)
        XCTAssertEqual(supervisor.snapshot().state, "kernel_failed")
        XCTAssertEqual(launcher.procs.count, 11)

        try supervisor.start()
        XCTAssertEqual(launcher.procs.count, 12)
        XCTAssertEqual(supervisor.snapshot().state, "running")
    }

    func testWindowDropsRestartsOlderThan600Seconds() throws {
        let (blocked, blockedLauncher, blockedClock) = try makeSupervisor()
        try blocked.start()
        for _ in 1...10 {
            blockedLauncher.latest.finish(.code(1))
        }
        blockedClock.advance(599)
        blockedLauncher.latest.finish(.code(1))
        XCTAssertEqual(blocked.snapshot().state, "kernel_failed")
        XCTAssertEqual(blockedLauncher.procs.count, 11)

        let (open, openLauncher, openClock) = try makeSupervisor()
        try open.start()
        for _ in 1...10 {
            openLauncher.latest.finish(.code(1))
        }
        openClock.advance(600)
        openLauncher.latest.finish(.code(1))
        XCTAssertEqual(open.snapshot().state, "running")
        XCTAssertEqual(openLauncher.procs.count, 12)
    }

    func testStopSendsTermOnlyWhenTheChildExits() throws {
        let (supervisor, launcher, _) = try makeSupervisor()
        try supervisor.start()
        let proc = launcher.latest
        supervisor.stop()
        XCTAssertEqual(proc.signals, [SIGTERM])
        XCTAssertEqual(proc.waits, [5])
        XCTAssertEqual(launcher.procs.count, 1)
        XCTAssertEqual(supervisor.snapshot().state, "stopped")
    }

    func testStopEscalatesToKillAfterGrace() throws {
        let (supervisor, launcher, _) = try makeSupervisor()
        launcher.ignoreTerminate = true
        try supervisor.start()
        let proc = launcher.latest
        supervisor.stop()
        XCTAssertEqual(proc.signals, [SIGTERM, SIGKILL])
        XCTAssertEqual(proc.waits, [5, 5])
        XCTAssertEqual(launcher.procs.count, 1)
        XCTAssertEqual(supervisor.snapshot().state, "stopped")
        XCTAssertFalse(proc.isRunning)
    }

    func testSnapshotPublishesTheControlAPIView() throws {
        let control = FakeControlClient()
        let root = try temporaryDirectory("segue-snap")
        let config = root.appendingPathComponent("kernel.json")
        try Data(#"{"dns":{"listen":"127.0.0.1:53"}}"#.utf8).write(to: config)
        let stateDir = root.appendingPathComponent("kernel").path
        let launcher = FakeLauncher()
        let supervisor = KernelSupervisor(
            kernelPath: "/bin/segue-kernel",
            configPath: config.path,
            stateDir: stateDir,
            launcher: launcher,
            control: control
        )
        control.status = nil
        try supervisor.start()
        XCTAssertNil(supervisor.snapshot().tunInterface)
        XCTAssertNil(supervisor.snapshot().dnsAddress)

        control.status = KernelControlStatus(state: "reconnecting", tunInterface: "utun3")
        XCTAssertEqual(supervisor.snapshot().tunInterface, "utun3")
        XCTAssertNil(supervisor.snapshot().dnsAddress, "no carrier: no kernel DNS")

        control.status = KernelControlStatus(state: "connected", tunInterface: "utun3", routes: "installed")
        XCTAssertEqual(supervisor.snapshot().dnsAddress, "127.0.0.1:53")

        control.status = nil
        launcher.latest.finish(.code(0))
        XCTAssertNil(supervisor.snapshot().tunInterface, "a dead kernel publishes nothing")
    }

    func testSnapshotWithoutControlClientKeepsProcessFactsOnly() throws {
        let (supervisor, launcher, _) = try makeSupervisor()
        try supervisor.start()
        XCTAssertEqual(supervisor.snapshot().state, "running")
        XCTAssertNil(supervisor.snapshot().tunInterface)
        XCTAssertNil(supervisor.snapshot().dnsAddress)
        launcher.latest.finish(.code(1))
        XCTAssertEqual(launcher.procs.count, 2)
    }

    func testControlViewWithoutADNSConfigIsTunOnly() throws {
        let control = FakeControlClient()
        control.status = KernelControlStatus(state: "connected", tunInterface: "utun1", routes: "installed")
        let root = try temporaryDirectory("segue-snap2")
        let supervisor = KernelSupervisor(
            kernelPath: "/bin/segue-kernel",
            configPath: root.appendingPathComponent("missing.json").path,
            stateDir: root.appendingPathComponent("kernel").path,
            launcher: FakeLauncher(),
            control: control
        )
        try supervisor.start()
        XCTAssertEqual(supervisor.snapshot().tunInterface, "utun1")
        XCTAssertNil(supervisor.snapshot().dnsAddress, "no dns.listen in the config")
    }

    func testPIDFileFollowsTheChild() throws {
        let root = try temporaryDirectory("segue-pid")
        let stateDir = root.appendingPathComponent("kernel").path
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let pidFile = stateDir + "/kernel.pid"
        let launcher = FakeLauncher()
        let supervisor = KernelSupervisor(
            kernelPath: "/bin/segue-kernel",
            configPath: root.appendingPathComponent("kernel.json").path,
            stateDir: stateDir,
            launcher: launcher
        )
        try supervisor.start()
        let written = try String(contentsOfFile: pidFile, encoding: .utf8)
        XCTAssertEqual(written.trimmingCharacters(in: .whitespacesAndNewlines), "\(launcher.latest.pid)")
        supervisor.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile))
        // A crash relaunch rewrites the file with the new child.
        try supervisor.start()
        launcher.latest.finish(.code(1))
        let relaunched = try String(contentsOfFile: pidFile, encoding: .utf8)
        XCTAssertEqual(
            relaunched.trimmingCharacters(in: .whitespacesAndNewlines),
            "\(launcher.latest.pid)"
        )
        launcher.latest.finish(.signal(SIGKILL))
        launcher.latest.finish(.code(0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile))
    }

    func testExitsReportThroughOnStateChange() throws {
        let (supervisor, launcher, _) = try makeSupervisor()
        var reports = 0
        supervisor.onStateChange = { reports += 1 }
        try supervisor.start()
        XCTAssertEqual(reports, 0, "a start is not a state-change report")
        launcher.latest.finish(.code(1))
        XCTAssertEqual(reports, 1, "the restart reported")
        launcher.latest.finish(.code(0))
        XCTAssertEqual(reports, 2, "the clean settle reported")
        // A duplicate exit from an already-reaped pid is ignored.
        launcher.procs[0].finish(.code(1))
        XCTAssertEqual(reports, 2)
    }

    private func makeSupervisor() throws -> (KernelSupervisor, FakeLauncher, ManualClock) {
        let launcher = FakeLauncher()
        let clock = ManualClock(Date(timeIntervalSince1970: 1_700_000_000))
        let supervisor = KernelSupervisor(
            kernelPath: "/Library/PrivilegedHelperTools/segue-kernel",
            configPath: "/Library/Application Support/Segue/kernel.json",
            stateDir: "/Library/Application Support/Segue/kernel",
            launcher: launcher,
            clock: clock
        )
        return (supervisor, launcher, clock)
    }
}
