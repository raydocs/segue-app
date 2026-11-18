import Foundation

public enum ResolverFileError: Error, Equatable {
    /// Not a name this lock can own a `/etc/resolver` file for (the suffix
    /// becomes a filename, so anything but a plain DNS name is refused).
    case invalidSuffix(String)
    /// No DNS listener lives on port 0.
    case invalidPort(UInt16)
}

/// Renders the `/etc/resolver/<suffix>` files that hold AI names to the
/// helper's loopback listener while intent is armed and the tunnel is down
/// (design `docs/design/macos.md` §2). Each file points exactly one suffix at
/// `127.0.0.1:<port>`; the listener answers armed names with empty NOERROR
/// and never recurses. The files outlive the listener on purpose: a closed
/// port fails those names instead of leaking them.
public enum ResolverFiles {
    public static let resolverDirectory = "/etc/resolver"
    public static let nameserver = "127.0.0.1"

    /// First line of every file this lock writes. The release daemon removes
    /// only `/etc/resolver` files that carry it, so files owned by other
    /// software survive a Restore network.
    public static let marker = "# managed by segue.ailock"

    /// One file per suffix, keyed by the filename under `/etc/resolver`
    /// (the normalized suffix, which is already a safe filename).
    public static func render(suffixes: [String], port: UInt16) throws -> [String: String] {
        guard port != 0 else { throw ResolverFileError.invalidPort(port) }
        var files: [String: String] = [:]
        for raw in suffixes {
            guard let suffix = AILockSuffix.normalize(raw) else {
                throw ResolverFileError.invalidSuffix(raw)
            }
            files[suffix] = marker + "\nnameserver \(nameserver)\nport \(port)\n"
        }
        return files
    }

    /// true when this lock (or the helper) wrote the file. The marker must be
    /// the first line; a file that only mentions the marker elsewhere is not
    /// ours.
    public static func carriesMarker(_ text: String) -> Bool {
        text.hasPrefix(marker + "\n")
    }
}

/// One network service's resolver state as a capture saw it. `serviceID` is
/// the stable System Configuration identifier (survives renames); `name` is
/// the display name at capture time, kept for diagnostics only. `servers` is
/// the original explicit resolver list in order — possibly empty, which means
/// "no explicit servers" and is a meaningful restore target.
public struct DNSServiceRecord: Codable, Equatable, Sendable {
    public let serviceID: String
    public let name: String
    public let servers: [String]

    public init(serviceID: String, name: String, servers: [String]) {
        self.serviceID = serviceID
        self.name = name
        self.servers = servers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// The saved pre-arm DNS state of the machine: which service pointed where.
/// Pure data; the helper reads and writes System Configuration and keeps the
/// snapshot on disk so a crash between arm and restore cannot lose it.
public struct DNSSnapshot: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public let schemaVersion: Int
    public let services: [DNSServiceRecord]

    public init(services: [DNSServiceRecord], schemaVersion: Int = DNSSnapshot.currentSchema) {
        var byID: [String: DNSServiceRecord] = [:]
        var order: [String] = []
        for record in services {
            if byID[record.serviceID] == nil { order.append(record.serviceID) }
            byID[record.serviceID] = record
        }
        self.schemaVersion = schemaVersion
        self.services = order.map { byID[$0]! }
    }

    /// Diffs this snapshot against a fresh capture of the same machine and
    /// says what restore would do. Nothing here touches System Configuration.
    public func restorePlan(current: [DNSServiceRecord]) -> DNSRestorePlan {
        let currentByID = Dictionary(current.map { ($0.serviceID, $0) }, uniquingKeysWith: { _, last in
            last
        })
        var restores: [DNSRestorePlan.Restore] = []
        var alreadyCurrent: [DNSServiceRecord] = []
        var missing: [DNSServiceRecord] = []

        for saved in services {
            guard let now = currentByID[saved.serviceID] else {
                missing.append(saved)
                continue
            }
            if now.servers == saved.servers {
                alreadyCurrent.append(saved)
            } else {
                restores.append(
                    DNSRestorePlan.Restore(record: saved, currentServers: now.servers))
            }
        }

        let savedIDs = Set(services.map(\.serviceID))
        let newServices = current.filter { !savedIDs.contains($0.serviceID) }
        return DNSRestorePlan(
            restores: restores,
            alreadyCurrent: alreadyCurrent,
            missingServices: missing,
            newServices: newServices
        )
    }
}

/// What restoring a snapshot would change, as data: services to rewrite,
/// services already back to their captured servers, captured services that no
/// longer exist (nothing to restore; the user must hear about them), and
/// services that appeared after the capture (left alone — Segue never
/// pointed them anywhere).
public struct DNSRestorePlan: Equatable, Sendable {
    public struct Restore: Equatable, Sendable {
        /// The captured record; its `servers` go back.
        public let record: DNSServiceRecord
        /// What the service points at now.
        public let currentServers: [String]
    }

    public let restores: [Restore]
    public let alreadyCurrent: [DNSServiceRecord]
    public let missingServices: [DNSServiceRecord]
    public let newServices: [DNSServiceRecord]

    /// true when there is nothing to write and nothing to report.
    public var isEmpty: Bool {
        restores.isEmpty && missingServices.isEmpty
    }
}
