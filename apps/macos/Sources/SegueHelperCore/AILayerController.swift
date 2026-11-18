import Darwin
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
    /// Where armed-suffix resolver files point: `kernel`, `guard`, or
    /// `system` (no files). `system` is never reported while intent is armed;
    /// the session turns that into `guard`.
    var dnsMode: String
    /// `tunnel` (files name the live kernel DNS port), `guard`, `degraded`
    /// (a write failed or the files are not a uniform hold), or `system`
    /// (disarmed, no files).
    var aiLayer: String
    /// True when every armed suffix file was read back and matches one hold.
    var dnsReadback: Bool

    var namesHeld: Bool {
        aiLayer == AILayerState.tunnel || aiLayer == AILayerState.guardMode
    }

    static let unknown = AILayerObservation(
        anchorLoaded: false,
        resolverFilesPresent: false,
        guardListening: false,
        dnsMode: AILayerState.system,
        aiLayer: AILayerState.system,
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
        case .io(let message):
            // Resolver writes put `errno N:` in the message so status_read
            // can name the failure. Other io errors stay the short code.
            if message.hasPrefix("errno ") { return "io_failed \(message)" }
            return "io_failed"
        }
    }

    static func code(of error: Error) -> String {
        if let error = error as? AILayerError { return error.code }
        return "command_failed"
    }
}

/// Installs and removes the narrow AI layer: PF anchor `segue.ailock`,
/// `/etc/resolver` files, and the helper's loopback listener.
///
/// Armed names are never steered by per-service DNS. `networksetup` cannot
/// carry a port, and the kernel listens on `127.0.0.1:<port>` (15353 in
/// production), so a service pointed at `127.0.0.1` would miss it and a
/// failed read-back used to delete the resolver files. While intent is
/// armed every suffix file exists. Tunnel up replaces it, atomically, with
/// `nameserver 127.0.0.1` and the kernel's port. Tunnel down, or an unknown
/// kernel address, replaces it with the helper's guard port. A suffix is
/// never unlinked to change its port. A write failure is `degraded`, not
/// `system`.
///
/// A leftover per-service snapshot from an older helper is restored only
/// after the resolver files are in place. The anchor is flushed only after
/// those files are gone. Startup (`reconcileOnLaunch`) re-arms the narrow
/// layer and never releases it.
public final class AILayerController {
    private let commands: SystemCommands
    private let kernel: KernelSupervising
    /// Replaced on every install from `listPath` when that path is set.
    /// A failed reread keeps the previous list: a parse error must not
    /// become an empty anchor.
    private var list: AILockList
    private let paths: AILayerPaths
    /// Nil in unit tests, which inject `list` directly. Production is the
    /// `--ai-lock` file, reread because the matrix writes it after the
    /// helper has already started.
    private let listPath: String?
    private let pfctlPath: String
    private let lock = NSLock()
    /// Set when a resolver-file write threw. Cleared by a later successful
    /// write or a completed disarm. `observe` will not report `system`
    /// while this is set.
    private var resolverWriteFailed = false
    /// Last list-file failure. Nil when the file parsed, including a
    /// legitimately empty list. Reported as `ai_list_error` while armed.
    private var aiListError: String?
    /// Avoid logging the same refusal on every kernel poll.
    private var loggedListError: String?
    /// Last body passed to `pfctl -f`. The tunnel poll calls `kernelChanged`
    /// every 250ms for 20s after the kernel exits; reloading an identical
    /// anchor zeroes rule counters, so a drop in that window never shows a
    /// counter that moved. `pfctl -sr` does not echo this text back, so the
    /// rendered body is the key. `flushAnchor` clears it. Nothing else
    /// writes this anchor.
    private var loadedAnchorRules: String?

    init(
        commands: SystemCommands,
        kernel: KernelSupervising,
        list: AILockList,
        paths: AILayerPaths,
        listPath: String? = nil,
        pfctlPath: String = SystemPrograms.pfctl
    ) {
        self.commands = commands
        self.kernel = kernel
        self.list = list
        self.paths = paths
        self.listPath = listPath
        self.pfctlPath = pfctlPath
        self.loadedAnchorRules = nil
    }

    /// The list-file failure from the last install, if it did not parse.
    /// Empty when the file was read, or when no path is configured.
    func listError() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return aiListError
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
            list: AILockList(),
            paths: AILayerPaths(
                pfConfPath: paths.pfConfPath,
                resolverDirectory: paths.resolverDirectory,
                snapshotPath: snapshot,
                guardAddress: ResolverFiles.nameserver,
                guardPort: paths.guardPort
            ),
            listPath: paths.aiLockPath,
            pfctlPath: paths.pfctlPath
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
    /// files on the guard port. The session's follow-up converge moves them
    /// to the kernel port once the control API reports a carrier. Disarmed
    /// intent is not this method's job: the session does not call it, so a
    /// clear intent installs nothing and releases nothing.
    func reconcileOnLaunch() throws {
        try sync { try install(allowTunnelDNS: false) }
    }

    /// Kernel liveness changed. Tunnel up (a published loopback DNS port)
    /// points the resolver files at that port. Anything else points them at
    /// the guard. Neither path deletes a file to get there.
    func kernelChanged() throws {
        try sync { try install(allowTunnelDNS: true) }
    }

    func observe() throws -> AILayerObservation {
        try sync { try inspect() }
    }

    // MARK: - converge

    /// Caller holds `lock`.
    ///
    /// The resolver files are installed even when the anchor cannot be
    /// loaded. A pfctl failure used to skip the listener, so armed names
    /// fell through to the system resolver. The anchor error is still
    /// reported; the names stay held.
    private func install(allowTunnelDNS: Bool) throws {
        try refreshList()
        let snap = kernel.snapshot()
        let utun = Self.utunName(snap.tunInterface)
        var anchorError: Error?
        do {
            try ensureHook()
            try loadAnchor(utun: utun)
        } catch {
            anchorError = error
        }
        let kernelPort = allowTunnelDNS ? Self.kernelDNSPort(snap.dnsAddress) : nil
        let port = kernelPort ?? paths.guardPort
        // The guard listener stays up for the whole arm, so moving names
        // back onto its port is only a file replace. Start it first when
        // that is the port we are about to publish: a closed port fails
        // closed, but an already-bound one answers empty NOERROR the moment
        // the file changes. A listener failure still writes the files, then
        // surfaces, so the session retries.
        var listenerError: Error?
        do {
            try ensureGuardListener()
        } catch {
            listenerError = error
        }
        try pointResolvers(port: port)
        // An older helper rewrote per-service DNS and left a snapshot.
        // Armed names are already on the resolver files, so putting the
        // saved servers back cannot open them. Tunnel-up does not create
        // a new snapshot.
        try restoreLegacySnapshot()
        if let listenerError { throw listenerError }
        if let anchorError { throw anchorError }
    }

    /// Caller holds `lock`.
    private func release() throws {
        do {
            // Legacy snapshot first, while the files still hold names.
            try restoreLegacySnapshot()
            try removeResolverFiles()
            if commands.guardIsListening() {
                try commands.stopGuardListener()
            }
            try flushAnchor()
            resolverWriteFailed = false
            removeSnapshotBestEffort()
        } catch {
            try? install(allowTunnelDNS: true)
            throw error
        }
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
        if loadedAnchorRules == rules {
            return
        }
        _ = try runChecked(
            program: pfctlPath,
            arguments: ["-a", PFAnchorRenderer.anchorName, "-f", "-"],
            stdin: rules
        )
        loadedAnchorRules = rules
    }

    private func flushAnchor() throws {
        loadedAnchorRules = nil
        guard try anchorIsLoaded() else { return }
        _ = try runChecked(
            program: pfctlPath,
            arguments: ["-a", PFAnchorRenderer.anchorName, "-F", "all"],
            stdin: nil
        )
    }

    private func anchorIsLoaded() throws -> Bool {
        // `pfctl -s Anchors` still lists segue.ailock after `-F all` because
        // the pf.conf hook names it. An empty anchor is not a hold.
        let output = try runChecked(
            program: pfctlPath,
            arguments: ["-a", PFAnchorRenderer.anchorName, "-sr"],
            stdin: nil
        )
        return SystemText.anchorHasRules(output.stdout)
    }

    /// Replace each suffix file in place. `writeTextFile` is an atomic
    /// rename, so a reader never sees a missing file and never sees a torn
    /// body. A failed write leaves the previous body (or no file, if this
    /// suffix had none yet) and is remembered as degraded.
    private func pointResolvers(port: UInt16) throws {
        let rendered: [String: String]
        do {
            rendered = try ResolverFiles.render(suffixes: list.suffixes, port: port)
        } catch {
            resolverWriteFailed = true
            throw AILayerError.io("resolver")
        }
        do {
            for name in rendered.keys.sorted() {
                guard let body = rendered[name] else { continue }
                let path = resolverPath(name)
                if commands.fileExists(path) {
                    let existing = try commands.readTextFile(path)
                    if existing == body { continue }
                }
                try writeResolverFile(path, body)
            }
            for name in rendered.keys.sorted() {
                guard let body = rendered[name] else { continue }
                let got = try commands.readTextFile(resolverPath(name))
                guard got == body else {
                    throw AILayerError.dnsReadbackMismatch(service: name)
                }
            }
        } catch {
            resolverWriteFailed = true
            throw error
        }
        resolverWriteFailed = false
    }

    private func ensureGuardListener() throws {
        try commands.startGuardListener(
            address: paths.guardAddress,
            port: paths.guardPort,
            responder: GuardResponder(suffixes: list.suffixes)
        )
    }

    private func removeResolverFiles() throws {
        for suffix in list.suffixes.sorted() {
            let path = resolverPath(suffix)
            if commands.fileExists(path) {
                try commands.removeFile(path)
            }
        }
    }

    /// Restore a snapshot left by an older helper, then delete it so a
    /// later converge does not keep rewriting services. No snapshot is the
    /// common case: tunnel-up does not create one.
    private func restoreLegacySnapshot() throws {
        guard commands.fileExists(paths.snapshotPath) else { return }
        try restoreSnapshot()
        removeSnapshotBestEffort()
    }

    private func restoreSnapshot() throws {
        guard commands.fileExists(paths.snapshotPath) else { return }
        let saved = try loadSnapshot()
        let live = try captureServices()
        let plan = saved.restorePlan(current: live)
        for item in plan.restores {
            let name = live.first { $0.serviceID == item.record.serviceID }?.name ?? item.record.name
            try assign(name: name, current: item.currentServers, servers: item.record.servers)
        }
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
        let hold = classifyHold()
        let listening = commands.guardIsListening()
        let clean = hold.aiLayer == AILayerState.tunnel || hold.aiLayer == AILayerState.guardMode
        return AILayerObservation(
            anchorLoaded: anchor,
            resolverFilesPresent: hold.filesPresent,
            guardListening: listening,
            dnsMode: hold.dnsMode,
            aiLayer: hold.aiLayer,
            dnsReadback: clean && hold.filesPresent
        )
    }

    private struct ResolverHold {
        var filesPresent: Bool
        var dnsMode: String
        var aiLayer: String
    }

    /// What the suffix files actually say. A uniform match of the live
    /// kernel port is `tunnel` / `kernel`. A uniform match of the guard
    /// port is `guard`. Anything else with a file on disk, or a remembered
    /// write failure, is `degraded` and is not `system`.
    private func classifyHold() -> ResolverHold {
        let suffixes = list.suffixes
        if suffixes.isEmpty {
            return degradedIfWriteFailed(ResolverHold(
                filesPresent: false,
                dnsMode: AILayerState.system,
                aiLayer: AILayerState.system
            ))
        }
        let kernelPort = Self.kernelDNSPort(kernel.snapshot().dnsAddress)
        var ports: [UInt16] = []
        var missing = false
        for suffix in suffixes {
            let path = resolverPath(suffix)
            guard commands.fileExists(path),
                  let text = try? commands.readTextFile(path),
                  let port = Self.portOfResolverFile(text)
            else {
                missing = true
                continue
            }
            ports.append(port)
        }
        let filesPresent = !missing && ports.count == suffixes.count
        if filesPresent, let kernelPort, ports.allSatisfy({ $0 == kernelPort }) {
            return ResolverHold(
                filesPresent: true,
                dnsMode: AILayerState.kernel,
                aiLayer: AILayerState.tunnel
            )
        }
        if filesPresent, ports.allSatisfy({ $0 == paths.guardPort }) {
            return ResolverHold(
                filesPresent: true,
                dnsMode: AILayerState.guardMode,
                aiLayer: AILayerState.guardMode
            )
        }
        if ports.isEmpty {
            return degradedIfWriteFailed(ResolverHold(
                filesPresent: false,
                dnsMode: AILayerState.system,
                aiLayer: AILayerState.system
            ))
        }
        // Partial, mixed, or a port the live kernel is not publishing.
        // `kernel` only when every file names one non-guard port (they
        // still aim at a kernel listener). Otherwise `guard`: not system.
        let uniform = ports.allSatisfy { $0 == ports[0] }
        let dnsMode = (filesPresent && uniform && ports[0] != paths.guardPort)
            ? AILayerState.kernel
            : AILayerState.guardMode
        return ResolverHold(filesPresent: filesPresent, dnsMode: dnsMode, aiLayer: AILayerState.degraded)
    }

    private func degradedIfWriteFailed(_ hold: ResolverHold) -> ResolverHold {
        guard resolverWriteFailed else { return hold }
        var degraded = hold
        degraded.aiLayer = AILayerState.degraded
        if degraded.dnsMode == AILayerState.system {
            degraded.dnsMode = AILayerState.guardMode
        }
        return degraded
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

    /// `127.0.0.1:<port>` with a non-zero port. A bare address, a non-loopback
    /// host, or port 0 is unpublished: the layer keeps the guard.
    static func kernelDNSPort(_ raw: String?) -> UInt16? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        guard !text.contains(where: \.isWhitespace), !text.contains("/") else { return nil }
        guard text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") else {
            return nil
        }
        let host = String(text[..<colon])
        let portText = String(text[text.index(after: colon)...])
        guard host == ResolverFiles.nameserver, let port = UInt16(portText), port != 0 else {
            return nil
        }
        return port
    }

    /// Port named by a file this lock wrote. Nil when the marker, the
    /// loopback nameserver, or the port line is missing.
    static func portOfResolverFile(_ text: String) -> UInt16? {
        guard ResolverFiles.carriesMarker(text) else { return nil }
        var nameserverOK = false
        var port: UInt16?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "nameserver \(ResolverFiles.nameserver)" {
                nameserverOK = true
            } else if line.hasPrefix("port ") {
                port = UInt16(line.dropFirst("port ".count))
            }
        }
        guard nameserverOK, let port, port != 0 else { return nil }
        return port
    }

    /// Caller holds `lock`. A missing or unreadable file, or a parse error,
    /// is remembered and thrown. The previous list stays in place so the
    /// failure cannot install an empty anchor.
    private func refreshList() throws {
        guard let listPath else { return }
        let loaded = Self.readList(path: listPath)
        if let error = loaded.error {
            aiListError = error
            if loggedListError != error {
                loggedListError = error
                FileHandle.standardError.write(Data(
                    "segue-core-helper: ai-lock list refused (\(error))\n".utf8
                ))
            }
            throw AILayerError.io("ai-lock")
        }
        list = loaded.list
        aiListError = nil
        loggedListError = nil
    }

    private func writeResolverFile(_ path: String, _ body: String) throws {
        do {
            try commands.writeTextFile(path, body)
        } catch let error as SystemCommandError {
            if case .io(let message) = error {
                throw AILayerError.io(message)
            }
            throw AILayerError.io("resolver")
        }
    }

    private struct ListRead {
        var list: AILockList
        var error: String?
    }

    /// Reads `path` with the errno intact. A parse error is `error` and an
    /// empty list that the caller must not install. A file that parses,
    /// even with no entries, has `error == nil`.
    private static func readList(path: String) -> ListRead {
        let fd = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        if fd < 0 {
            let err = errno
            return ListRead(list: AILockList(), error: Self.fileError(path, err))
        }
        defer { _ = Darwin.close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                let err = errno
                return ListRead(list: AILockList(), error: Self.fileError(path, err))
            }
            if n == 0 { break }
            data.append(contentsOf: buffer.prefix(n))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return ListRead(list: AILockList(), error: "\(path): not utf-8")
        }
        do {
            return ListRead(list: try AILockList.parse(text), error: nil)
        } catch let error as AILockList.Error {
            return ListRead(list: AILockList(), error: "\(path): \(describe(error))")
        } catch {
            return ListRead(list: AILockList(), error: "\(path): \(error)")
        }
    }

    private static func fileError(_ path: String, _ err: Int32) -> String {
        "\(path): \(String(cString: strerror(err))) (errno \(err))"
    }

    private static func describe(_ error: AILockList.Error) -> String {
        switch error {
        case .unknownDirective(let lineNumber, let directive):
            return "unknown directive \(directive) at line \(lineText(lineNumber))"
        case .missingValue(let lineNumber, let directive):
            return "missing value for \(directive) at line \(lineText(lineNumber))"
        case .extraTokens(let lineNumber):
            return "extra tokens at line \(lineText(lineNumber))"
        case .invalidSuffix(let lineNumber, let value):
            return "invalid suffix \(value) at line \(lineText(lineNumber))"
        case .invalidCIDR(let lineNumber, let value, let problem):
            return "invalid cidr \(value) (\(cidrProblem(problem))) at line \(lineText(lineNumber))"
        }
    }

    private static func lineText(_ lineNumber: Int?) -> String {
        if let lineNumber { return String(lineNumber) }
        return "-"
    }

    private static func cidrProblem(_ problem: CIDR.ParseProblem) -> String {
        switch problem {
        case .notAnAddress: return "not an address"
        case .missingPrefixLength: return "missing prefix length"
        case .extraSlashes: return "extra slashes"
        case .prefixNotNumeric: return "prefix not numeric"
        case .prefixOutOfRange(let max): return "prefix out of range (max \(max))"
        case .hostBitsSet: return "host bits set"
        }
    }
}
