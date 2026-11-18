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
            "--config",
            "/Library/Application Support/Segue/kernel.json",
            "--state-dir",
            "/Library/Application Support/Segue/kernel",
        ]])
        XCTAssertEqual(supervisor.snapshot().state, "running")
        XCTAssertEqual(supervisor.snapshot().pid, launcher.latest.pid)
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
