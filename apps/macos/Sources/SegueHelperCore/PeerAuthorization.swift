import Foundation

/// Facts the socket layer already collected. The code-signing bit is the
/// result of the requirement check, not a substitute the caller invents.
public struct PeerIdentity: Equatable, Sendable {
    public var uid: uid_t
    public var codeSigningSatisfied: Bool

    public init(uid: uid_t, codeSigningSatisfied: Bool) {
        self.uid = uid
        self.codeSigningSatisfied = codeSigningSatisfied
    }
}

public struct PeerPolicy: Equatable, Sendable {
    public var allowedUIDs: [uid_t]
    /// Requirement text the credential source evaluated. Empty is not a pass.
    public var requirement: String

    public init(allowedUIDs: [uid_t], requirement: String) {
        self.allowedUIDs = allowedUIDs
        self.requirement = requirement
    }
}

public enum DenyReason: String, Equatable, Sendable {
    case uid
    case codeSigning = "code_signing"
}

public enum Decision: Equatable, Sendable {
    case allow
    case deny(DenyReason)
}

/// Design default (docs/design/macos.md §7). A debugger entitlement fails it.
public enum SegueCodeSigning {
    public static let requirement =
        "anchor apple generic and identifier \"com.raydocs.segue\" and certificate leaf[subject.OU] = \"YY57758GS7\" and entitlement[\"com.apple.security.get-task-allow\"] absent"
}

/// UID and the code-signing requirement are both required. UID is checked
/// first so a stranger is refused before the signing result matters.
public func authorize(peer: PeerIdentity, policy: PeerPolicy) -> Decision {
    guard policy.allowedUIDs.contains(peer.uid) else {
        return .deny(.uid)
    }
    let requirement = policy.requirement.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !requirement.isEmpty, peer.codeSigningSatisfied else {
        return .deny(.codeSigning)
    }
    return .allow
}

/// Lines of decimal uids. Blank lines and `#` comments are ignored.
/// Unparseable lines are skipped, never treated as "allow everyone".
public func parseAllowedUIDs(_ text: String) -> [uid_t] {
    var uids: [uid_t] = []
    for raw in text.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") {
            continue
        }
        guard let uid = uid_t(line) else {
            continue
        }
        uids.append(uid)
    }
    return uids
}
