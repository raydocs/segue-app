import Darwin
import Foundation
import SegueAILayer
import SegueHelperProtocol
import XCTest

@testable import SegueHelperCore

/// One helper session with the kernel's collaborators faked: the process
/// launcher, the control API, and the system commands. Drives HelperSession
/// directly (the socket path is covered by HelperSocketServerTests).
final class KernelRig {
    let directory: URL
    let commands: RecordingSystemCommands
    let launcher: FakeLauncher
    let control: FakeControlClient
    let supervisor: KernelSupervisor
    let session: HelperSession
    let intentURL: URL
    let configURL: URL

    /// The kernel DNS listen address written into the fake kernel.json.
    /// Resolver files name this port; per-service DNS is not rewritten.
    static let kernelDNS = "127.0.0.1:53"

    init(
        armedIntent: Bool = false,
        restartLimit: Int = 10,
        dnsListen: String? = KernelRig.kernelDNS,
        externalProbe: @escaping (Int32, String) -> Bool = { _, _ in false }
    ) throws {
        let directory = try temporaryDirectory("segue-kernel-rig")
        let intentURL = directory.appendingPathComponent("ai-lock.intent")
        let configURL = directory.appendingPathComponent("kernel.json")
        if let dnsListen {
            let config: [String: Any] = ["dns": ["listen": dnsListen]]
            try JSONSerialization.data(withJSONObject: config).write(to: configURL)
        }
        if armedIntent {
            try IntentStore(fileURL: intentURL).save(
                StoredIntent(armed: true, generation: 1, name: "user_connect")
            )
        }
        let commands = RecordingSystemCommands()
        let launcher = FakeLauncher()
        let control = FakeControlClient()
        let stateDir = directory.appendingPathComponent("kernel").path
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let supervisor = KernelSupervisor(
            kernelPath: "/bin/segue-kernel",
            configPath: configURL.path,
            stateDir: stateDir,
            launcher: launcher,
            logPath: directory.appendingPathComponent("kernel.log").path,
            control: control,
            restartLimit: restartLimit,
            stopGrace: 0.2,
            externalProbe: externalProbe
        )
        let layer = AILayerController(
            commands: commands,
            kernel: supervisor,
            list: AILockList(
                suffixes: ["example.com"],
                cidrs: [try CIDR(parsing: "192.0.2.0/24")]
            ),
            paths: AILayerPaths(
                pfConfPath: directory.appendingPathComponent("pf.conf").path,
                resolverDirectory: directory.appendingPathComponent("resolver").path,
                snapshotPath: directory.appendingPathComponent("dns-snapshot.json").path,
                guardAddress: "127.0.0.1",
                guardPort: AILayerPaths.defaultGuardPort
            )
        )
        // No background loop: every convergence below is driven by hand.
        let session = HelperSession(
            store: IntentStore(fileURL: intentURL),
            kernel: supervisor,
            layer: layer,
            control: control,
            reconcileOnInit: true,
            tunnelTimeout: 0
        )
        self.directory = directory
        self.commands = commands
        self.launcher = launcher
        self.control = control
        self.supervisor = supervisor
        self.session = session
        self.intentURL = intentURL
        self.configURL = configURL
    }

    var pidFile: String { supervisor.stateDir + "/kernel.pid" }

    func armEnvelope(generation: UInt64 = 4) throws -> HelperEnvelope {
        try HelperEnvelope.arm(ArmIntent(
            generation: generation,
            anchorRevision: 1,
            manifestDigest: "abc",
            egress: [],
            exitIfaces: [],
            strict: false,
            evidence: ArmEvidence(policyVersion: nil, posture: "off")
        ))
    }

    func disarmEnvelope(generation: UInt64 = 4) throws -> HelperEnvelope {
        try HelperEnvelope.disarm(DisarmIntent(generation: generation, intent: .userDisconnect))
    }

    /// The system DNS servers, as the fake networksetup holds them.
    func serviceServers() -> [[String]] {
        commands.services.map(\.servers)
    }

    func resolverText() -> String? {
        commands.files[directory.appendingPathComponent("resolver/example.com").path]
    }

    func resolverFilePresent() -> Bool {
        resolverText() != nil
    }
}

final class HelperSessionKernelTests: XCTestCase {
    // MARK: arm

    func testArmStartsTheKernelThenConvergesToTheTunnel() throws {
        let rig = try KernelRig()
        rig.control.status = KernelControlStatus(
            state: "connected", tunInterface: "utun4", routes: "installed"
        )
        let reply = try rig.session.handle(rig.armEnvelope())
        XCTAssertEqual(rig.launcher.procs.count, 1, "arm starts the kernel")
        XCTAssertEqual(rig.supervisor.snapshot().pid, rig.launcher.latest.pid)
        XCTAssertEqual(rig.supervisor.snapshot().tunInterface, "utun4")
        XCTAssertEqual(rig.supervisor.snapshot().dnsAddress, KernelRig.kernelDNS)
        XCTAssertEqual(reply.status?.kernel?.state, "running")
        XCTAssertEqual(reply.status?.kernel?.pid, rig.launcher.latest.pid)
        XCTAssertEqual(reply.status?.kernel?.lastExit, nil)
        XCTAssertEqual(reply.status?.tunInterface, "utun4")
        // Connected: resolver files name the kernel port. System DNS is
        // left alone, so other names keep their servers.
        XCTAssertEqual(rig.serviceServers(), [["192.0.2.1"], []])
        XCTAssertTrue(rig.resolverFilePresent())
        XCTAssertEqual(rig.resolverText(), "# managed by segue.ailock\nnameserver 127.0.0.1\nport 53\n")
        XCTAssertEqual(reply.status?.dnsMode, AILayerState.kernel)
        XCTAssertEqual(reply.status?.aiLayer, AILayerState.tunnel)
        XCTAssertEqual(reply.status?.resolverFilesPresent, true)
    }

    func testArmHoldsTheGuardWhileTheCarrierComesUp() throws {
        let rig = try KernelRig()
        rig.control.status = KernelControlStatus(state: "reconnecting")
        _ = try rig.session.handle(rig.armEnvelope())
        XCTAssertEqual(rig.launcher.procs.count, 1)
        XCTAssertTrue(rig.resolverFilePresent(), "names are held before the carrier is up")
        XCTAssertEqual(rig.resolverText(), "# managed by segue.ailock\nnameserver 127.0.0.1\nport 5354\n")
        XCTAssertEqual(rig.serviceServers(), [["192.0.2.1"], []])
        // A utun is open but the carrier is not connected: still the guard.
        rig.control.status = KernelControlStatus(state: "reconnecting", tunInterface: "utun5")
        _ = try rig.session.handle(HelperEnvelope.statusRead())
        XCTAssertEqual(rig.resolverText(), "# managed by segue.ailock\nnameserver 127.0.0.1\nport 5354\n")
        XCTAssertNil(rig.supervisor.snapshot().dnsAddress)
        // Connected: the next converge replaces the files with the kernel port.
        rig.control.status = KernelControlStatus(
            state: "connected", tunInterface: "utun5", routes: "installed"
        )
        _ = try rig.session.handle(HelperEnvelope.statusRead())
        XCTAssertEqual(rig.serviceServers(), [["192.0.2.1"], []])
        XCTAssertEqual(rig.resolverText(), "# managed by segue.ailock\nnameserver 127.0.0.1\nport 53\n")
        XCTAssertFalse(rig.commands.invocations.contains { $0.hasPrefix("remove ") && $0.contains("/resolver/") })
    }

    func testArmWithANonStandardPortWritesThatPort() throws {
        // Port 15353 cannot be a networksetup server. The resolver file
        // carries it; system DNS stays put.
        let rig = try KernelRig(dnsListen: "127.0.0.1:15353")
        rig.control.status = KernelControlStatus(
            state: "connected", tunInterface: "utun4", routes: "installed"
        )
        let reply = try rig.session.handle(rig.armEnvelope())
        XCTAssertEqual(rig.resolverText(), "# managed by segue.ailock\nnameserver 127.0.0.1\nport 15353\n")
        XCTAssertEqual(rig.serviceServers(), [["192.0.2.1"], []])
        XCTAssertEqual(reply.status?.dnsMode, AILayerState.kernel)
        XCTAssertEqual(reply.status?.aiLayer, AILayerState.tunnel)
    }

    func testArmWithoutAPublishedDNSAddressStaysOnTheGuard() throws {
        let rig = try KernelRig(dnsListen: nil)
        rig.control.status = KernelControlStatus(
            state: "connected", tunInterface: "utun4", routes: "installed"
        )
        let reply = try rig.session.handle(rig.armEnvelope())
        XCTAssertEqual(rig.resolverText(), "# managed by segue.ailock\nnameserver 127.0.0.1\nport 5354\n")
        XCTAssertEqual(reply.status?.dnsMode, AILayerState.guardMode)
        XCTAssertEqual(reply.status?.aiLayer, AILayerState.guardMode)
        XCTAssertNotEqual(reply.status?.aiLayer, AILayerState.system)
    }

    // MARK: disarm

    func testDisarmReleasesTheLayerBeforeTheKernelStops() throws {
        let rig = try KernelRig()
        rig.control.status = KernelControlStatus(
            state: "connected", tunInterface: "utun4", routes: "installed"
        )
        _ = try rig.session.handle(rig.armEnvelope())
        XCTAssertEqual(rig.serviceServers(), [["192.0.2.1"], []])
        // By SIGTERM the resolver files are gone. System DNS was never rewritten.
        var serversAtSignal: [[[String]]] = []
        var filesAtSignal: [Bool] = []
        let proc = rig.launcher.latest
        rig.launcher.onSend = { _, _ in
            serversAtSignal.append(rig.commands.services.map(\.servers))
            filesAtSignal.append(rig.resolverFilePresent())
        }
        _ = try rig.session.handle(rig.disarmEnvelope())
        XCTAssertEqual(proc.signals, [SIGTERM])
        XCTAssertEqual(serversAtSignal.count, 1)
        XCTAssertEqual(serversAtSignal.first ?? [], [["192.0.2.1"], []])
        XCTAssertEqual(filesAtSignal, [false])
        XCTAssertFalse(rig.resolverFilePresent())
        XCTAssertEqual(rig.supervisor.snapshot().state, "stopped")
        XCTAssertEqual(rig.launcher.procs.count, 1, "a disarm does not relaunch")
        XCTAssertNil(rig.supervisor.snapshot().tunInterface)
    }

    // MARK: crash

    func testCrashRestartsAndHoldsTheGuardWhileDown() throws {
        let rig = try KernelRig()
        rig.control.status = KernelControlStatus(
            state: "connected", tunInterface: "utun4", routes: "installed"
        )
        _ = try rig.session.handle(rig.armEnvelope())
        XCTAssertEqual(rig.resolverText(), "# managed by segue.ailock\nnameserver 127.0.0.1\nport 53\n")
        // The tunnel dies with the process: the control API stops
        // answering before the crash lands.
        rig.control.status = nil
        rig.launcher.latest.finish(.code(4))
        XCTAssertEqual(rig.launcher.procs.count, 2, "a crash restarts inside the budget")
        XCTAssertEqual(rig.supervisor.snapshot().state, "running")
        XCTAssertEqual(rig.supervisor.snapshot().lastExit, "tun_setup_failed")
        XCTAssertEqual(
            rig.resolverText(),
            "# managed by segue.ailock\nnameserver 127.0.0.1\nport 5354\n",
            "kernel down: names are held by the guard"
        )
        XCTAssertEqual(rig.serviceServers(), [["192.0.2.1"], []])
        XCTAssertNil(rig.supervisor.snapshot().tunInterface)
    }

    func testRestartBudgetExhaustionKeepsTheLayer() throws {
        let rig = try KernelRig(restartLimit: 1)
        rig.control.status = nil
        _ = try rig.session.handle(rig.armEnvelope())
        rig.launcher.latest.finish(.code(1))
        XCTAssertEqual(rig.launcher.procs.count, 2)
        rig.launcher.latest.finish(.code(1))
        XCTAssertEqual(rig.launcher.procs.count, 2, "the budget is spent; it stays down")
        XCTAssertEqual(rig.supervisor.snapshot().state, "kernel_failed")
        XCTAssertEqual(rig.supervisor.snapshot().lastExit, "listener_failed")
        // The layer was never released: armed names are still held.
        XCTAssertTrue(rig.resolverFilePresent())
        XCTAssertEqual(try IntentStore(fileURL: rig.intentURL).load()?.armed, true)
    }

    func testStatusReadCarriesTheRedactedStderrTailWhenKernelFailed() throws {
        let rig = try KernelRig(restartLimit: 1)
        rig.control.status = nil
        // What the captured kernel.stderr would hold after the crash loop.
        try Data("listener failed: Bearer abcdefghijklmnop\n".utf8)
            .write(to: rig.directory.appendingPathComponent("kernel.stderr"))
        _ = try rig.session.handle(rig.armEnvelope())
        rig.launcher.latest.finish(.code(1))
        rig.launcher.latest.finish(.code(1))
        XCTAssertEqual(rig.supervisor.snapshot().state, "kernel_failed")
        let reply = try rig.session.handle(HelperEnvelope.statusRead())
        XCTAssertEqual(reply.status?.kernel?.state, "kernel_failed")
        let tail = try XCTUnwrap(reply.status?.kernel?.lastStderr)
        XCTAssertTrue(tail.contains("listener failed"))
        XCTAssertNil(tail.range(of: "abcdefghijklmnop"), "the tail is redacted on the wire")
    }

    // MARK: helper restart

    func testHelperRestartWithArmedIntentReArmsAndStartsTheKernel() throws {
        let rig = try KernelRig(armedIntent: true)
        // A helper restart: same intent store, fresh everything else.
        let control = FakeControlClient()
        let launcher = FakeLauncher()
        let supervisor = KernelSupervisor(
            kernelPath: "/bin/segue-kernel",
            configPath: rig.configURL.path,
            stateDir: rig.supervisor.stateDir,
            launcher: launcher,
            logPath: rig.directory.appendingPathComponent("kernel.log").path,
            control: control
        )
        let commands = RecordingSystemCommands()
        let layer = AILayerController(
            commands: commands,
            kernel: supervisor,
            list: AILockList(suffixes: ["example.com"], cidrs: []),
            paths: AILayerPaths(
                pfConfPath: rig.directory.appendingPathComponent("pf.conf").path,
                resolverDirectory: rig.directory.appendingPathComponent("resolver").path,
                snapshotPath: rig.directory.appendingPathComponent("dns-snapshot.json").path,
                guardAddress: "127.0.0.1",
                guardPort: AILayerPaths.defaultGuardPort
            )
        )
        _ = HelperSession(
            store: IntentStore(fileURL: rig.intentURL),
            kernel: supervisor,
            layer: layer,
            control: control,
            reconcileOnInit: true,
            tunnelTimeout: 0
        )
        XCTAssertEqual(launcher.procs.count, 1, "the kernel is started again")
        XCTAssertEqual(supervisor.snapshot().state, "running")
        XCTAssertTrue(
            commands.fileExists(rig.directory.appendingPathComponent("resolver/example.com").path),
            "the narrow layer is re-armed"
        )
    }

    func testFreshHelperWithClearIntentStartsNothing() throws {
        let rig = try KernelRig(armedIntent: false)
        _ = try rig.session.handle(HelperEnvelope.statusRead())
        XCTAssertEqual(rig.launcher.procs.count, 0, "clear intent starts no kernel")
        XCTAssertEqual(rig.supervisor.snapshot().state, "stopped")
        XCTAssertFalse(rig.resolverFilePresent())
    }

    // MARK: orphan takeover

    func testStartTakesOverAnOrphanKernelBeforeSpawning() throws {
        // A previous helper died without stopping its kernel: the pid file
        // names a live process. The probe answers "alive and named like the
        // kernel" once, then "gone", as if the SIGTERM had worked.
        let orphan: Int32 = 31_337
        var probes = 0
        let rig = try KernelRig(externalProbe: { pid, name in
            guard pid == orphan, name == "segue-kernel" else { return false }
            probes += 1
            return probes == 1
        })
        try Data("\(orphan)\n".utf8).write(to: URL(fileURLWithPath: rig.pidFile))
        _ = try rig.session.handle(rig.armEnvelope())
        XCTAssertGreaterThanOrEqual(probes, 2, "the orphan was probed and waited on")
        XCTAssertEqual(rig.launcher.procs.count, 1, "a fresh child spawned after the takeover")
        XCTAssertEqual(rig.supervisor.snapshot().pid, rig.launcher.latest.pid)
        let rewritten = try String(contentsOfFile: rig.pidFile, encoding: .utf8)
        XCTAssertEqual(rewritten.trimmingCharacters(in: .whitespacesAndNewlines), "\(rig.launcher.latest.pid)")
    }

    func testStalePIDFileIsIgnored() throws {
        // After a reboot the pid in the file is some other process (the
        // probe answers "not our kernel"): no signal is sent, the file is
        // cleared, and a fresh child spawns.
        var probes = 0
        let rig = try KernelRig(externalProbe: { _, _ in
            probes += 1
            return false
        })
        try Data("31338\n".utf8).write(to: URL(fileURLWithPath: rig.pidFile))
        try rig.session.handle(rig.armEnvelope())
        XCTAssertEqual(probes, 1, "the stale pid was probed once and dropped")
        XCTAssertEqual(rig.launcher.procs.count, 1)
        let rewritten = try String(contentsOfFile: rig.pidFile, encoding: .utf8)
        XCTAssertEqual(rewritten.trimmingCharacters(in: .whitespacesAndNewlines), "\(rig.launcher.latest.pid)")
    }
}
