//! The ports a shell injects. Production bindings talk to the OS; tests use
//! in-memory fakes. Nothing in this crate opens a socket or a file of its own.
//! The state store is the cache: catalog, policy, and ticket bytes live there.
//!
//! The traits are synchronous on purpose. The state machine is sans-IO: the
//! shell calls the ports while it applies effects. An async HTTP stack lives
//! in the shell, behind [`HttpTransport`].

use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

use crate::plan::KernelPlan;

/// Bytes the debug format must not print. Dropped buffers are cleared.
#[derive(Clone, PartialEq, Eq)]
pub struct Secret(Vec<u8>);

impl Secret {
    pub fn new(bytes: impl AsRef<[u8]>) -> Self {
        Self(bytes.as_ref().to_vec())
    }

    pub fn expose(&self) -> &[u8] {
        &self.0
    }
}

impl std::fmt::Debug for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Secret([redacted])")
    }
}

impl Drop for Secret {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
    Put,
    Delete,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiRequest {
    pub method: Method,
    pub path: String,
    pub body: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TransportError {
    #[error("transport unavailable")]
    Unavailable,
    #[error("transport refused the request")]
    Refused,
}

/// The shell's HTTP client. The client crate never chooses a host.
pub trait HttpTransport {
    fn send(&self, req: &ApiRequest) -> Result<ApiResponse, TransportError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CredentialKey {
    RefreshToken,
    DeviceId,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CredentialError {
    #[error("credential store unavailable")]
    Unavailable,
    #[error("credential store refused the operation")]
    Refused,
}

/// Keychain, Credential Manager, or a test map. Refresh tokens live here, not
/// in [`crate::ClientStatus`].
pub trait CredentialStore {
    fn get(&self, key: CredentialKey) -> Result<Option<Secret>, CredentialError>;
    fn set(&self, key: CredentialKey, value: &Secret) -> Result<(), CredentialError>;
    fn delete(&self, key: CredentialKey) -> Result<(), CredentialError>;
}

/// What a probe through the data plane just saw. This is not "connected":
/// connected still needs protector evidence and an AI route.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeResult {
    Ready,
    Down,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DataPlaneError {
    #[error("data plane unavailable")]
    Unavailable,
    #[error("data plane refused the operation")]
    Refused,
}

/// Kernel control API (process mode) or the embedded kernel. `disconnect` is
/// only invoked for an explicit user disconnect, sign-out, or quit.
pub trait DataPlane {
    fn apply(&self, plan: &KernelPlan) -> Result<(), DataPlaneError>;
    fn set_user_enabled(&self, enabled: bool) -> Result<(), DataPlaneError>;
    fn probe(&self) -> Result<ProbeResult, DataPlaneError>;
    fn disconnect(&self, intent: DisarmIntent) -> Result<(), DataPlaneError>;
    /// Stop the tunnel so ordinary traffic uses the physical network. Does not
    /// disarm the AI lock. Used when an AI-only hold exhausts its budget.
    fn release_ordinary(&self) -> Result<(), DataPlaneError>;
}

/// Wire intent on `POST /v1/arm`. The only value is a user connect.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ArmIntent {
    #[serde(rename = "user_connect")]
    UserConnect,
}

/// Wire intent on `POST /v1/disarm`. A body without one of these is refused
/// by the protector; this type cannot omit it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DisarmIntent {
    #[serde(rename = "user_disconnect")]
    UserDisconnect,
    #[serde(rename = "sign_out")]
    SignOut,
    #[serde(rename = "quit")]
    Quit,
}

impl DisarmIntent {
    pub fn as_intent_kind(self) -> crate::IntentKind {
        match self {
            DisarmIntent::UserDisconnect => crate::IntentKind::UserDisconnect,
            DisarmIntent::SignOut => crate::IntentKind::SignOut,
            DisarmIntent::Quit => crate::IntentKind::Quit,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Egress {
    pub ip: String,
    pub port: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArmEvidence {
    pub policy_version: u64,
    pub posture: String,
}

/// `POST /v1/arm`. The protector decides; this is the app's proposal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArmRequest {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    pub generation: u64,
    pub intent: ArmIntent,
    pub anchor_revision: u64,
    pub manifest_digest: String,
    pub egress: Vec<Egress>,
    pub exit_ifaces: Vec<String>,
    pub strict: bool,
    pub evidence: ArmEvidence,
}

/// `POST /v1/disarm`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DisarmRequest {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    pub generation: u64,
    pub intent: DisarmIntent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProtectorEvidence {
    pub tcp_proof_ms: Option<u64>,
    pub dns_readback: bool,
}

/// `GET /v1/status` on the protector. Evidence here was measured by the
/// protector, not supplied by the app.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProtectorStatus {
    pub armed: bool,
    pub generation: u64,
    pub held: bool,
    pub rules_digest: String,
    pub evidence: ProtectorEvidence,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ack {
    pub generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArmAck {
    pub generation: u64,
    pub rules_digest: String,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ProtectorError {
    #[error("protector unavailable")]
    Unavailable,
    #[error("protector refused the operation")]
    Refused,
}

/// Privileged helper (desktop) or the in-process VPN service (mobile).
/// `disarm` is only invoked for [`DisarmIntent`].
pub trait Protector {
    fn arm(&self, req: &ArmRequest) -> Result<ArmAck, ProtectorError>;
    fn disarm(&self, req: &DisarmRequest) -> Result<Ack, ProtectorError>;
    fn status(&self) -> ProtectorStatus;
}

/// Time enters the state machine only through this port, so tests can replay
/// a vector without sleeping.
pub trait Clock {
    fn now_unix(&self) -> u64;
    fn monotonic_ms(&self) -> u64;
}

/// One persisted blob. The binding chooses the path. This crate never opens a
/// file itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum StateKey {
    /// Exact admitted catalog envelope.
    CatalogWire,
    /// `{revision} {digest}` high-water. Moves forward only.
    CatalogFloor,
    /// Exact policy envelope forwarded to the data plane.
    PolicyWire,
    /// `{version} {digest}` rollback floor.
    PolicyFloor,
    /// Newest observed server `Date`, decimal unix seconds.
    ServerTime,
    /// Ticket bytes. A secret: the binding writes them mode `0600` and does
    /// not log them.
    TicketWire,
    /// `{not_after} {digest}` so an older ticket cannot replace a newer one.
    TicketFloor,
}

impl StateKey {
    /// Ticket bytes must not be logged or left world-readable.
    pub fn is_secret(self) -> bool {
        matches!(self, StateKey::TicketWire)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum StoreError {
    #[error("state store unavailable")]
    Unavailable,
    #[error("state store refused the operation")]
    Refused,
}

/// On-disk cache for catalog, policy, and ticket bytes.
///
/// `put` replaces one key atomically: a crash leaves the previous value or the
/// new one, never a torn write. `put` of [`StateKey::TicketWire`] is a bearer
/// secret and the binding stores it with mode `0600`.
pub trait StateStore {
    fn get(&self, key: StateKey) -> Result<Option<Vec<u8>>, StoreError>;
    fn put(&self, key: StateKey, bytes: &[u8]) -> Result<(), StoreError>;
    fn delete(&self, key: StateKey) -> Result<(), StoreError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_debug_redacts_and_arm_json_matches_the_wire() {
        let secret = Secret::new(b"refresh-token-value");
        let rendered = format!("{secret:?}");
        assert!(!rendered.contains("refresh-token-value"));
        assert!(rendered.contains("redacted"));

        let arm = ArmRequest {
            schema_version: 1,
            generation: 4,
            intent: ArmIntent::UserConnect,
            anchor_revision: 9,
            manifest_digest: "abc".to_owned(),
            egress: vec![Egress {
                ip: "203.0.113.10".to_owned(),
                port: 443,
            }],
            exit_ifaces: vec!["utun4".to_owned()],
            strict: false,
            evidence: ArmEvidence {
                policy_version: 7,
                posture: "connecting".to_owned(),
            },
        };
        let json = serde_json::to_string(&arm).unwrap();
        assert_eq!(
            json,
            concat!(
                r#"{"schemaVersion":1,"generation":4,"intent":"user_connect","#,
                r#""anchor_revision":9,"manifest_digest":"abc","egress":[{"ip":"203.0.113.10","port":443}],"#,
                r#""exit_ifaces":["utun4"],"strict":false,"evidence":{"policy_version":7,"posture":"connecting"}}"#
            )
        );

        let disarm = DisarmRequest {
            schema_version: 1,
            generation: 4,
            intent: DisarmIntent::UserDisconnect,
        };
        assert_eq!(
            serde_json::to_string(&disarm).unwrap(),
            r#"{"schemaVersion":1,"generation":4,"intent":"user_disconnect"}"#
        );
        assert_eq!(
            serde_json::to_string(&DisarmIntent::SignOut).unwrap(),
            r#""sign_out""#
        );
        assert_eq!(
            serde_json::to_string(&DisarmIntent::Quit).unwrap(),
            r#""quit""#
        );
    }
}
