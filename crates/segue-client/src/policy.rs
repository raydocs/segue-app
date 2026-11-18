//! Signed policy bundle lifecycle.
//!
//! The kernel is the verifier of the rule table. This module checks the
//! envelope (size, key id, Ed25519 over [`POLICY_SIG_CONTEXT`]), reads
//! `version` and `expires_at` for ordering, and forwards the original bytes.
//! It does not read rules, domains, or the default action, and it does not
//! treat the peek as a compiled policy.
//!
//! Expiry uses the last observed server time when one has been recorded, so a
//! fast or slow device clock cannot by itself expire or extend a bundle. With
//! no server time yet, the injected clock is the fallback.

use serde::Deserialize;
use serde_json::Value;

use crate::canonical::canonical_json;
use crate::envelope::{self, MAX_POLICY_BYTES, POLICY_SIG_CONTEXT};
use crate::keys::TrustedKey;
use crate::persist::SequenceFloor;
use crate::status::PolicyView;

/// How long before `expires_at` a bundle is due for a slow refresh.
pub const POLICY_REFRESH_MARGIN_SECS: u64 = 24 * 60 * 60;

/// A bundle the data plane should receive unchanged.
#[derive(Clone, PartialEq, Eq)]
pub struct PolicyForward {
    pub view: PolicyView,
    /// Exact envelope bytes. Not re-encoded.
    pub bytes: Vec<u8>,
    pub digest: String,
    pub version: u64,
    pub expires_at: u64,
    pub high_water: u64,
    pub idempotent: bool,
    pub expired: bool,
    pub refresh_due: bool,
}

impl std::fmt::Debug for PolicyForward {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PolicyForward")
            .field("version", &self.version)
            .field("expires_at", &self.expires_at)
            .field("digest", &self.digest)
            .field("bytes_len", &self.bytes.len())
            .field("idempotent", &self.idempotent)
            .field("expired", &self.expired)
            .field("refresh_due", &self.refresh_due)
            .field("valid", &self.view.valid)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PolicyError {
    #[error("the protection rules are too large")]
    Oversized,
    #[error("the protection rules are malformed")]
    Malformed,
    #[error("no policy key is configured")]
    NoKey,
    #[error("a policy key id is configured twice")]
    DuplicateKey,
    #[error("a policy key is not an Ed25519 public key")]
    BadKey,
    #[error("the protection rules are signed by an unknown key")]
    UnknownKey,
    #[error("the protection rules signature is not valid")]
    BadSignature,
    #[error("the protection rules are not newer than the ones already installed")]
    Rollback,
    #[error("this policy version does not match the one already installed")]
    DigestConflict,
    #[error("the protection rules have expired")]
    Expired,
    #[error("the protection rules are already expired according to the server")]
    ServerTime,
}

impl PolicyError {
    pub fn code(&self) -> &'static str {
        match self {
            PolicyError::Oversized => "oversized",
            PolicyError::Malformed => "malformed",
            PolicyError::NoKey => "no_key",
            PolicyError::DuplicateKey => "duplicate_key",
            PolicyError::BadKey => "bad_key",
            PolicyError::UnknownKey => "unknown_key",
            PolicyError::BadSignature => "bad_signature",
            PolicyError::Rollback => "rollback",
            PolicyError::DigestConflict => "digest_conflict",
            PolicyError::Expired => "expired",
            PolicyError::ServerTime => "server_time",
        }
    }

    pub fn user_copy(&self) -> &'static str {
        match self {
            PolicyError::Expired | PolicyError::ServerTime => "The protection rules have expired.",
            PolicyError::Rollback | PolicyError::DigestConflict => {
                "These protection rules are older than the ones already installed."
            }
            PolicyError::BadSignature | PolicyError::UnknownKey | PolicyError::NoKey => {
                "Couldn't verify the protection rules."
            }
            PolicyError::Oversized
            | PolicyError::Malformed
            | PolicyError::DuplicateKey
            | PolicyError::BadKey => "The protection rules could not be read.",
        }
    }
}

#[derive(Debug, Deserialize)]
struct Peek {
    version: u64,
    expires_at: u64,
}

/// Admit a bundle for forwarding.
///
/// `server_time` is the newest `Date` observed from the control plane, or 0
/// when none has been seen. A bundle whose `expires_at` is at or before that
/// time is refused even if the device clock is behind.
pub fn admit_policy(
    bytes: &[u8],
    now: u64,
    server_time: u64,
    keys: &[TrustedKey],
    floor: Option<&SequenceFloor>,
) -> Result<PolicyForward, PolicyError> {
    let peeked = peek(bytes, keys)?;
    let basis = expiry_basis(now, server_time);
    if server_time > 0 && server_time >= peeked.expires_at {
        return Err(PolicyError::ServerTime);
    }
    if basis >= peeked.expires_at {
        return Err(PolicyError::Expired);
    }
    decide_version(peeked.version, &peeked.digest, floor)?;
    Ok(assemble(bytes, peeked, floor, now, server_time, false))
}

/// Re-read a bundle that was already stored. An expired bundle is returned
/// with `valid: false` so the UI can say so; the bytes are still the last
/// signed copy. Rollback is not applied: the caller checks the stored floor.
pub fn inspect_policy(
    bytes: &[u8],
    now: u64,
    server_time: u64,
    keys: &[TrustedKey],
) -> Result<PolicyForward, PolicyError> {
    let peeked = peek(bytes, keys)?;
    Ok(assemble(bytes, peeked, None, now, server_time, true))
}

struct Peeked {
    version: u64,
    expires_at: u64,
    digest: String,
}

fn peek(bytes: &[u8], keys: &[TrustedKey]) -> Result<Peeked, PolicyError> {
    if bytes.len() > MAX_POLICY_BYTES {
        return Err(PolicyError::Oversized);
    }
    let digest = envelope::hex_sha256(bytes);
    let opened = envelope::open(bytes, keys, POLICY_SIG_CONTEXT).map_err(map_envelope)?;
    let text = std::str::from_utf8(&opened.body).map_err(|_| PolicyError::Malformed)?;
    let value: Value = serde_json::from_str(text).map_err(|_| PolicyError::Malformed)?;
    if canonical_json(&value).as_bytes() != opened.body.as_slice() {
        return Err(PolicyError::Malformed);
    }
    // Only version and expires_at are read. Other fields stay in the value
    // for the canonical check and are not interpreted.
    let header: Peek = serde_json::from_value(value).map_err(|_| PolicyError::Malformed)?;
    Ok(Peeked {
        version: header.version,
        expires_at: header.expires_at,
        digest,
    })
}

fn assemble(
    bytes: &[u8],
    peeked: Peeked,
    floor: Option<&SequenceFloor>,
    now: u64,
    server_time: u64,
    keep_expired: bool,
) -> PolicyForward {
    let basis = expiry_basis(now, server_time);
    let expired = basis >= peeked.expires_at;
    let idempotent = !keep_expired
        && floor
            .is_some_and(|known| known.sequence == peeked.version && known.digest == peeked.digest);
    let high_water = floor
        .map(|known| known.sequence.max(peeked.version))
        .unwrap_or(peeked.version);
    PolicyForward {
        view: PolicyView {
            valid: !expired,
            version: Some(peeked.version),
            expires_at: Some(peeked.expires_at),
        },
        bytes: bytes.to_vec(),
        digest: peeked.digest,
        version: peeked.version,
        expires_at: peeked.expires_at,
        high_water,
        idempotent,
        expired,
        refresh_due: expired
            || peeked.expires_at.saturating_sub(basis) <= POLICY_REFRESH_MARGIN_SECS,
    }
}

/// Server time wins once it has been observed. Otherwise the device clock.
pub fn expiry_basis(now: u64, server_time: u64) -> u64 {
    if server_time > 0 {
        server_time
    } else {
        now
    }
}

fn decide_version(
    version: u64,
    digest: &str,
    floor: Option<&SequenceFloor>,
) -> Result<(), PolicyError> {
    let floor_seq = floor.map(|known| known.sequence).unwrap_or(0);
    if version > floor_seq {
        return Ok(());
    }
    if floor.is_some_and(|known| known.sequence == version && known.digest == digest) {
        return Ok(());
    }
    if floor.is_some_and(|known| known.sequence == version) {
        return Err(PolicyError::DigestConflict);
    }
    Err(PolicyError::Rollback)
}

fn map_envelope(error: envelope::EnvelopeError) -> PolicyError {
    match error {
        envelope::EnvelopeError::Malformed => PolicyError::Malformed,
        envelope::EnvelopeError::NoKey => PolicyError::NoKey,
        envelope::EnvelopeError::DuplicateKey => PolicyError::DuplicateKey,
        envelope::EnvelopeError::BadKey => PolicyError::BadKey,
        envelope::EnvelopeError::UnknownKey(_) => PolicyError::UnknownKey,
        envelope::EnvelopeError::BadSignature => PolicyError::BadSignature,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::seal;
    use serde_json::json;

    fn admit_at(
        body: Value,
        now: u64,
        server_time: u64,
        floor: Option<&SequenceFloor>,
    ) -> Result<PolicyForward, PolicyError> {
        let seed = seal::seed_from_label("policy-unit");
        let bytes = seal::policy_document(&seed, 1, &body);
        let keys = [TrustedKey {
            key_id: 1,
            public_key: seal::public_key(&seed),
        }];
        admit_policy(&bytes, now, server_time, &keys, floor)
    }

    fn body() -> Value {
        json!({
            "version": 7,
            "expires_at": 1_800_000_000_u64,
            "rules": [{"note": "ignored by the client"}],
            "default": {"type": "reject"}
        })
    }

    #[test]
    fn forwards_original_bytes_and_ignores_rule_shape() {
        let seed = seal::seed_from_label("policy-unit");
        let bytes = seal::policy_document(&seed, 1, &body());
        let keys = [TrustedKey {
            key_id: 1,
            public_key: seal::public_key(&seed),
        }];
        let forward = admit_policy(&bytes, 1_700_001_000, 0, &keys, None).unwrap();
        assert_eq!(forward.bytes, bytes);
        assert!(forward.view.valid);
        assert_eq!(forward.version, 7);
        assert!(!forward.refresh_due);

        let mut nonsense = body();
        nonsense["rules"] = json!("not-rules");
        let still = admit_at(nonsense, 1_700_001_000, 0, None).unwrap();
        assert!(still.view.valid);
        assert!(!format!("{still:?}").contains("not-rules"));
    }

    #[test]
    fn server_time_beats_a_wrong_device_clock() {
        let ahead = admit_at(body(), 1_900_000_000, 1_700_001_000, None).unwrap();
        assert!(
            ahead.view.valid,
            "a fast device clock must not expire a bundle"
        );

        let behind = admit_at(body(), 1_700_001_000, 1_800_000_000, None);
        assert_eq!(behind.unwrap_err().code(), "server_time");

        let no_server = admit_at(body(), 1_800_000_000, 0, None);
        assert_eq!(no_server.unwrap_err().code(), "expired");
    }

    #[test]
    fn rollback_and_same_version_conflict() {
        let first = admit_at(body(), 1_700_001_000, 0, None).unwrap();
        let floor = SequenceFloor {
            sequence: first.version,
            digest: first.digest.clone(),
        };
        let again = admit_at(body(), 1_700_001_000, 0, Some(&floor)).unwrap();
        assert!(again.idempotent);

        let mut older = body();
        older["version"] = json!(6);
        assert_eq!(
            admit_at(older, 1_700_001_000, 0, Some(&floor))
                .unwrap_err()
                .code(),
            "rollback"
        );
        let mut other = body();
        other["expires_at"] = json!(1_700_500_000_u64);
        assert_eq!(
            admit_at(other, 1_700_001_000, 0, Some(&floor))
                .unwrap_err()
                .code(),
            "digest_conflict"
        );
    }
}
