//! Build signed envelopes and tickets from a 32-byte seed.
//!
//! Conformance tests and a dev control plane use this. A shell that only
//! admits documents never calls it, and no production private key is stored
//! in the repository: tests derive the seed from a public label.

use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use ed25519_dalek::{Signer, SigningKey};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::canonical::canonical_json;
use crate::envelope::{CATALOG_SIG_CONTEXT, POLICY_SIG_CONTEXT};
use crate::ticket::TICKET_SIG_DOMAIN;

/// SHA-256 of a public label. The label is not a key; the digest is the seed.
pub fn seed_from_label(label: &str) -> [u8; 32] {
    let digest = Sha256::digest(label.as_bytes());
    let mut seed = [0_u8; 32];
    seed.copy_from_slice(&digest);
    seed
}

pub fn public_key(seed: &[u8; 32]) -> [u8; 32] {
    SigningKey::from_bytes(seed).verifying_key().to_bytes()
}

/// Catalog envelope over the canonical encoding of `body`.
pub fn catalog_document(seed: &[u8; 32], key_id: u32, body: &Value) -> Vec<u8> {
    let canonical = canonical_json(body);
    envelope(CATALOG_SIG_CONTEXT, seed, key_id, canonical.as_bytes())
}

/// Policy envelope over the canonical encoding of `body`.
pub fn policy_document(seed: &[u8; 32], key_id: u32, body: &Value) -> Vec<u8> {
    let canonical = canonical_json(body);
    envelope(POLICY_SIG_CONTEXT, seed, key_id, canonical.as_bytes())
}

/// Envelope over exactly `body`. The body is not rewritten.
pub fn envelope(context: &[u8], seed: &[u8; 32], key_id: u32, body: &[u8]) -> Vec<u8> {
    let signing = SigningKey::from_bytes(seed);
    let mut message = Vec::with_capacity(context.len() + body.len());
    message.extend_from_slice(context);
    message.extend_from_slice(body);
    let signature = signing.sign(&message);
    let value = json!({
        "body": STANDARD.encode(body),
        "key_id": key_id,
        "sig": STANDARD.encode(signature.to_bytes()),
    });
    canonical_json(&value).into_bytes()
}

/// `SGT1.` ticket. `payload` is the raw claims JSON the signature covers.
pub fn ticket(seed: &[u8; 32], payload: &[u8]) -> Vec<u8> {
    let signing = SigningKey::from_bytes(seed);
    let mut message = Vec::with_capacity(TICKET_SIG_DOMAIN.len() + payload.len());
    message.extend_from_slice(TICKET_SIG_DOMAIN);
    message.extend_from_slice(payload);
    let signature = signing.sign(&message);
    let mut out = Vec::new();
    out.extend_from_slice(b"SGT1.");
    out.extend_from_slice(URL_SAFE_NO_PAD.encode(payload).as_bytes());
    out.push(b'.');
    out.extend_from_slice(URL_SAFE_NO_PAD.encode(signature.to_bytes()).as_bytes());
    out
}
