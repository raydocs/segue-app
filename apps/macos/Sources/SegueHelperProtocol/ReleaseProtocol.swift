import Foundation

/// Release-daemon IPC, the second wire contract.
///
/// `segue-release` is a separate root LaunchDaemon on its own socket
/// (`docs/design/macos.md` §3) so "Restore network" still works when the
/// helper cannot answer. It never talks to the helper; it clears what the
/// helper wrote — the PF anchor, marked `/etc/resolver` files, the DNS
/// snapshot, and the persisted intent. One verb, `restore`, idempotent. The
/// reply is a read-back of the machine, not a receipt of what the daemon did.
/// The envelope shape mirrors `HelperEnvelope`; the contract versions
/// independently and starts at 1.

public enum ReleaseProtocolVersion {
    public static let current = 1
}

public enum ReleaseProtocolError: Error, Equatable {
    case unsupportedVersion(Int)
    case malformed
}

/// Read-back outcome. `restored` only when every step proved itself and the
/// machine reads back clean; any failure or leftover makes it `partial`.
public enum ReleaseOutcome {
    public static let restored = "restored"
    public static let partial = "partial"
}

public enum ReleaseMessageKind: String, Codable, Equatable, Sendable {
    case restore
    case report
    case error
}

/// Same code strings as the helper envelope; the two daemons refuse peers
/// for the same reasons.
public enum ReleaseErrorCode {
    public static let unsupportedVersion = HelperErrorCode.unsupportedVersion
    public static let malformed = HelperErrorCode.malformed
    public static let unauthorized = HelperErrorCode.unauthorized
    public static let internalError = HelperErrorCode.internalError
}

public struct ReleaseErrorBody: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// What the machine looked like after a `restore`. `resolverFilesRemaining`
/// names marked files that survived; `failures` names steps that did not
/// prove themselves. `dnsMode` reuses the helper's `AILayerState` strings:
/// marked files left means `guard`, otherwise `system`.
public struct ReleaseReport: Codable, Equatable, Sendable {
    public var anchorLoaded: Bool
    public var resolverFilesRemoved: [String]
    public var resolverFilesRemaining: [String]
    public var dnsRestoredServices: [String]
    public var dnsMissingServices: [String]
    public var dnsMode: String
    public var intentCleared: Bool
    public var snapshotCleared: Bool
    public var failures: [String]
    public var outcome: String

    enum CodingKeys: String, CodingKey {
        case anchorLoaded = "anchor_loaded"
        case resolverFilesRemoved = "resolver_files_removed"
        case resolverFilesRemaining = "resolver_files_remaining"
        case dnsRestoredServices = "dns_restored_services"
        case dnsMissingServices = "dns_missing_services"
        case dnsMode = "dns_mode"
        case intentCleared = "intent_cleared"
        case snapshotCleared = "snapshot_cleared"
        case failures
        case outcome
    }

    public init(
        anchorLoaded: Bool,
        resolverFilesRemoved: [String],
        resolverFilesRemaining: [String],
        dnsRestoredServices: [String],
        dnsMissingServices: [String],
        dnsMode: String,
        intentCleared: Bool,
        snapshotCleared: Bool,
        failures: [String],
        outcome: String
    ) {
        self.anchorLoaded = anchorLoaded
        self.resolverFilesRemoved = resolverFilesRemoved
        self.resolverFilesRemaining = resolverFilesRemaining
        self.dnsRestoredServices = dnsRestoredServices
        self.dnsMissingServices = dnsMissingServices
        self.dnsMode = dnsMode
        self.intentCleared = intentCleared
        self.snapshotCleared = snapshotCleared
        self.failures = failures
        self.outcome = outcome
    }
}

/// One JSON envelope, one line on the release socket.
public struct ReleaseEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let kind: ReleaseMessageKind
    public let report: ReleaseReport?
    public let error: ReleaseErrorBody?

    public static func restore() -> ReleaseEnvelope {
        ReleaseEnvelope(
            version: ReleaseProtocolVersion.current,
            kind: .restore,
            report: nil,
            error: nil
        )
    }

    public static func report(_ body: ReleaseReport) -> ReleaseEnvelope {
        ReleaseEnvelope(
            version: ReleaseProtocolVersion.current,
            kind: .report,
            report: body,
            error: nil
        )
    }

    public static func failure(code: String, message: String) -> ReleaseEnvelope {
        ReleaseEnvelope(
            version: ReleaseProtocolVersion.current,
            kind: .error,
            report: nil,
            error: ReleaseErrorBody(code: code, message: message)
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == ReleaseProtocolVersion.current else {
            throw ReleaseProtocolError.unsupportedVersion(version)
        }
        let kind = try container.decode(ReleaseMessageKind.self, forKey: .kind)
        let report = try container.decodeIfPresent(ReleaseReport.self, forKey: .report)
        let error = try container.decodeIfPresent(ReleaseErrorBody.self, forKey: .error)
        let envelope = ReleaseEnvelope(version: version, kind: kind, report: report, error: error)
        guard envelope.shapeIsValid else {
            throw ReleaseProtocolError.malformed
        }
        self = envelope
    }

    public func encode(to encoder: Encoder) throws {
        guard shapeIsValid, version == ReleaseProtocolVersion.current else {
            throw ReleaseProtocolError.malformed
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(report, forKey: .report)
        try container.encodeIfPresent(error, forKey: .error)
    }

    private init(
        version: Int,
        kind: ReleaseMessageKind,
        report: ReleaseReport?,
        error: ReleaseErrorBody?
    ) {
        self.version = version
        self.kind = kind
        self.report = report
        self.error = error
    }

    private var shapeIsValid: Bool {
        switch kind {
        case .restore:
            return report == nil && error == nil
        case .report:
            return report != nil && error == nil
        case .error:
            return error != nil && report == nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case kind
        case report
        case error
    }
}
