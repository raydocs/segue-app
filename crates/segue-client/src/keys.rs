//! Public keys the shell configures. Private keys never enter this crate's
//! runtime path; [`crate::seal`] exists so tests can build envelopes from a seed.

/// One Ed25519 public key the control plane signs with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrustedKey {
    pub key_id: u32,
    /// Raw 32-byte Ed25519 verifying key. Not a secret.
    pub public_key: [u8; 32],
}
