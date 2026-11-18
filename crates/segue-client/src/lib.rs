//! Portable product logic every Segue app shell links.
//!
//! This crate owns account-facing state, [`prepare`] (catalog + policy + ticket
//! paths → one kernel config), and the connect state machine. It does not own
//! routing, the AI-lock rule table, or the firewall. Those stay in
//! `segue-kernel` and the privileged protector.
//!
//! No OS calls and no sockets. A shell reaches the machine through the five
//! ports in [`ports`]. Test bindings are in-memory, which is what the
//! conformance vectors drive.
//!
//! The default failure mode is an AI-only hold: when the reconnect budget runs
//! out, ordinary traffic is released and AI destinations stay blocked. Strict
//! mode is a user setting, off unless [`ProtectionMode::Strict`] is chosen.
//! Only an explicit disconnect, sign-out, or quit disarms that hold.

#![forbid(unsafe_code)]

pub mod backoff;
pub mod client;
pub mod error;
pub mod fsm;
pub mod plan;
pub mod ports;
pub mod status;

pub use backoff::ReconnectBackoff;
pub use client::{Client, ClientConfig, ClientError, Ports};
pub use error::PrepareError;
pub use fsm::{Effect, Event, EventKind, Fsm, Step};
pub use plan::{
    prepare, CatalogNode, KernelPlan, PlanFile, PlanFileRole, PolicyKeyRef, PrepareInput,
};
pub use ports::{
    Ack, ApiRequest, ApiResponse, ArmAck, ArmEvidence, ArmIntent, ArmRequest, Clock,
    CredentialError, CredentialKey, CredentialStore, DataPlane, DataPlaneError, DisarmIntent,
    DisarmRequest, Egress, HttpTransport, Method, ProbeResult, Protector, ProtectorError,
    ProtectorEvidence, ProtectorStatus, Secret, TransportError,
};
pub use status::{
    ClientEvent, ClientStatus, ExitChoice, ExitView, FailureCode, FailureSource, FailureView,
    IntentKind, IntentRecord, Phase, PolicyView, ProtectionMode, ProtectionView,
    STATUS_SCHEMA_VERSION,
};
