import Foundation

/// Helper IPC, the shared wire contract.
///
/// Versioned JSON envelopes for the unix socket in the macOS design. The
/// contract version starts at 1. One message is one JSON object; the socket
/// puts that object on a single line. Arm and disarm carry an explicit
/// intent. Status is a read-back, including whether the helper sees a utun.
/// Nothing here opens a socket.

public enum HelperProtocolVersion {
    public static let current = 1
}

public enum HelperProtocolError: Error, Equatable {
    case unsupportedVersion(Int)
    case malformed
}

public enum HelperErrorCode {
    public static let unsupportedVersion = "unsupported_version"
    public static let malformed = "malformed"
    public static let unauthorized = "unauthorized"
    public static let internalError = "internal"
}

/// Status strings for the AI layer. `ai_layer` is `tunnel` (resolver
/// files name the live kernel DNS port), `guard`, `degraded` (armed, but
/// the files are missing or a write failed), or `system` (not armed).
/// `dns_mode` is `kernel`, `guard`, or `system`. `system` is never sent
/// for either field while intent is armed. `not_implemented` is the
/// stage-0 sentinel; current replies do not use it.
public enum AILayerState {
    public static let notImplemented = "not_implemented"
    public static let tunnel = "tunnel"
    public static let guardMode = "guard"
    public static let system = "system"
    public static let kernel = "kernel"
    public static let degraded = "degraded"
}

public enum HelperMessageKind: String, Codable, Equatable, Sendable {
    case arm
    case disarm
    case statusRead = "status_read"
    case status
    case error
}

public enum ArmIntentName: String, Codable, Equatable, Sendable {
    case userConnect = "user_connect"
}

public enum DisarmReason: String, Codable, Equatable, Sendable {
    case userDisconnect = "user_disconnect"
    case signOut = "sign_out"
    case quit
}

public struct EgressEndpoint: Codable, Equatable, Sendable {
    public var ip: String
    public var port: UInt16

    public init(ip: String, port: UInt16) {
        self.ip = ip
        self.port = port
    }
}

public struct ArmEvidence: Codable, Equatable, Sendable {
    public var policyVersion: UInt64?
    public var posture: String

    enum CodingKeys: String, CodingKey {
        case policyVersion = "policy_version"
        case posture
    }

    public init(policyVersion: UInt64?, posture: String) {
        self.policyVersion = policyVersion
        self.posture = posture
    }
}

public struct ArmIntent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generation: UInt64
    public let intent: ArmIntentName
    public let anchorRevision: UInt64
    public let manifestDigest: String
    public let egress: [EgressEndpoint]
    public let exitIfaces: [String]
    public let strict: Bool
    public let evidence: ArmEvidence

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generation
        case intent
        case anchorRevision = "anchor_revision"
        case manifestDigest = "manifest_digest"
        case egress
        case exitIfaces = "exit_ifaces"
        case strict
        case evidence
    }

    public init(
        generation: UInt64,
        anchorRevision: UInt64,
        manifestDigest: String,
        egress: [EgressEndpoint],
        exitIfaces: [String],
        strict: Bool,
        evidence: ArmEvidence
    ) {
        self.schemaVersion = HelperProtocolVersion.current
        self.generation = generation
        self.intent = .userConnect
        self.anchorRevision = anchorRevision
        self.manifestDigest = manifestDigest
        self.egress = egress
        self.exitIfaces = exitIfaces
        self.strict = strict
        self.evidence = evidence
    }
}

public struct DisarmIntent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generation: UInt64
    public let intent: DisarmReason

    public init(generation: UInt64, intent: DisarmReason) {
        self.schemaVersion = HelperProtocolVersion.current
        self.generation = generation
        self.intent = intent
    }
}

public struct StatusEvidence: Codable, Equatable, Sendable {
    public var tcpProofMs: UInt64?
    public var dnsReadback: Bool

    enum CodingKeys: String, CodingKey {
        case tcpProofMs = "tcp_proof_ms"
        case dnsReadback = "dns_readback"
    }

    public init(tcpProofMs: UInt64?, dnsReadback: Bool) {
        self.tcpProofMs = tcpProofMs
        self.dnsReadback = dnsReadback
    }
}

public struct HelperProcessReport: Codable, Equatable, Sendable {
    public var state: String

    public init(state: String) {
        self.state = state
    }
}

public struct KernelReport: Codable, Equatable, Sendable {
    public var state: String
    public var pid: Int32?
    public var lastExit: String?

    enum CodingKeys: String, CodingKey {
        case state
        case pid
        case lastExit = "last_exit"
    }

    public init(state: String, pid: Int32?, lastExit: String?) {
        self.state = state
        self.pid = pid
        self.lastExit = lastExit
    }
}

public struct HelperErrorBody: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Helper read-back. `tunInterface` is set only when the helper sees a utun.
/// `aiLayer` is `tunnel`, `guard`, `degraded`, or `system`. `dnsMode` is
/// `kernel`, `guard`, or `system` (where the resolver files point). The
/// anchor, resolver-file, and listener flags are omitted by older peers.
public struct HelperStatus: Codable, Equatable, Sendable {
    public var armed: Bool
    public var generation: UInt64
    public var held: Bool
    public var tunInterface: String?
    public var rulesDigest: String
    public var evidence: StatusEvidence
    public var lastError: String?
    public var aiLayer: String?
    public var helper: HelperProcessReport?
    public var kernel: KernelReport?
    public var anchorLoaded: Bool?
    public var resolverFilesPresent: Bool?
    public var guardListening: Bool?
    public var dnsMode: String?
    /// Set while armed when the AI list file is missing or does not parse.
    /// A failed list is not installed as an empty one.
    public var aiListError: String?

    enum CodingKeys: String, CodingKey {
        case armed
        case generation
        case held
        case tunInterface = "tun_interface"
        case rulesDigest = "rules_digest"
        case evidence
        case lastError = "last_error"
        case aiLayer = "ai_layer"
        case helper
        case kernel
        case anchorLoaded = "anchor_loaded"
        case resolverFilesPresent = "resolver_files"
        case guardListening = "guard_listening"
        case dnsMode = "dns_mode"
        case aiListError = "ai_list_error"
    }

    public init(
        armed: Bool,
        generation: UInt64,
        held: Bool,
        tunInterface: String?,
        rulesDigest: String,
        evidence: StatusEvidence,
        lastError: String?,
        aiLayer: String? = nil,
        helper: HelperProcessReport? = nil,
        kernel: KernelReport? = nil,
        anchorLoaded: Bool? = nil,
        resolverFilesPresent: Bool? = nil,
        guardListening: Bool? = nil,
        dnsMode: String? = nil,
        aiListError: String? = nil
    ) {
        self.armed = armed
        self.generation = generation
        self.held = held
        self.tunInterface = tunInterface
        self.rulesDigest = rulesDigest
        self.evidence = evidence
        self.lastError = lastError
        self.aiLayer = aiLayer
        self.helper = helper
        self.kernel = kernel
        self.anchorLoaded = anchorLoaded
        self.resolverFilesPresent = resolverFilesPresent
        self.guardListening = guardListening
        self.dnsMode = dnsMode
        self.aiListError = aiListError
    }
}

/// One JSON envelope. One request is in flight on the socket; this type does
/// not implement that queue.
public struct HelperEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let kind: HelperMessageKind
    public let arm: ArmIntent?
    public let disarm: DisarmIntent?
    public let status: HelperStatus?
    public let error: HelperErrorBody?

    public static func arm(_ body: ArmIntent) throws -> HelperEnvelope {
        try checkSchema(body.schemaVersion)
        return HelperEnvelope(
            version: HelperProtocolVersion.current,
            kind: .arm,
            arm: body,
            disarm: nil,
            status: nil,
            error: nil
        )
    }

    public static func disarm(_ body: DisarmIntent) throws -> HelperEnvelope {
        try checkSchema(body.schemaVersion)
        return HelperEnvelope(
            version: HelperProtocolVersion.current,
            kind: .disarm,
            arm: nil,
            disarm: body,
            status: nil,
            error: nil
        )
    }

    public static func status(_ body: HelperStatus) -> HelperEnvelope {
        HelperEnvelope(
            version: HelperProtocolVersion.current,
            kind: .status,
            arm: nil,
            disarm: nil,
            status: body,
            error: nil
        )
    }

    public static func statusRead() -> HelperEnvelope {
        HelperEnvelope(
            version: HelperProtocolVersion.current,
            kind: .statusRead,
            arm: nil,
            disarm: nil,
            status: nil,
            error: nil
        )
    }

    public static func failure(code: String, message: String) -> HelperEnvelope {
        HelperEnvelope(
            version: HelperProtocolVersion.current,
            kind: .error,
            arm: nil,
            disarm: nil,
            status: nil,
            error: HelperErrorBody(code: code, message: message)
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == HelperProtocolVersion.current else {
            throw HelperProtocolError.unsupportedVersion(version)
        }
        let kind = try container.decode(HelperMessageKind.self, forKey: .kind)
        let arm = try container.decodeIfPresent(ArmIntent.self, forKey: .arm)
        let disarm = try container.decodeIfPresent(DisarmIntent.self, forKey: .disarm)
        let status = try container.decodeIfPresent(HelperStatus.self, forKey: .status)
        let error = try container.decodeIfPresent(HelperErrorBody.self, forKey: .error)
        if let arm, arm.schemaVersion != HelperProtocolVersion.current {
            throw HelperProtocolError.unsupportedVersion(arm.schemaVersion)
        }
        if let disarm, disarm.schemaVersion != HelperProtocolVersion.current {
            throw HelperProtocolError.unsupportedVersion(disarm.schemaVersion)
        }
        let envelope = HelperEnvelope(
            version: version,
            kind: kind,
            arm: arm,
            disarm: disarm,
            status: status,
            error: error
        )
        guard envelope.shapeIsValid else {
            throw HelperProtocolError.malformed
        }
        self = envelope
    }

    public func encode(to encoder: Encoder) throws {
        guard shapeIsValid, version == HelperProtocolVersion.current else {
            throw HelperProtocolError.malformed
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(arm, forKey: .arm)
        try container.encodeIfPresent(disarm, forKey: .disarm)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(error, forKey: .error)
    }

    private init(
        version: Int,
        kind: HelperMessageKind,
        arm: ArmIntent?,
        disarm: DisarmIntent?,
        status: HelperStatus?,
        error: HelperErrorBody?
    ) {
        self.version = version
        self.kind = kind
        self.arm = arm
        self.disarm = disarm
        self.status = status
        self.error = error
    }

    private var shapeIsValid: Bool {
        switch kind {
        case .arm:
            return arm != nil && disarm == nil && status == nil && error == nil
        case .disarm:
            return disarm != nil && arm == nil && status == nil && error == nil
        case .status:
            return status != nil && arm == nil && disarm == nil && error == nil
        case .statusRead:
            return arm == nil && disarm == nil && status == nil && error == nil
        case .error:
            return error != nil && arm == nil && disarm == nil && status == nil
        }
    }

    private static func checkSchema(_ version: Int) throws {
        guard version == HelperProtocolVersion.current else {
            throw HelperProtocolError.unsupportedVersion(version)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case kind
        case arm
        case disarm
        case status
        case error
    }
}
