import Foundation
import SegueAILayer
import SegueHelperProtocol

struct AILayerPaths: Equatable {
    static let defaultGuardPort: UInt16 = 5354

    var pfConfPath: String
    var resolverDirectory: String
    var snapshotPath: String
    var guardAddress: String
    var guardPort: UInt16
}

struct AILayerObservation: Equatable {
    var anchorLoaded: Bool
    var resolverFilesPresent: Bool
    var guardListening: Bool
    /// `tunnel`, `guard`, or `system`.
    var dnsMode: String
    var dnsReadback: Bool

    var namesHeld: Bool {
        dnsMode == AILayerState.tunnel || dnsMode == AILayerState.guardMode
    }

    static let unknown = AILayerObservation(
        anchorLoaded: false,
        resolverFilesPresent: false,
        guardListening: false,
        dnsMode: AILayerState.system,
        dnsReadback: false
    )
}

enum AILayerError: Error, Equatable {
    case command(program: String, status: Int32, message: String)
    case hookRejected
    case invalidInterface
    case snapshotUnreadable
    case snapshotRefused
    case dnsReadbackMismatch(service: String)
    case io(String)

    var code: String {
        switch self {
        case .command: return "command_failed"
        case .hookRejected: return "pf_hook_rejected"
        case .invalidInterface: return "invalid_interface"
        case .snapshotUnreadable: return "dns_snapshot_unreadable"
        case .snapshotRefused: return "dns_snapshot_refused"
        case .dnsReadbackMismatch: return "dns_readback_mismatch"
        case .io: return "io_failed"
        }
    }

    static func code(of error: Error) -> String {
        if let error = error as? AILayerError { return error.code }
        return "command_failed"
    }
}

/// Installs and removes the narrow AI layer: PF anchor `segue.ailock`,
/// per-service DNS, `/etc/resolver` files, and the helper's loopback
/// listener.
///
/// A failure mid-way leaves the layer more closed, never less. Resolver
/// files go in before a restore that would move DNS off the kernel
/// resolver, and the anchor is flushed only after that restore has been
/// read back. Startup (`reconcileOnLaunch`) re-arms the narrow layer and
/// never releases it.
public final class AILayerController {
    private let commands: SystemCommands
    private let kernel: KernelSupervising
    private let list: AILockList
    private let paths: AILayerPaths
    private let lock = NSLock()
    /// Address we last pointed services at. Not persisted: a restart learns
    /// the original servers from the snapshot file and pins names with
    /// resolver files before restoring them.
    private var kernelDNSAddress: String?
    private var dnsReadbackOK = false

    init(commands: SystemCommands, kernel: KernelSupervising, list: AILockList, paths: AILayerPaths) {
        self.commands = commands
        self.kernel = kernel
        self.list = list
        self.paths = paths
    }

    /// Production wiring. Talks to pfctl, networksetup, and the real
    /// filesystem. Tests must not call this.
    public static func live(kernel: KernelSupervising, paths: HelperPaths) -> AILayerController {
        let snapshot = URL(fileURLWithPath: paths.intentPath)
            .deletingLastPathComponent()
            .appendingPathComponent("dns-snapshot.json")
            .path
        return AILayerController(
            commands: LiveSystemCommands(),
            kernel: kernel,
            list: loadList(paths.aiLockPath),
            paths: AILayerPaths(
                pfConfPath: paths.pfConfPath,
                resolverDirectory: paths.resolverDirectory,
                snapshotPath: snapshot,
                guardAddress: ResolverFiles.nameserver,
                guardPort: paths.guardPort
            )
        )
    }

    /// Arm for the kernel's current tunnel. Idempotent.
    func arm() throws {
        try sync { try install(allowTunnelDNS: true) }
    }

    /// Explicit release. Idempotent. On failure the previous hold is put
    /// back before the error is rethrown.
    func disarm() throws {
        try sync { try release() }
    }

    /// Helper start. Armed intent re-installs the anchor and the resolver
    /// files and does not point DNS at the kernel. Disarmed intent is not
    /// this method's job: the session does not call it, so a clear intent
    /// installs nothing and releases nothing.
    func reconcileOnLaunch() throws {
        try sync { try install(allowTunnelDNS: false) }
    }

    /// Kernel liveness changed. Same converge as `arm`: tunnel up keeps
    /// DNS on the kernel, tunnel down switches to the guard without
    /// dropping the layer.
    func kernelChanged() throws {
        try sync { try install(allowTunnelDNS: true) }
    }

    func observe() throws -> AILayerObservation {
        try sync { try inspect() }
    }

    // MARK: - converge

    /// Caller holds `lock`.
    ///
    /// The guard is installed even when the anchor cannot be loaded. A
    /// pfctl failure used to skip the listener, so armed names fell through
    /// to the system resolver while the resolver file (written on a later
    /// retry) made the matrix think the guard was up. The anchor error is
    /// still reported; the names stay held.
    private func install(allowTunnelDNS: Bool) throws {
        let snap = kernel.snapshot()
        let utun = Self.utunName(snap.tunInterface)
        var anchorError: Error?
        do {
            try ensureHook()
            try loadAnchor(utun: utun)
        } catch {
            anchorError = error
        }
        if allowTunnelDNS, utun != nil, anchorError == nil,
           let dns = Self.normalizeAddress(snap.dnsAddress) {
            try applyTunnelDNS(dns)
        } else {
            try applyGuardDNS()
        }
        if let anchorError { throw anchorError }
    }

    /// Point every service at the kernel resolver, then drop the guard
    /// files. Files stay until the read-back matches, so a failed set cannot
    /// uncover names the files were holding.
    private func applyTunnelDNS(_ address: String) throws {
        let current = try captureServices()
        if current.isEmpty {
            try applyGuardDNS()
            return
        }
        kernelDNSAddress = address
        dnsReadbackOK = false
        try ensureSnapshot(current: current, kernelAddress: address)
        for service in current {
            try assign(name: service.name, current: service.servers, servers: [address])
        }
        dnsReadbackOK = true
        try removeGuard()
    }

    /// Resolver files and the listener first, then the saved servers. A
    /// restore that fails after the files are in place still holds AI names
    /// (the files win over the system resolver). Restoring first would open
    /// those names for the whole window until the write succeeded.
    private func applyGuardDNS() throws {
        try installGuard()
        try restoreSnapshot()
        kernelDNSAddress = nil
    }

    /// Caller holds `lock`.
    private func release() throws {
        let hold = try inspect()
        do {
            if hold.dnsMode == AILayerState.tunnel || shouldPinBeforeRestore(hold) {
                try installGuard()
            }
            try restoreSnapshot()
            try removeGuard()
            try flushAnchor()
            kernelDNSAddress = nil
            removeSnapshotBestEffort()
        } catch {
            switch hold.dnsMode {
            case AILayerState.tunnel:
                try? install(allowTunnelDNS: true)
            case AILayerState.guardMode:
                try? install(allowTunnelDNS: false)
            default:
                if hold.anchorLoaded {
                    try? ensureHook()
                    try? loadAnchor(utun: Self.utunName(kernel.snapshot().tunInterface))
                }
            }
            throw error
        }
    }

    /// A snapshot on disk means some earlier arm changed DNS. Pin names
    /// before putting the saved servers back, unless the guard files are
    /// already the hold.
    private func shouldPinBeforeRestore(_ hold: AILayerObservation) -> Bool {
        hold.dnsMode != AILayerState.guardMode && commands.fileExists(paths.snapshotPath)
    }

    // MARK: - pieces

    private func ensureHook() throws {
        let current: String
        if commands.fileExists(paths.pfConfPath) {
            current = try commands.readTextFile(paths.pfConfPath)
        } else {
            current = ""
        }
        let result: PFConfHookResult
        do {
            result = try PFConfHook.ensure(current)
        } catch {
            throw AILayerError.hookRejected
        }
        if result.inserted {
            try commands.writeTextFile(paths.pfConfPath, result.text)
        }
    }

    private func loadAnchor(utun: String?) throws {
        let rules: String
        do {
            rules = try PFAnchorRenderer.render(intent: .armed, utun: utun, list: list)
        } catch {
            throw AILayerError.invalidInterface
        }
        _ = try runChecked(
            program: SystemPrograms.pfctl,
            arguments: ["-a", PFAnchorRenderer.anchorName, "-f", "-"],
            stdin: rules
        )
    }

    private func flushAnchor() throws {
        guard try anchorIsLoaded() else { return }
        _ = try runChecked(
            program: SystemPrograms.pfctl,
            arguments: ["-a", PFAnchorRenderer.anchorName, "-F", "all"],
            stdin: nil
        )
    }

    private func anchorIsLoaded() throws -> Bool {
        // `pfctl -s Anchors` still lists segue.ailock after `-F all` because
        // the pf.conf hook names it. An empty anchor is not a hold.
        let output = try runChecked(
            program: SystemPrograms.pfctl,
            arguments: ["-a", PFAnchorRenderer.anchorName, "-sr"],
            stdin: nil
        )
        return SystemText.anchorHasRules(output.stdout)
    }

    private func installGuard() throws {
        let rendered = try ResolverFiles.render(suffixes: list.suffixes, port: paths.guardPort)
        for name in rendered.keys.sorted() {
            guard let body = rendered[name] else { continue }
            let path = resolverPath(name)
            if commands.fileExists(path) {
                let existing = try commands.readTextFile(path)
                if existing == body { continue }
            }
            try commands.writeTextFile(path, body)
        }
        try commands.startGuardListener(
            address: paths.guardAddress,
            port: paths.guardPort,
            responder: GuardResponder(suffixes: list.suffixes)
        )
    }

    private func removeGuard() throws {
        for suffix in list.suffixes.sorted() {
            let path = resolverPath(suffix)
            if commands.fileExists(path) {
                try commands.removeFile(path)
            }
        }
        if commands.guardIsListening() {
            try commands.stopGuardListener()
        }
    }

    private func ensureSnapshot(current: [DNSServiceRecord], kernelAddress: String) throws {
        if commands.fileExists(paths.snapshotPath) { return }
        let alreadyOverride = !current.isEmpty && current.allSatisfy { $0.servers == [kernelAddress] }
        if alreadyOverride { throw AILayerError.snapshotRefused }
        let data = try JSONEncoder().encode(DNSSnapshot(services: current))
        guard let text = String(data: data, encoding: .utf8) else {
            throw AILayerError.io("snapshot")
        }
        try commands.writeTextFile(paths.snapshotPath, text)
    }

    private func restoreSnapshot() throws {
        guard commands.fileExists(paths.snapshotPath) else { return }
        let saved = try loadSnapshot()
        let live = try captureServices()
        let plan = saved.restorePlan(current: live)
        dnsReadbackOK = false
        for item in plan.restores {
            let name = live.first { $0.serviceID == item.record.serviceID }?.name ?? item.record.name
            try assign(name: name, current: item.currentServers, servers: item.record.servers)
        }
        dnsReadbackOK = plan.missingServices.isEmpty
    }

    private func loadSnapshot() throws -> DNSSnapshot {
        let text = try commands.readTextFile(paths.snapshotPath)
        guard let data = text.data(using: .utf8) else { throw AILayerError.snapshotUnreadable }
        guard let snapshot = try? JSONDecoder().decode(DNSSnapshot.self, from: data) else {
            throw AILayerError.snapshotUnreadable
        }
        return snapshot
    }

    private func removeSnapshotBestEffort() {
        guard commands.fileExists(paths.snapshotPath) else { return }
        try? commands.removeFile(paths.snapshotPath)
    }

    private func captureServices() throws -> [DNSServiceRecord] {
        let output = try runChecked(
            program: SystemPrograms.networksetup,
            arguments: ["-listnetworkserviceorder"],
            stdin: nil
        )
        let listed = SystemText.serviceOrder(output.stdout)
        var filled: [DNSServiceRecord] = []
        for service in listed {
            let servers = try readDNS(name: service.name)
            filled.append(DNSServiceRecord(
                serviceID: service.serviceID,
                name: service.name,
                servers: servers
            ))
        }
        return filled
    }

    private func assign(name: String, current: [String], servers: [String]) throws {
        if current == servers { return }
        try writeDNS(name: name, servers: servers)
        let readback = try readDNS(name: name)
        guard readback == servers else { throw AILayerError.dnsReadbackMismatch(service: name) }
    }

    private func writeDNS(name: String, servers: [String]) throws {
        guard servers.allSatisfy(SystemText.isDNSToken) else { throw AILayerError.io("dns server") }
        var arguments = ["-setdnsservers", name]
        if servers.isEmpty {
            arguments.append("Empty")
        } else {
            arguments.append(contentsOf: servers)
        }
        _ = try runChecked(program: SystemPrograms.networksetup, arguments: arguments, stdin: nil)
    }

    private func readDNS(name: String) throws -> [String] {
        let output = try runChecked(
            program: SystemPrograms.networksetup,
            arguments: ["-getdnsservers", name],
            stdin: nil
        )
        return SystemText.dnsServers(output.stdout)
    }

    private func inspect() throws -> AILayerObservation {
        let anchor = try anchorIsLoaded()
        let files = resolverFilesPresent()
        let listening = commands.guardIsListening()
        let services = try captureServices()
        return AILayerObservation(
            anchorLoaded: anchor,
            resolverFilesPresent: files,
            guardListening: listening,
            dnsMode: dnsMode(filesPresent: files, services: services),
            dnsReadback: dnsReadbackOK
        )
    }

    private func dnsMode(filesPresent: Bool, services: [DNSServiceRecord]) -> String {
        if filesPresent { return AILayerState.guardMode }
        if let address = activeKernelDNS(),
            !services.isEmpty,
            services.allSatisfy({ $0.servers == [address] })
        {
            return AILayerState.tunnel
        }
        return AILayerState.system
    }

    private func activeKernelDNS() -> String? {
        if let kernelDNSAddress { return kernelDNSAddress }
        return Self.normalizeAddress(kernel.snapshot().dnsAddress)
    }

    private func resolverFilesPresent() -> Bool {
        guard !list.suffixes.isEmpty else { return false }
        return list.suffixes.allSatisfy { commands.fileExists(resolverPath($0)) }
    }

    private func resolverPath(_ suffix: String) -> String {
        paths.resolverDirectory + "/" + suffix
    }

    private func runChecked(program: String, arguments: [String], stdin: String?) throws
        -> SystemCommandOutput
    {
        let output = try commands.run(program: program, arguments: arguments, standardInput: stdin)
        guard output.status == 0 else {
            let message = output.stderr.isEmpty ? output.stdout : output.stderr
            throw AILayerError.command(program: program, status: output.status, message: message)
        }
        return output
    }

    private func sync<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// `utun` plus digits, nothing else. Mirrors the renderer's check so a
    /// bad name is treated as "no tunnel" instead of being interpolated.
    static func utunName(_ name: String?) -> String? {
        guard let name, name.hasPrefix("utun"), name.count <= 15 else { return nil }
        let digits = name.dropFirst("utun".count)
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return name
    }

    /// An IPv4 or IPv6 address, or `host:53`. Anything else is unpublished.
    static func normalizeAddress(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        guard !text.contains(where: \.isWhitespace), !text.contains("/") else { return nil }
        let colons = text.filter { $0 == ":" }.count
        if colons == 1 {
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let host = String(text[..<colon])
            let port = String(text[text.index(after: colon)...])
            guard port == "53", !host.isEmpty else { return nil }
            text = host
        }
        return text
    }

    private static func loadList(_ path: String) -> AILockList {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return AILockList()
        }
        do {
            return try AILockList.parse(text)
        } catch {
            FileHandle.standardError.write(Data(
                "segue-core-helper: ai-lock list ignored (\(path))\n".utf8
            ))
            return AILockList()
        }
    }
}
