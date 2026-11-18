//! Portable product logic every Segue app shell links.
//!
//! This crate owns account-facing state, [`prepare`] (catalog + policy + ticket
//! paths → one kernel config), and the connect state machine. It does not own
//! routing, the AI-lock rule table, or the firewall. Those stay in
//! `segue-kernel` and the privileged protector.
//!
//! No OS calls and no sockets. A shell reaches the machine through the ports
//! in [`ports`], including the state store that holds the catalog, policy, and
//! ticket cache. Test bindings are in-memory, which is what the conformance
//! vectors drive. The crate does not parse a policy rule table: it checks the
//! signed envelope and forwards the original bytes.
//!
//! The default failure mode is an AI-only hold: when the reconnect budget runs
//! out, ordinary traffic is released and AI destinations stay blocked. Strict
//! mode is a user setting, off unless [`ProtectionMode::Strict`] is chosen.
//! Only an explicit disconnect, sign-out, or quit disarms that hold.

#![forbid(unsafe_code)]

pub mod account;
pub mod backoff;
pub mod canonical;
pub mod catalog;
pub mod client;
pub mod envelope;
pub mod error;
pub mod fsm;
pub mod keys;
pub mod persist;
pub mod plan;
pub mod policy;
pub mod ports;
pub mod seal;
pub mod status;
pub mod ticket;

pub use account::{
    classify_account_response, AccountError, AccountFailure, AccountSession, Device, Entitlement,
    Platform,
};
pub use backoff::ReconnectBackoff;
pub use canonical::canonical_json;
pub use catalog::{admit_catalog, CatalogError, CatalogInstall};
pub use client::{Client, ClientConfig, ClientError, Ports};
pub use envelope::{CATALOG_SIG_CONTEXT, MAX_CATALOG_BYTES, MAX_POLICY_BYTES, POLICY_SIG_CONTEXT};
pub use error::PrepareError;
pub use fsm::{Effect, Event, EventKind, Fsm, Step};
pub use keys::TrustedKey;
pub use persist::SequenceFloor;
pub use plan::{
    prepare, CatalogNode, KernelPlan, PlanFile, PlanFileRole, PolicyKeyRef, PrepareInput,
};
pub use policy::{
    admit_policy, inspect_policy, PolicyError, PolicyForward, POLICY_REFRESH_MARGIN_SECS,
};
pub use ports::{
    Ack, ApiRequest, ApiResponse, ArmAck, ArmEvidence, ArmIntent, ArmRequest, Clock,
    CredentialError, CredentialKey, CredentialStore, DataPlane, DataPlaneError, DisarmIntent,
    DisarmRequest, Egress, HttpTransport, Method, ProbeResult, Protector, ProtectorError,
    ProtectorEvidence, ProtectorStatus, Secret, StateKey, StateStore, StoreError, TransportError,
};
pub use status::{
    ClientEvent, ClientStatus, ExitChoice, ExitView, FailureCode, FailureSource, FailureView,
    IntentKind, IntentRecord, Phase, PolicyView, ProtectionMode, ProtectionView,
    STATUS_SCHEMA_VERSION,
};
pub use ticket::{
    admit_ticket, inspect_ticket, ExitClass, TicketAdmitted, TicketError, TicketView,
    DEFAULT_TICKET_REFRESH_MARGIN_SECS, MAX_TICKET_BYTES, TICKET_SIG_DOMAIN,
};
