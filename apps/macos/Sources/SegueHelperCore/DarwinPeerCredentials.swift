import Darwin
import Foundation
import Security

public enum PeerCredentialError: Error, Equatable {
    case badRequirement(Int32)
}

/// Turns a connected unix socket into a `PeerIdentity`.
///
/// `getpeereid` supplies the uid. `LOCAL_PEERTOKEN` plus
/// `SecCodeCopyGuestWithAttributes` evaluates `requirement`. A uid we could
/// not read is `nil` (the server refuses). A signing failure is still an
/// identity, with `codeSigningSatisfied == false`, so the pure check can
/// tell the two refusals apart.
public protocol PeerCredentialSource: AnyObject {
    func identity(of socket: Int32) -> PeerIdentity?
}

public final class DarwinPeerCredentials: PeerCredentialSource {
    private let requirement: SecRequirement

    public init(requirement requirementText: String) throws {
        var parsed: SecRequirement?
        let status = SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(rawValue: 0),
            &parsed
        )
        guard status == errSecSuccess, let parsed else {
            throw PeerCredentialError.badRequirement(status)
        }
        requirement = parsed
    }

    public func identity(of socket: Int32) -> PeerIdentity? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(socket, &uid, &gid) == 0 else {
            return nil
        }
        return PeerIdentity(uid: uid, codeSigningSatisfied: signingSatisfied(socket))
    }

    private func signingSatisfied(_ socket: Int32) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let tokenRC = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, pointer, &length)
        }
        guard tokenRC == 0 else {
            return false
        }
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attributes = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(rawValue: 0), &guest) == errSecSuccess,
              let guest
        else {
            return false
        }
        return SecCodeCheckValidity(guest, SecCSFlags(rawValue: 0), requirement) == errSecSuccess
    }
}
