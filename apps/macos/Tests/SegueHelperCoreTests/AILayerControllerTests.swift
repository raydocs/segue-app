import Foundation
import SegueAILayer
import SegueHelperProtocol
import XCTest

@testable import SegueHelperCore

final class FakeKernel: KernelControlling {
    var snap: KernelSnapshot
    private(set) var starts = 0
    private(set) var stops = 0
    var onStateChange: (() -> Void)?

    init(_ snap: KernelSnapshot) {
        self.snap = snap
    }

    func snapshot() -> KernelSnapshot { snap }

    func start() throws { starts += 1 }

    func stop() { stops += 1 }
}

final class LayerRig {
    let commands: RecordingSystemCommands
    let kernel: FakeKernel
    let controller: AILayerController
    let paths: AILayerPaths
    let list: AILockList

    static let kernelDNS = "192.0.2.53"
    static let suffixes = ["example.com", "example.org"]

    init(tunnelUp: Bool) throws {
        let commands = RecordingSystemCommands()
        let kernel = FakeKernel(KernelSnapshot(
            state: tunnelUp ? "running" : "stopped",
            pid: tunnelUp ? 42 : nil,
            lastExit: nil,
            tunInterface: tunnelUp ? "utun4" : nil,
            dnsAddress: tunnelUp ? Self.kernelDNS : nil
        ))
        let paths = AILayerPaths(
            pfConfPath: "/etc/pf.conf",
            resolverDirectory: "/etc/resolver",
            snapshotPath: "/Library/Application Support/Segue/dns-snapshot.json",
            guardAddress: "127.0.0.1",
            guardPort: AILayerPaths.defaultGuardPort
        )
        let list = AILockList(
            suffixes: Self.suffixes,
            cidrs: [try CIDR(parsing: "192.0.2.0/24")]
        )
        self.commands = commands
        self.kernel = kernel
        self.paths = paths
        self.list = list
        controller = AILayerController(
            commands: commands,
            kernel: kernel,
            list: list,
            paths: paths
        )
    }

    func servers(_ name: String) -> [String]? {
        commands.services.first { $0.name == name }?.servers
    }

    func openness() -> Openness {
        let files = Self.suffixes.allSatisfy { suffix in
            commands.files[paths.resolverDirectory + "/" + suffix] != nil
        }
        let pointed = !commands.services.isEmpty && commands.services.allSatisfy {
            $0.servers == [Self.kernelDNS]
        }
        return Openness(anchorLoaded: commands.anchorRules != nil, namesHeld: files || pointed)
    }
}

struct Openness: Equatable, CustomStringConvertible {
    var anchorLoaded: Bool
    var namesHeld: Bool

    var description: String { "anchor=\(anchorLoaded) names=\(namesHeld)" }
}

private func isMoreOpen(_ before: Openness, _ after: Openness) -> Bool {
    if before.anchorLoaded && !after.anchorLoaded { return true }
    if before.namesHeld && !after.namesHeld { return true }
    return false
}

private func armEnvelope(generation: UInt64 = 4) throws -> HelperEnvelope {
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

final class AILayerControllerTests: XCTestCase {
    func testParsersSkipDisabledServicesAndEmptyDNS() {
        let text = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (2) *Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)

        """
        let parsed = SystemText.serviceOrder(text)
        XCTAssertEqual(parsed.map(\.name), ["Wi-Fi"])
        XCTAssertEqual(parsed.map(\.serviceID), ["en0"])
        XCTAssertEqual(
            SystemText.dnsServers("There aren't any DNS Servers set on Wi-Fi.\n"),
            []
        )
        XCTAssertEqual(
            SystemText.dnsServers("192.0.2.1\n192.0.2.2\n"),
            ["192.0.2.1", "192.0.2.2"]
        )
        XCTAssertTrue(SystemText.listsAnchor("  segue.ailock\n", name: "segue.ailock"))
        XCTAssertFalse(SystemText.listsAnchor("  segue.ailock.extra\n", name: "segue.ailock"))
        XCTAssertFalse(SystemText.anchorHasRules(""))
        XCTAssertFalse(SystemText.anchorHasRules("No ALTQ support in kernel\nALTQ related functions disabled\n"))
        XCTAssertTrue(SystemText.anchorHasRules(
            "block drop out quick inet from any to 198.51.100.0/24 label \"segue-ai-0\"\n"
        ))
        XCTAssertEqual(AILayerController.normalizeAddress("192.0.2.53:53"), "192.0.2.53")
        XCTAssertNil(AILayerController.normalizeAddress("192.0.2.53:5354"))
        XCTAssertNil(AILayerController.utunName("en0"))
        XCTAssertEqual(AILayerController.utunName("utun4"), "utun4")
    }

    func testArmTunnelDownWritesGuardAndLeavesSystemDNS() throws {
        let rig = try LayerRig(tunnelUp: false)
        rig.commands.seedFile("/etc/pf.conf", contents: "anchor \"com.apple/*\"\n")
        try rig.controller.arm()

        let pf = try XCTUnwrap(rig.commands.files["/etc/pf.conf"])
        XCTAssertEqual(pf, "anchor \"com.apple/*\"\nanchor \"segue.ailock\"\n")
        XCTAssertFalse(pf.contains("load anchor"))
        let rules = try XCTUnwrap(rig.commands.anchorRules)
        XCTAssertTrue(rules.contains("pass quick on lo0"))
        XCTAssertFalse(rules.contains("utun"))
        XCTAssertTrue(rules.contains(
            "block drop out quick inet to 192.0.2.0/24 label \"segue-ai-0\""
        ))
        XCTAssertFalse(rules.contains("block drop all"))
        XCTAssertFalse(rules.contains("user "))
        XCTAssertEqual(
            rig.commands.files["/etc/resolver/example.com"],
            "# managed by segue.ailock\nnameserver 127.0.0.1\nport 5354\n"
        )
        XCTAssertNotNil(rig.commands.files["/etc/resolver/example.org"])
        XCTAssertEqual(rig.commands.guardPort, 5354)
        XCTAssertEqual(Set(rig.commands.guardSuffixes), Set(LayerRig.suffixes))
        XCTAssertEqual(rig.servers("Wi-Fi"), ["192.0.2.1"])
        XCTAssertEqual(rig.servers("Ethernet"), [])
        XCTAssertNil(rig.commands.files[rig.paths.snapshotPath])
        XCTAssertTrue(rig.commands.invocations.contains("/sbin/pfctl -a segue.ailock -f -"))
        XCTAssertFalse(rig.commands.invocations.contains { $0.contains(" -F all") })

        let observed = try rig.controller.observe()
        XCTAssertEqual(observed.dnsMode, AILayerState.guardMode)
        XCTAssertTrue(observed.anchorLoaded)
        XCTAssertTrue(observed.resolverFilesPresent)
        XCTAssertTrue(observed.guardListening)
        XCTAssertFalse(observed.dnsReadback)
    }

    func testArmTunnelUpPointsDNSAtTheKernel() throws {
        let rig = try LayerRig(tunnelUp: true)
        try rig.controller.arm()

        let rules = try XCTUnwrap(rig.commands.anchorRules)
        XCTAssertTrue(rules.contains("pass quick on utun4"))
        XCTAssertTrue(rules.contains("label \"segue-ai-0\""))
        XCTAssertFalse(rules.contains("block drop all"))
        XCTAssertNil(rig.commands.files["/etc/resolver/example.com"])
        XCTAssertNil(rig.commands.guardPort)
        XCTAssertEqual(rig.servers("Wi-Fi"), [LayerRig.kernelDNS])
        XCTAssertEqual(rig.servers("Ethernet"), [LayerRig.kernelDNS])
        let snapshot = try XCTUnwrap(rig.commands.files[rig.paths.snapshotPath])
        XCTAssertTrue(snapshot.contains("192.0.2.1"))
        XCTAssertFalse(snapshot.contains(LayerRig.kernelDNS))
        XCTAssertTrue(rig.commands.invocations.contains(
            "/usr/sbin/networksetup -setdnsservers Wi-Fi \(LayerRig.kernelDNS)"
        ))
        XCTAssertTrue(rig.commands.invocations.contains(
            "/usr/sbin/networksetup -setdnsservers Ethernet \(LayerRig.kernelDNS)"
        ))

        let observed = try rig.controller.observe()
        XCTAssertEqual(observed.dnsMode, AILayerState.tunnel)
        XCTAssertTrue(observed.anchorLoaded)
        XCTAssertFalse(observed.resolverFilesPresent)
        XCTAssertFalse(observed.guardListening)
        XCTAssertTrue(observed.dnsReadback)

        let saved = snapshot
        try rig.controller.arm()
        XCTAssertEqual(rig.commands.files[rig.paths.snapshotPath], saved)
        let pf = try XCTUnwrap(rig.commands.files["/etc/pf.conf"])
        XCTAssertEqual(pf.components(separatedBy: "anchor \"segue.ailock\"").count - 1, 1)
    }

    func testDisarmRestoresDNSBeforeFlushingTheAnchor() throws {
        let rig = try LayerRig(tunnelUp: true)
        try rig.controller.arm()
        rig.commands.discardLog()
        try rig.controller.disarm()

        let flush = try XCTUnwrap(rig.commands.invocations.firstIndex { $0.contains("-F all") })
        let restore = try XCTUnwrap(
            rig.commands.invocations.firstIndex { $0.contains("-setdnsservers Wi-Fi 192.0.2.1") }
        )
        let remove = try XCTUnwrap(
            rig.commands.invocations.firstIndex { $0.hasPrefix("remove /etc/resolver/") }
        )
        XCTAssertLessThan(restore, remove)
        XCTAssertLessThan(remove, flush)
        let between = rig.commands.invocations[(restore + 1)..<flush]
        XCTAssertTrue(between.contains { $0.contains("-getdnsservers Wi-Fi") })
        XCTAssertTrue(rig.commands.invocations.contains(
            "/usr/sbin/networksetup -setdnsservers Ethernet Empty"
        ))

        XCTAssertNil(rig.commands.anchorRules)
        XCTAssertNil(rig.commands.files["/etc/resolver/example.com"])
        XCTAssertNil(rig.commands.guardPort)
        XCTAssertEqual(rig.servers("Wi-Fi"), ["192.0.2.1"])
        XCTAssertEqual(rig.servers("Ethernet"), [])
        XCTAssertNil(rig.commands.files[rig.paths.snapshotPath])
        let observed = try rig.controller.observe()
        XCTAssertEqual(observed.dnsMode, AILayerState.system)
        XCTAssertFalse(observed.anchorLoaded)

        try rig.controller.disarm()
        XCTAssertNil(rig.commands.anchorRules)
        XCTAssertEqual(try rig.controller.observe().dnsMode, AILayerState.system)
        XCTAssertEqual(rig.servers("Wi-Fi"), ["192.0.2.1"])
    }

    func testKernelDeathKeepsTheLayerOnTheGuard() throws {
        let rig = try LayerRig(tunnelUp: true)
        try rig.controller.arm()
        rig.kernel.snap = KernelSnapshot(
            state: "stopped",
            pid: nil,
            lastExit: "clean_shutdown",
            tunInterface: nil,
            dnsAddress: nil
        )
        try rig.controller.kernelChanged()

        let rules = try XCTUnwrap(rig.commands.anchorRules)
        XCTAssertFalse(rules.contains("utun"))
        XCTAssertTrue(rules.contains("segue-ai-0"))
        XCTAssertNotNil(rig.commands.files["/etc/resolver/example.com"])
        XCTAssertEqual(rig.commands.guardPort, 5354)
        XCTAssertEqual(rig.servers("Wi-Fi"), ["192.0.2.1"])
        XCTAssertEqual(rig.servers("Ethernet"), [])
        let observed = try rig.controller.observe()
        XCTAssertEqual(observed.dnsMode, AILayerState.guardMode)
        XCTAssertTrue(observed.anchorLoaded)
        XCTAssertTrue(observed.resolverFilesPresent)
        XCTAssertTrue(observed.guardListening)
    }

    func testHelperRestartWhileArmedRearmsTheNarrowLayer() throws {
        let rig = try LayerRig(tunnelUp: true)
        try rig.controller.arm()
        let restartedKernel = FakeKernel(KernelSnapshot(state: "stopped", pid: nil, lastExit: nil))
        let restarted = AILayerController(
            commands: rig.commands,
            kernel: restartedKernel,
            list: rig.list,
            paths: rig.paths
        )
        rig.commands.discardLog()
        try restarted.reconcileOnLaunch()

        XCTAssertFalse(rig.commands.invocations.contains { $0.contains(" -F all") })
        XCTAssertFalse(rig.commands.invocations.contains { $0.hasPrefix("remove ") })
        XCTAssertNotNil(rig.commands.files["/etc/resolver/example.com"])
        XCTAssertEqual(rig.servers("Wi-Fi"), ["192.0.2.1"])
        XCTAssertEqual(rig.servers("Ethernet"), [])
        let rules = try XCTUnwrap(rig.commands.anchorRules)
        XCTAssertFalse(rules.contains("utun"))
        XCTAssertTrue(rules.contains("block drop out quick"))
        XCTAssertEqual(try restarted.observe().dnsMode, AILayerState.guardMode)
    }

    func testClearIntentOnStartInstallsNothing() throws {
        let rig = try LayerRig(tunnelUp: false)
        rig.commands.seedAnchor("pass quick on lo0\n")
        rig.commands.seedFile(
            "/etc/resolver/example.com",
            contents: "nameserver 127.0.0.1\nport 5354\n"
        )
        let directory = try temporaryDirectory("layer-clear")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = HelperSession(
            store: IntentStore(fileURL: directory.appendingPathComponent("ai-lock.intent")),
            kernel: rig.kernel,
            layer: rig.controller
        )
        XCTAssertEqual(rig.commands.anchorRules, "pass quick on lo0\n")
        XCTAssertNotNil(rig.commands.files["/etc/resolver/example.com"])
        XCTAssertFalse(rig.commands.invocations.contains { $0.contains(" -F all") || $0.hasPrefix("remove ") })
    }

    func testSessionRestartWhileArmedReportsTheGuard() throws {
        let directory = try temporaryDirectory("layer-session")
        defer { try? FileManager.default.removeItem(at: directory) }
        let intentURL = directory.appendingPathComponent("state/ai-lock.intent")
        try IntentStore(fileURL: intentURL).save(
            StoredIntent(armed: true, generation: 9, name: "user_connect")
        )
        let rig = try LayerRig(tunnelUp: false)
        let session = HelperSession(
            store: IntentStore(fileURL: intentURL),
            kernel: rig.kernel,
            layer: rig.controller
        )
        let status = try XCTUnwrap(try session.handle(HelperEnvelope.statusRead()).status)
        XCTAssertTrue(status.armed)
        XCTAssertEqual(status.generation, 9)
        XCTAssertEqual(status.aiLayer, AILayerState.guardMode)
        XCTAssertEqual(status.dnsMode, "guard")
        XCTAssertEqual(status.anchorLoaded, true)
        XCTAssertEqual(status.resolverFilesPresent, true)
        XCTAssertEqual(status.guardListening, true)
        XCTAssertNotEqual(status.aiLayer, AILayerState.notImplemented)
        XCTAssertNil(status.lastError)
    }

    func testSessionArmFailureIsRetriedAndKeepsIntent() throws {
        let directory = try temporaryDirectory("layer-fail-arm")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try LayerRig(tunnelUp: true)
        rig.commands.failCallIndex = 0
        let session = HelperSession(
            store: IntentStore(fileURL: directory.appendingPathComponent("ai-lock.intent")),
            kernel: rig.kernel,
            layer: rig.controller,
            tunnelTimeout: 0
        )
        let reply = try session.handle(try armEnvelope())
        let status = try XCTUnwrap(reply.status)
        XCTAssertTrue(status.armed)
        XCTAssertNotEqual(status.aiLayer, AILayerState.notImplemented)
        XCTAssertEqual(
            try IntentStore(fileURL: directory.appendingPathComponent("ai-lock.intent")).load()?.armed,
            true
        )
        // The arm's install threw, the intent stayed, and the converge
        // that follows the kernel start (here the fake answers right
        // away) recovered the layer on the spot.
        XCTAssertNil(status.lastError)
        XCTAssertEqual(status.anchorLoaded, true)
        XCTAssertNotNil(rig.commands.anchorRules)
    }

    func testSessionPersistentArmFailureReportsLastError() throws {
        let directory = try temporaryDirectory("layer-fail-persistent")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try LayerRig(tunnelUp: true)
        rig.commands.failEveryCall = true
        let session = HelperSession(
            store: IntentStore(fileURL: directory.appendingPathComponent("ai-lock.intent")),
            kernel: rig.kernel,
            layer: rig.controller,
            tunnelTimeout: 0
        )
        let reply = try session.handle(try armEnvelope())
        let status = try XCTUnwrap(reply.status)
        XCTAssertTrue(status.armed)
        XCTAssertEqual(status.lastError, "command_failed")
        XCTAssertEqual(status.anchorLoaded, false)
        XCTAssertEqual(
            try IntentStore(fileURL: directory.appendingPathComponent("ai-lock.intent")).load()?.armed,
            true
        )
        XCTAssertNil(rig.commands.anchorRules)
    }

    func testSessionStatusReadBackAfterKernelDeath() throws {
        let directory = try temporaryDirectory("layer-death")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try LayerRig(tunnelUp: true)
        let session = HelperSession(
            store: IntentStore(fileURL: directory.appendingPathComponent("ai-lock.intent")),
            kernel: rig.kernel,
            layer: rig.controller,
            tunnelTimeout: 0
        )
        let armed = try XCTUnwrap(try session.handle(try armEnvelope()).status)
        XCTAssertEqual(armed.dnsMode, AILayerState.tunnel)
        XCTAssertEqual(armed.tunInterface, "utun4")
        XCTAssertEqual(armed.aiLayer, "tunnel")
        XCTAssertTrue(armed.evidence.dnsReadback)

        rig.kernel.snap = KernelSnapshot(
            state: "kernel_failed",
            pid: nil,
            lastExit: "signal_9",
            tunInterface: nil,
            dnsAddress: nil
        )
        let after = try XCTUnwrap(try session.handle(HelperEnvelope.statusRead()).status)
        XCTAssertTrue(after.armed)
        XCTAssertEqual(after.dnsMode, AILayerState.guardMode)
        XCTAssertEqual(after.aiLayer, "guard")
        XCTAssertEqual(after.anchorLoaded, true)
        XCTAssertEqual(after.resolverFilesPresent, true)
        XCTAssertEqual(after.guardListening, true)
        XCTAssertNil(after.tunInterface)
        XCTAssertEqual(after.lastError, "kernel_failed")
        XCTAssertEqual(rig.servers("Wi-Fi"), ["192.0.2.1"])

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(HelperEnvelope.status(after))) as? [String: Any]
        )
        let body = try XCTUnwrap(object["status"] as? [String: Any])
        XCTAssertEqual(body["ai_layer"] as? String, "guard")
        XCTAssertEqual(body["dns_mode"] as? String, "guard")
        XCTAssertEqual(body["anchor_loaded"] as? Bool, true)
        XCTAssertEqual(body["resolver_files"] as? Bool, true)
        XCTAssertEqual(body["guard_listening"] as? Bool, true)
        XCTAssertNotEqual(body["ai_layer"] as? String, "not_implemented")
    }

    func testFailureDuringArmIsNeverMoreOpen() throws {
        try assertFailuresNeverOpen(
            { try LayerRig(tunnelUp: true) },
            { try $0.controller.arm() }
        )
        try assertFailuresNeverOpen(
            { try LayerRig(tunnelUp: false) },
            { try $0.controller.arm() }
        )
    }

    func testFailureSwitchingToTunnelIsNeverMoreOpen() throws {
        try assertFailuresNeverOpen(
            {
                let rig = try LayerRig(tunnelUp: false)
                try rig.controller.arm()
                rig.kernel.snap = KernelSnapshot(
                    state: "running",
                    pid: 7,
                    lastExit: nil,
                    tunInterface: "utun4",
                    dnsAddress: LayerRig.kernelDNS
                )
                return rig
            },
            { try $0.controller.kernelChanged() }
        )
    }

    func testFailureDuringKernelDeathIsNeverMoreOpen() throws {
        try assertFailuresNeverOpen(
            {
                let rig = try LayerRig(tunnelUp: true)
                try rig.controller.arm()
                rig.kernel.snap = KernelSnapshot(
                    state: "stopped",
                    pid: nil,
                    lastExit: nil,
                    tunInterface: nil,
                    dnsAddress: nil
                )
                return rig
            },
            { try $0.controller.kernelChanged() }
        )
    }

    func testFailureDuringDisarmIsNeverMoreOpen() throws {
        try assertFailuresNeverOpen(
            {
                let rig = try LayerRig(tunnelUp: true)
                try rig.controller.arm()
                return rig
            },
            { try $0.controller.disarm() }
        )
        try assertFailuresNeverOpen(
            {
                let rig = try LayerRig(tunnelUp: false)
                try rig.controller.arm()
                return rig
            },
            { try $0.controller.disarm() }
        )
    }

    private func assertFailuresNeverOpen(
        _ prepare: () throws -> LayerRig,
        _ op: (LayerRig) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var failures = 0
        for step in 0..<48 {
            let rig = try prepare()
            rig.commands.failCallIndex = step
            rig.commands.resetCounter()
            let before = rig.openness()
            do {
                try op(rig)
                if rig.commands.injected.isEmpty { break }
            } catch {
                failures += 1
                let after = rig.openness()
                XCTAssertFalse(
                    isMoreOpen(before, after),
                    "step \(step) \(rig.commands.injected) before \(before) after \(after)",
                    file: file,
                    line: line
                )
            }
        }
        XCTAssertGreaterThan(failures, 0, file: file, line: line)
    }
}
