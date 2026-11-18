//! Device ticket lifecycle.
//!
//! Wire form: `SGT1.` + base64url(payload) + `.` + base64url(signature), at most
//! 2048 bytes, no padding. The signature covers [`TICKET_SIG_DOMAIN`] plus the
//! raw payload bytes. A ticket is a bearer secret: views, errors, and debug
//! text never contain it, and buffers are zeroized after decode.
//!
//! Renewal is due `not_after` minus a margin. A ticket that then expires is a
//! scheduled expiry for the UI, not a connect failure. Installing a new ticket
//! must move `not_after` forward; an older ticket is a rollback.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use ed25519_dalek::{Signature, VerifyingKey};
use serde::Deserialize;
use zeroize::Zeroize;

use crate::envelope::hex_sha256;
use crate::keys::TrustedKey;
use crate::persist::SequenceFloor;

/// Domain separation for ticket signatures. The relay verifies the same string.
pub const TICKET_SIG_DOMAIN: &[u8] = b"segue-ticket-v1\n";
pub const MAX_TICKET_BYTES: usize = 2048;
pub const DEFAULT_TICKET_REFRESH_MARGIN_SECS: u64 = 60 * 60;

const PREFIX: &str = "SGT1.";

/// What the UI may know. The ticket bytes are not here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TicketView {
    pub key_id: u32,
    pub device_id: u64,
    pub account_id: u64,
    pub plan: String,
    pub exit_classes: Vec<ExitClass>,
    pub ai_anchor_node_id: u64,
    pub not_before: u64,
    pub not_after: u64,
    pub refresh_due: bool,
    pub expired: bool,
    pub idempotent: bool,
}

impl TicketView {
    pub fn at(mut self, now: u64, margin_secs: u64) -> Self {
        self.expired = now >= self.not_after;
        self.refresh_due = self.expired || now >= self.not_after.saturating_sub(margin_secs);
        self
    }

    /// Scheduled expiry copy. `None` when the ticket is inside its window.
    /// Never includes the ticket.
    pub fn user_copy(&self) -> Option<&'static str> {
        if self.expired {
            Some("The connection ticket has expired. Renewal is scheduled.")
        } else if self.refresh_due {
            Some("The connection ticket is due for renewal.")
        } else {
            None
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ExitClass {
    Overseas,
    Ai,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TicketAdmitted {
    pub view: TicketView,
    pub digest: String,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TicketError {
    #[error("the connection ticket is too large")]
    Oversized,
    #[error("the connection ticket is malformed")]
    Malformed,
    #[error("no ticket key is configured")]
    NoKey,
    #[error("a ticket key id is configured twice")]
    DuplicateKey,
    #[error("a ticket key is not an Ed25519 public key")]
    BadKey,
    #[error("the connection ticket is signed by an unknown key")]
    UnknownKey,
    #[error("the connection ticket signature is not valid")]
    BadSignature,
    #[error("the connection ticket is not valid yet")]
    NotYetValid,
    #[error("the connection ticket has expired")]
    Expired,
    #[error("the connection ticket is older than the one already installed")]
    Rollback,
    #[error("this connection ticket does not match the one already installed")]
    DigestConflict,
    #[error("the connection ticket is for a different device")]
    DeviceMismatch,
}

impl TicketError {
    pub fn code(&self) -> &'static str {
        match self {
            TicketError::Oversized => "oversized",
            TicketError::Malformed => "malformed",
            TicketError::NoKey => "no_key",
            TicketError::DuplicateKey => "duplicate_key",
            TicketError::BadKey => "bad_key",
            TicketError::UnknownKey => "unknown_key",
            TicketError::BadSignature => "bad_signature",
            TicketError::NotYetValid => "not_yet_valid",
            TicketError::Expired => "expired",
            TicketError::Rollback => "rollback",
            TicketError::DigestConflict => "digest_conflict",
            TicketError::DeviceMismatch => "device",
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Claims {
    v: u32,
    key_id: u32,
    device_id: u64,
    #[serde(default)]
    account_id: u64,
    #[serde(default)]
    plan: String,
    exit_classes: Vec<ExitClass>,
    #[serde(default)]
    ai_anchor_node_id: u64,
    not_before: u64,
    not_after: u64,
}

#[derive(Debug, Deserialize)]
struct KeyOnly {
    key_id: u32,
}

/// Admit a ticket for storage. Refuses expired, not-yet-valid, and older tickets.
/// The returned view has no ticket bytes.
pub fn admit_ticket(
    bytes: &[u8],
    now: u64,
    margin_secs: u64,
    keys: &[TrustedKey],
    floor: Option<&SequenceFloor>,
    expected_device: Option<u64>,
) -> Result<TicketAdmitted, TicketError> {
    let digest = hex_sha256(bytes);
    let claims = decode(bytes, keys)?;
    if let Some(device) = expected_device {
        if claims.device_id != device {
            return Err(TicketError::DeviceMismatch);
        }
    }
    if now < claims.not_before {
        return Err(TicketError::NotYetValid);
    }
    if now >= claims.not_after {
        return Err(TicketError::Expired);
    }
    decide_floor(claims.not_after, &digest, floor)?;
    let idempotent =
        floor.is_some_and(|known| known.sequence == claims.not_after && known.digest == digest);
    Ok(TicketAdmitted {
        digest,
        view: view_from(claims, now, margin_secs, idempotent),
    })
}

/// Decode a stored ticket for the UI. Expired is a view flag, not an error,
/// so a missed renewal can be shown without failing connect.
pub fn inspect_ticket(
    bytes: &[u8],
    now: u64,
    margin_secs: u64,
    keys: &[TrustedKey],
) -> Result<TicketView, TicketError> {
    let claims = decode(bytes, keys)?;
    Ok(view_from(claims, now, margin_secs, false))
}

fn view_from(claims: Claims, now: u64, margin_secs: u64, idempotent: bool) -> TicketView {
    TicketView {
        key_id: claims.key_id,
        device_id: claims.device_id,
        account_id: claims.account_id,
        plan: claims.plan,
        exit_classes: claims.exit_classes,
        ai_anchor_node_id: claims.ai_anchor_node_id,
        not_before: claims.not_before,
        not_after: claims.not_after,
        refresh_due: false,
        expired: false,
        idempotent,
    }
    .at(now, margin_secs)
}

fn decide_floor(
    not_after: u64,
    digest: &str,
    floor: Option<&SequenceFloor>,
) -> Result<(), TicketError> {
    let floor_seq = floor.map(|known| known.sequence).unwrap_or(0);
    if not_after > floor_seq {
        return Ok(());
    }
    if floor.is_some_and(|known| known.sequence == not_after && known.digest == digest) {
        return Ok(());
    }
    if floor.is_some_and(|known| known.sequence == not_after) {
        return Err(TicketError::DigestConflict);
    }
    Err(TicketError::Rollback)
}

fn decode(bytes: &[u8], keys: &[TrustedKey]) -> Result<Claims, TicketError> {
    if bytes.len() > MAX_TICKET_BYTES {
        return Err(TicketError::Oversized);
    }
    let text = std::str::from_utf8(bytes).map_err(|_| TicketError::Malformed)?;
    let rest = text.strip_prefix(PREFIX).ok_or(TicketError::Malformed)?;
    let (payload_b64, sig_b64) = rest.split_once('.').ok_or(TicketError::Malformed)?;
    if payload_b64.is_empty() || sig_b64.is_empty() || rest.contains('\n') {
        return Err(TicketError::Malformed);
    }
    let mut payload = URL_SAFE_NO_PAD
        .decode(payload_b64)
        .map_err(|_| TicketError::Malformed)?;
    let sig_bytes = URL_SAFE_NO_PAD
        .decode(sig_b64)
        .map_err(|_| TicketError::Malformed)?;
    let result = verify_payload(&payload, &sig_bytes, keys);
    payload.zeroize();
    let claims = result?;
    if claims.v != 1 || claims.not_after <= claims.not_before {
        return Err(TicketError::Malformed);
    }
    if claims.exit_classes.is_empty() || !is_plan(&claims.plan) {
        return Err(TicketError::Malformed);
    }
    Ok(claims)
}

fn verify_payload(
    payload: &[u8],
    sig_bytes: &[u8],
    keys: &[TrustedKey],
) -> Result<Claims, TicketError> {
    if keys.is_empty() {
        return Err(TicketError::NoKey);
    }
    let mut seen = std::collections::BTreeSet::new();
    for key in keys {
        if !seen.insert(key.key_id) {
            return Err(TicketError::DuplicateKey);
        }
    }
    let header: KeyOnly = serde_json::from_slice(payload).map_err(|_| TicketError::Malformed)?;
    let trusted = keys
        .iter()
        .find(|key| key.key_id == header.key_id)
        .ok_or(TicketError::UnknownKey)?;
    let key = VerifyingKey::from_bytes(&trusted.public_key).map_err(|_| TicketError::BadKey)?;
    let signature = Signature::from_slice(sig_bytes).map_err(|_| TicketError::Malformed)?;
    let mut message = Vec::with_capacity(TICKET_SIG_DOMAIN.len() + payload.len());
    message.extend_from_slice(TICKET_SIG_DOMAIN);
    message.extend_from_slice(payload);
    key.verify_strict(&message, &signature)
        .map_err(|_| TicketError::BadSignature)?;
    serde_json::from_slice(payload).map_err(|_| TicketError::Malformed)
}

fn is_plan(plan: &str) -> bool {
    let bytes = plan.as_bytes();
    bytes.len() <= 32
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-' || *byte == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::seal;
    use serde_json::{json, Value};

    fn sample(not_after: u64) -> Value {
        json!({
            "v": 1,
            "key_id": 1,
            "device_id": 9,
            "account_id": 4,
            "plan": "plus",
            "exit_classes": ["overseas", "ai"],
            "ai_anchor_node_id": 12,
            "not_before": 1_700_000_000_u64,
            "not_after": not_after
        })
    }

    fn signed(body: &Value) -> (Vec<u8>, Vec<TrustedKey>) {
        let seed = seal::seed_from_label("ticket-unit");
        let payload = crate::canonical::canonical_json(body);
        let bytes = seal::ticket(&seed, payload.as_bytes());
        let keys = vec![TrustedKey {
            key_id: 1,
            public_key: seal::public_key(&seed),
        }];
        (bytes, keys)
    }

    #[test]
    fn admits_without_leaking_and_marks_refresh() {
        let (bytes, keys) = signed(&sample(1_700_003_000));
        let admitted = admit_ticket(
            &bytes,
            1_700_001_000,
            DEFAULT_TICKET_REFRESH_MARGIN_SECS,
            &keys,
            None,
            Some(9),
        )
        .unwrap();
        assert!(!admitted.view.expired);
        assert!(admitted.view.refresh_due);
        let rendered = format!("{:?}", admitted.view);
        let error = admit_ticket(&bytes, 1_700_001_000, 3600, &[], None, None).unwrap_err();
        let error_text = error.to_string();
        assert!(!rendered.contains("SGT1."));
        assert!(!error_text.contains("SGT1."));
        assert!(std::str::from_utf8(&bytes).unwrap().starts_with("SGT1."));
        assert_eq!(
            admit_ticket(&bytes, 1_700_001_000, 3600, &keys, None, Some(3))
                .unwrap_err()
                .code(),
            "device"
        );
    }

    #[test]
    fn older_ticket_is_rollback_and_expiry_is_scheduled_on_inspect() {
        let (bytes, keys) = signed(&sample(1_700_010_000));
        let admitted = admit_ticket(&bytes, 1_700_001_000, 60, &keys, None, None).unwrap();
        let floor = SequenceFloor {
            sequence: admitted.view.not_after,
            digest: admitted.digest.clone(),
        };
        assert!(
            admit_ticket(&bytes, 1_700_001_000, 60, &keys, Some(&floor), None)
                .unwrap()
                .view
                .idempotent
        );
        let (older, _) = signed(&sample(1_700_005_000));
        assert_eq!(
            admit_ticket(&older, 1_700_001_000, 60, &keys, Some(&floor), None)
                .unwrap_err()
                .code(),
            "rollback"
        );
        let (expired, _) = signed(&sample(1_700_002_000));
        let view = inspect_ticket(&expired, 1_700_002_000, 60, &keys).unwrap();
        assert!(view.expired);
        let copy = view.user_copy().unwrap();
        assert!(!copy.contains("SGT1"));
        assert!(copy.contains("scheduled") || copy.contains("expired"));
    }
}
