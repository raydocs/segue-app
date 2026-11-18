import Foundation
import SegueAILayer
import SegueHelperCore
import SegueHelperProtocol

/// Steps that did not prove themselves. Collected, never overwritten; any
/// entry keeps the outcome `partial`.
enum ReleaseFailure {
    static let anchorRead = "anchor_read_failed"
    static let anchorFlush = "anchor_flush_failed"
    static let resolverRead = "resolver_read_failed"
    static let resolverRemove = "resolver_remove_failed"
    static let snapshotUnreadable = "dns_snapshot_unreadable"
    static let dnsCapture = "dns_capture_failed"
    static let dnsRestore = "dns_restore_failed"
    static let snapshotRemove = "dns_snapshot_remove_failed"
    static let intentWrite = "intent_write_failed"

    static func label(_ name: String, _ detail: String) -> String {
        "\(name):\(detail)"
    }
}

struct ReleaseDNSOutcome {
    var restored: [String] = []
    var missing: [String] = []
}

/// The one verb. Clears what the helper wrote, without asking the helper:
/// the PF anchor, marked `/etc/resolver` files, the DNS snapshot (after
/// restoring it), and the persisted arm intent. Every step is best effort;
/// the reply is a read-back of what is actually still there, so a repeated
/// `restore` finishes the job instead of assuming it. Idempotent by design:
/// on a clean machine it writes nothing.
///
/// The helper's own disarm keeps names held while DNS moves back; this
/// escape hatch does not. The user asked for the network back, so the anchor
/// and the pinning files go first and the saved resolvers follow
/// (`docs/design/macos.md` §3, "Restore network, helper paused").
public final class ReleaseRestorer {
    private let commands: SystemCommands
    private let paths: ReleasePaths
    private let lock = NSLock()

    init(commands: SystemCommands, paths: ReleasePaths) {
        self.commands = commands
        self.paths = paths
    }

    /// Production wiring. Talks to pfctl, networksetup, and the real
    /// filesystem. Tests must not call this.
    public static func live(paths: ReleasePaths) -> ReleaseRestorer {
        ReleaseRestorer(commands: LiveSystemCommands(), paths: paths)
    }

    public func restore() -> ReleaseReport {
        lock.lock()
        defer { lock.unlock() }
        var failures: [String] = []

        flushAnchorIfNeeded(&failures)
        let removed = removeMarkedResolverFiles(&failures)
        let dns = restoreSnapshot(&failures)
        let intentCleared = clearIntent(&failures)

        let anchorLoaded = readBackAnchor(&failures)
        let remaining = markedResolverFiles(&failures)
        let snapshotCleared = !commands.fileExists(paths.snapshotPath)
        let dnsMode = remaining.isEmpty ? AILayerState.system : AILayerState.guardMode
        let restored = failures.isEmpty
            && !anchorLoaded
            && remaining.isEmpty
            && intentCleared
            && dnsMode == AILayerState.system

        return ReleaseReport(
            anchorLoaded: anchorLoaded,
            resolverFilesRemoved: removed.sorted(),
            resolverFilesRemaining: remaining.sorted(),
            dnsRestoredServices: dns.restored.sorted(),
            dnsMissingServices: dns.missing.sorted(),
            dnsMode: dnsMode,
            intentCleared: intentCleared,
            snapshotCleared: snapshotCleared,
            failures: unique(failures),
            outcome: restored ? ReleaseOutcome.restored : ReleaseOutcome.partial
        )
    }

    // MARK: - anchor

    /// Flush `segue.ailock` if it is loaded. An unreadable anchor still
    /// counts as a failure: "clean" must be proved, not assumed.
    private func flushAnchorIfNeeded(_ failures: inout [String]) {
        guard let loaded = anchorIsLoaded() else {
            failures.append(ReleaseFailure.anchorRead)
            return
        }
        guard loaded else { return }
        do {
            _ = try runChecked(
                program: SystemPrograms.pfctl,
                arguments: ["-a", PFAnchorRenderer.anchorName, "-F", "all"],
                standardInput: nil
            )
        } catch {
            failures.append(ReleaseFailure.anchorFlush)
        }
    }

    private func readBackAnchor(_ failures: inout [String]) -> Bool {
        guard let loaded = anchorIsLoaded() else {
            failures.append(ReleaseFailure.anchorRead)
            return true
        }
        return loaded
    }

    private func anchorIsLoaded() -> Bool? {
        // Flushing rules does not drop the name from `pfctl -s Anchors`:
        // the pf.conf line `anchor "segue.ailock"` keeps it listed. That
        // made every real restore `partial` with an empty failure list.
        // Loaded means the anchor still has rules.
        guard let output = try? runChecked(
            program: SystemPrograms.pfctl,
            arguments: ["-a", PFAnchorRenderer.anchorName, "-sr"],
            standardInput: nil
        ) else {
            return nil
        }
        return SystemText.anchorHasRules(output.stdout)
    }

    // MARK: - resolver files

    /// Remove only files carrying Segue's marker comment. Foreign files in
    /// `/etc/resolver` are somebody else's and stay.
    private func removeMarkedResolverFiles(_ failures: inout [String]) -> [String] {
        var removed: [String] = []
        for name in markedResolverFiles(&failures) {
            do {
                try commands.removeFile(resolverPath(name))
                removed.append(name)
            } catch {
                failures.append(ReleaseFailure.label(ReleaseFailure.resolverRemove, name))
            }
        }
        return removed
    }

    /// Marker-carrying filenames in the resolver directory, sorted.
    private func markedResolverFiles(_ failures: inout [String]) -> [String] {
        let entries: [String]
        do {
            entries = try commands.listDirectory(paths.resolverDirectory)
        } catch {
            failures.append(ReleaseFailure.resolverRead)
            return []
        }
        var marked: [String] = []
        for name in entries.sorted() {
            guard let text = try? commands.readTextFile(resolverPath(name)) else {
                failures.append(ReleaseFailure.label(ReleaseFailure.resolverRead, name))
                continue
            }
            if ResolverFiles.carriesMarker(text) {
                marked.append(name)
            }
        }
        return marked
    }

    private func resolverPath(_ name: String) -> String {
        paths.resolverDirectory + "/" + name
    }

    // MARK: - DNS snapshot

    /// Put the saved resolvers back, then drop the snapshot — but only once
    /// every service it knew about was rewritten, so a failed restore never
    /// destroys the only copy of the user's original DNS.
    private func restoreSnapshot(_ failures: inout [String]) -> ReleaseDNSOutcome {
        guard commands.fileExists(paths.snapshotPath) else {
            return ReleaseDNSOutcome()
        }
        let text: String
        do {
            text = try commands.readTextFile(paths.snapshotPath)
        } catch {
            failures.append(ReleaseFailure.snapshotUnreadable)
            return ReleaseDNSOutcome()
        }
        guard let data = text.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(DNSSnapshot.self, from: data)
        else {
            failures.append(ReleaseFailure.snapshotUnreadable)
            return ReleaseDNSOutcome()
        }
        guard let live = captureServices() else {
            failures.append(ReleaseFailure.dnsCapture)
            return ReleaseDNSOutcome()
        }
        let plan = snapshot.restorePlan(current: live)
        var restored: [String] = []
        var allProved = true
        for item in plan.restores {
            let name = live.first { $0.serviceID == item.record.serviceID }?.name ?? item.record.name
            do {
                try assign(name: name, servers: item.record.servers)
                restored.append(name)
            } catch {
                failures.append(ReleaseFailure.label(ReleaseFailure.dnsRestore, name))
                allProved = false
            }
        }
        guard allProved else { return ReleaseDNSOutcome(restored: restored) }
        do {
            try commands.removeFile(paths.snapshotPath)
        } catch {
            failures.append(ReleaseFailure.snapshotRemove)
        }
        return ReleaseDNSOutcome(restored: restored, missing: plan.missingServices.map(\.name))
    }

    /// `networksetup -listnetworkserviceorder` plus each service's servers.
    private func captureServices() -> [DNSServiceRecord]? {
        guard let output = try? runChecked(
            program: SystemPrograms.networksetup,
            arguments: ["-listnetworkserviceorder"],
            standardInput: nil
        ) else {
            return nil
        }
        var filled: [DNSServiceRecord] = []
        for service in SystemText.serviceOrder(output.stdout) {
            guard let servers = try? readDNS(name: service.name) else {
                return nil
            }
            filled.append(DNSServiceRecord(
                serviceID: service.serviceID,
                name: service.name,
                servers: servers
            ))
        }
        return filled
    }

    /// Write the servers and prove it by reading them back, the same read-back
    /// the helper requires before it calls a DNS change done.
    private func assign(name: String, servers: [String]) throws {
        guard servers.allSatisfy(SystemText.isDNSToken) else {
            throw SystemCommandError.io("dns server")
        }
        var arguments = ["-setdnsservers", name]
        if servers.isEmpty {
            arguments.append("Empty")
        } else {
            arguments.append(contentsOf: servers)
        }
        _ = try runChecked(program: SystemPrograms.networksetup, arguments: arguments, standardInput: nil)
        let readback = try readDNS(name: name)
        guard readback == servers else {
            throw SystemCommandError.io("dns readback \(name)")
        }
    }

    private func readDNS(name: String) throws -> [String] {
        let output = try runChecked(
            program: SystemPrograms.networksetup,
            arguments: ["-getdnsservers", name],
            standardInput: nil
        )
        return SystemText.dnsServers(output.stdout)
    }

    // MARK: - intent

    /// Clear the persisted arm bit so a helper restart does not re-arm. The
    /// reply says what is on disk now, not what the write intended.
    private func clearIntent(_ failures: inout [String]) -> Bool {
        let store = IntentStore(fileURL: URL(fileURLWithPath: paths.intentPath))
        if let stored = try? store.load(), stored.armed {
            do {
                try store.save(.disarmed)
            } catch {
                failures.append(ReleaseFailure.intentWrite)
            }
        }
        guard let stored = try? store.load() else {
            // No file is a clear intent.
            return true
        }
        return !stored.armed
    }

    // MARK: -

    private func runChecked(program: String, arguments: [String], standardInput: String?) throws
        -> SystemCommandOutput
    {
        let output = try commands.run(program: program, arguments: arguments, standardInput: standardInput)
        guard output.status == 0 else {
            throw SystemCommandError.io("\(program) status \(output.status)")
        }
        return output
    }

    private func unique(_ failures: [String]) -> [String] {
        var seen: Set<String> = []
        return failures.filter { seen.insert($0).inserted }
    }
}
