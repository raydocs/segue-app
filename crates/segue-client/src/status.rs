//! The one snapshot the UI renders, and the events a shell polls.
//!
//! `phase` is derived from the client, the protector, and the kernel. The UI
//! does not keep a second state machine. Internal failure codes stay on
//! [`FailureView`]; the screen reads [`ClientStatus::user_copy`].

use serde::{Deserialize, Serialize};

/// Schema of [`ClientStatus`]. Bumping this is a client contract change.
pub const STATUS_SCHEMA_VERSION: u32 = 1;

/// Connect phases. The order is the design table, not a progression: the
/// machine moves only by the transitions in `fsm`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    /// Never connected this launch, or the user has finished disconnecting.
    Off,
    /// Admission, cache read, [`crate::prepare`], file writes. Nothing armed yet
    /// on a fresh attempt.
    Preparing,
    /// Protector arm sent, or about to be sent. Arm intent is already recorded.
    Arming,
    /// Kernel connect and probe. Waiting for a carrier.
    Connecting,
    /// Exit evidence and AI-route evidence. Not "connected" yet.
    Verifying,
    /// Arm, carrier, exit evidence, and AI-route evidence all hold.
    Connected,
    /// Armed, no carrier. Auto-reconnect runs until its budget is spent.
    ProtectedOffline,
    /// An explicit release is in flight. A lost reply is not a release.
    Disarming,
    /// Failed before a verified session, or a later prepare failed. Not the
    /// state used for "the user disconnected".
    Failed,
}

impl Phase {
    pub const ALL: [Phase; 9] = [
        Phase::Off,
        Phase::Preparing,
        Phase::Arming,
        Phase::Connecting,
        Phase::Verifying,
        Phase::Connected,
        Phase::ProtectedOffline,
        Phase::Disarming,
        Phase::Failed,
    ];

    /// The UI shows "connected" only in [`Phase::Connected`].
    pub fn shows_connected(self) -> bool {
        matches!(self, Phase::Connected)
    }

    /// Short steady copy. The state machine replaces this when it has a
    /// more specific sentence.
    pub fn label(self) -> &'static str {
        match self {
            Phase::Off => "Not connected.",
            Phase::Preparing => "Preparing protection.",
            Phase::Arming => "Turning on the AI lock.",
            Phase::Connecting => "Connecting.",
            Phase::Verifying => "Checking the secure exit.",
            Phase::Connected => "Connected.",
            Phase::ProtectedOffline => "Reconnecting. The AI lock stays on.",
            Phase::Disarming => "Disconnecting.",
            Phase::Failed => "Couldn't connect.",
        }
    }
}

/// What the user last asked for. A later tunnel-side failure from the same
/// generation must not replace this.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IntentKind {
    Connect,
    UserDisconnect,
    SignOut,
    Quit,
}

impl IntentKind {
    /// The only kinds that may disarm the AI lock.
    pub fn releases(self) -> bool {
        matches!(
            self,
            IntentKind::UserDisconnect | IntentKind::SignOut | IntentKind::Quit
        )
    }
}

/// Recorded on [`ClientStatus`]. `at` is unix seconds from the injected clock.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IntentRecord {
    pub kind: IntentKind,
    pub generation: u64,
    pub at: u64,
}

/// How the user picked an exit. `Auto` pins AI inside one egress group; naming
/// an exit replaces that pin. The kernel owns the pin. This is only the choice.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ExitChoice {
    #[default]
    Auto,
    Named(String),
}

/// One exit row for the picker. Empty until a catalog is installed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExitView {
    pub name: String,
    pub region: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub egress_group: Option<String>,
}

/// Unverified peek at a policy, for ordering the UI. Not authority: the kernel
/// is the only verifier.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct PolicyView {
    pub valid: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<u64>,
}

/// AI-only hold is the product default. Strict keeps ordinary traffic held
/// when the reconnect budget runs out.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ProtectionMode {
    #[default]
    AiOnly,
    Strict,
}

/// What the protector is doing, as far as this process knows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ProtectionView {
    /// Arm intent is recorded, or an arm was acknowledged, and no disarm ack
    /// has cleared it.
    pub armed: bool,
    pub mode: ProtectionMode,
    /// AI destinations stay blocked.
    pub held: bool,
    /// Ordinary traffic is still inside the tunnel. False before the first arm,
    /// and false after an AI-only exhaustion releases the tunnel.
    pub tunnel_held: bool,
}

/// Internal failure code. Never copied onto the screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureCode {
    PrepareInvalid,
    ArmFailed,
    PostureError,
    CarrierLost,
    BudgetExhausted,
    Catalog,
    Update,
    AccountHold,
    CredentialRevoked,
    Timeout,
    ProcessRestart,
}

/// Where a failure came from. A user stop does not write a failure, so there
/// is no `user` source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureSource {
    System,
    Core,
    Network,
    Account,
}

/// A failure the UI may mention in its own words via [`ClientStatus::user_copy`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FailureView {
    pub code: FailureCode,
    pub stage: Phase,
    pub source: FailureSource,
    /// Unix seconds when an automatic retry may run. Absent: the user has to act.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_at: Option<u64>,
}

/// The UI's one input.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClientStatus {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    pub phase: Phase,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub intent: Option<IntentRecord>,
    pub generation: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connected_at: Option<u64>,
    pub exit_choice: ExitChoice,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_exit: Option<String>,
    pub exits: Vec<ExitView>,
    pub policy: PolicyView,
    pub protection: ProtectionView,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub failure: Option<FailureView>,
    pub user_copy: String,
}

impl ClientStatus {
    pub fn offline(mode: ProtectionMode) -> Self {
        Self {
            schema_version: STATUS_SCHEMA_VERSION,
            phase: Phase::Off,
            intent: None,
            generation: 0,
            connected_at: None,
            exit_choice: ExitChoice::Auto,
            current_exit: None,
            exits: Vec::new(),
            policy: PolicyView::default(),
            protection: ProtectionView {
                mode,
                ..ProtectionView::default()
            },
            failure: None,
            user_copy: Phase::Off.label().to_owned(),
        }
    }

    pub fn shows_connected(&self) -> bool {
        self.phase.shows_connected()
    }
}

/// Something the shell should render or persist. Drained by `poll_event`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientEvent {
    PhaseChanged {
        from: Phase,
        to: Phase,
        generation: u64,
    },
    IntentRecorded {
        kind: IntentKind,
        generation: u64,
        at: u64,
    },
    Connected {
        generation: u64,
        at: u64,
    },
    FailureRecorded {
        code: FailureCode,
        generation: u64,
    },
    FailureCleared {
        generation: u64,
    },
    /// AI-only exhaustion dropped the tunnel. The AI lock is still armed.
    OrdinaryTrafficReleased {
        generation: u64,
    },
    CopyChanged {
        user_copy: String,
    },
}
