//! Signed JSON envelope shared by the catalog and the policy bundle.
//!
//! `{key_id, body, sig}` with standard base64. The signature covers
//! `context || body-bytes`, so a catalog signature is not a policy signature.
//! The body bytes are returned as signed. Callers decide what, if anything,
//! they read out of them.

use std::collections::BTreeMap;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use ed25519_dalek::{Signature, VerifyingKey};
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::keys::TrustedKey;

/// Domain separation for catalog signatures.
pub const CATALOG_SIG_CONTEXT: &[u8] = b"segue-catalog-v1\0";
/// Domain separation for policy signatures. The kernel verifies the same string.
pub const POLICY_SIG_CONTEXT: &[u8] = b"segue-policy-v1\0";

/// Largest policy envelope accepted. Matches the kernel's bundle cap.
pub const MAX_POLICY_BYTES: usize = 8 << 20;
/// Largest catalog envelope accepted. A catalog is a node list, not a route table.
pub const MAX_CATALOG_BYTES: usize = 1 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum EnvelopeError {
    Malformed,
    NoKey,
    DuplicateKey,
    BadKey,
    UnknownKey(u32),
    BadSignature,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    key_id: u32,
    body: String,
    sig: String,
}

pub(crate) struct Opened {
    pub body: Vec<u8>,
}

/// Verify `bytes` as an envelope. Does not parse the body.
pub(crate) fn open(
    bytes: &[u8],
    keys: &[TrustedKey],
    context: &[u8],
) -> Result<Opened, EnvelopeError> {
    let index = index_keys(keys)?;
    let envelope: Envelope = serde_json::from_slice(bytes).map_err(|_| EnvelopeError::Malformed)?;
    let public = index
        .get(&envelope.key_id)
        .copied()
        .ok_or(EnvelopeError::UnknownKey(envelope.key_id))?;
    let key = VerifyingKey::from_bytes(&public).map_err(|_| EnvelopeError::BadKey)?;
    let body = STANDARD
        .decode(envelope.body.trim())
        .map_err(|_| EnvelopeError::Malformed)?;
    let sig_bytes = STANDARD
        .decode(envelope.sig.trim())
        .map_err(|_| EnvelopeError::Malformed)?;
    let signature = Signature::from_slice(&sig_bytes).map_err(|_| EnvelopeError::Malformed)?;
    let mut message = Vec::with_capacity(context.len() + body.len());
    message.extend_from_slice(context);
    message.extend_from_slice(&body);
    key.verify_strict(&message, &signature)
        .map_err(|_| EnvelopeError::BadSignature)?;
    Ok(Opened { body })
}

pub(crate) fn hex_sha256(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}

fn index_keys(keys: &[TrustedKey]) -> Result<BTreeMap<u32, [u8; 32]>, EnvelopeError> {
    if keys.is_empty() {
        return Err(EnvelopeError::NoKey);
    }
    let mut index = BTreeMap::new();
    for key in keys {
        if index.insert(key.key_id, key.public_key).is_some() {
            return Err(EnvelopeError::DuplicateKey);
        }
    }
    Ok(index)
}
