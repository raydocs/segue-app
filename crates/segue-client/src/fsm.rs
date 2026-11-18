//! Connect state machine.
//!
//! Nine phases, one owner. This crate decides the phase. The protector decides
//! whether the AI lock is really installed. The kernel decides posture.
//!
//! Only [`EventKind::UserDisconnect`], [`EventKind::SignOut`], and
//! [`EventKind::Quit`] emit [`Effect::Disarm`] or [`Effect::DisconnectDataPlane`].
//! A lost arm reply stays in [`Phase::Arming`] and is retried. A lost disarm
//! reply stays in [`Phase::Disarming`] and is not treated as a release.
//!
//! A tunnel-side failure never replaces a releasing intent from the same
//! generation. Crash moves the phase to [`Phase::Off`] and leaves that intent,
//! including a recorded arm, in place.
//!
//! The default hold is AI-only. Spending the reconnect budget releases the
//! tunnel (ordinary traffic works again) and does not disarm. [`ProtectionMode::Strict`]
//! keeps the tunnel held. An initial connect that never verifies does not enter
//! [`Phase::ProtectedOffline`]: the phase is [`Phase::Failed`], the tunnel is
//! not held, and an arm that was already acknowledged stays armed. Turning that
//! into a disarm would break the user-intent rule.

use crate::backoff::ReconnectBackoff;
use crate::ports::DisarmIntent;
use crate::status::{
    ClientStatus, FailureCode, FailureSource, FailureView, IntentKind, IntentRecord, Phase,
    ProtectionMode, ProtectionView, STATUS_SCHEMA_VERSION,
};

const ARM_RETRY_MS: u64 = 2_000;
const DISARM_RETRY_MS: u64 = 2_000;

/// What happened. `generation` fences a late event from an older attempt.
/// `None` means "the attempt this machine is in now".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Event {
    pub kind: EventKind,
    pub generation: Option<u64>,
}

impl Event {
    pub fn bare(kind: EventKind) -> Self {
        Self {
            kind,
            generation: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
    UserConnect,
    PrepareInvalid,
    PrepareOk,
    ArmAck,
    ArmError,
    PostureConnected,
    PostureError,
    ExitEvidence,
    AiRouteEvidence,
    CarrierLost,
    ProbeOk,
    ProbeFail,
    UserDisconnect,
    SignOut,
    Quit,
    DisarmAck,
    DisarmNoAck,
    ProcessRestart,
    BudgetExhausted,
    CatalogFailure,
    UpdateFailed,
    AccountHold,
    CredentialRevoked,
    Timeout,
}

/// Side effects, in the order the shell must run them. `PersistArmIntent`
/// comes before `Arm`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    PersistArmIntent {
        generation: u64,
    },
    Arm {
        generation: u64,
        strict: bool,
    },
    RetryArm {
        generation: u64,
        strict: bool,
    },
    ScheduleArmRetry {
        generation: u64,
        delay_ms: u64,
    },
    SetUserEnabled {
        generation: u64,
        enabled: bool,
    },
    Probe {
        generation: u64,
    },
    ScheduleBackoff {
        generation: u64,
        delay_ms: u64,
    },
    /// Drop the tunnel. Not a disarm: the AI lock stays.
    ReleaseOrdinaryTraffic {
        generation: u64,
    },
    DisconnectDataPlane {
        generation: u64,
        intent: DisarmIntent,
    },
    Disarm {
        generation: u64,
        intent: DisarmIntent,
    },
    RetryDisarm {
        generation: u64,
        intent: DisarmIntent,
    },
    ScheduleDisarmRetry {
        generation: u64,
        delay_ms: u64,
    },
}

impl Effect {
    pub fn is_fresh_release(&self) -> bool {
        matches!(
            self,
            Effect::Disarm { .. } | Effect::DisconnectDataPlane { .. }
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Step {
    pub accepted: bool,
    pub effects: Vec<Effect>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fsm {
    phase: Phase,
    mode: ProtectionMode,
    generation: u64,
    intent: Option<IntentRecord>,
    /// Set when entering [`Phase::Arming`], cleared only by a disarm ack.
    arm_persisted: bool,
    /// Set when entering [`Phase::Connected`], cleared only by a disarm ack.
    session_verified: bool,
    exit_evidence: bool,
    ai_evidence: bool,
    connected_at: Option<u64>,
    failure: Option<FailureView>,
    user_copy: String,
    backoff: ReconnectBackoff,
    next_due_ms: Option<u64>,
    arm_retry_due_ms: Option<u64>,
    disarm_retry_due_ms: Option<u64>,
    ordinary_released: bool,
}

impl Fsm {
    pub fn new(mode: ProtectionMode) -> Self {
        Self {
            phase: Phase::Off,
            mode,
            generation: 0,
            intent: None,
            arm_persisted: false,
            session_verified: false,
            exit_evidence: false,
            ai_evidence: false,
            connected_at: None,
            failure: None,
            user_copy: Phase::Off.label().to_owned(),
            backoff: ReconnectBackoff::new(),
            next_due_ms: None,
            arm_retry_due_ms: None,
            disarm_retry_due_ms: None,
            ordinary_released: false,
        }
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn apply(&mut self, event: Event, at_unix: u64, now_ms: u64) -> Step {
        if let Some(generation) = event.generation {
            if generation != self.generation {
                return self.rejected();
            }
        }
        if self.blocked_by_release(event.kind) {
            return self.rejected();
        }
        let effects = match (self.phase, event.kind) {
            (Phase::Off | Phase::Failed | Phase::ProtectedOffline, EventKind::UserConnect) => {
                self.user_connect(at_unix)
            }
            (Phase::Preparing, EventKind::PrepareInvalid) => {
                self.prepare_failed(FailureCode::PrepareInvalid)
            }
            (Phase::Preparing, EventKind::CatalogFailure) => {
                self.prepare_failed(FailureCode::Catalog)
            }
            (Phase::Preparing, EventKind::PrepareOk) => self.prepare_ok(),
            (Phase::Preparing, EventKind::UserDisconnect) => {
                self.begin_release(DisarmIntent::UserDisconnect, at_unix)
            }
            (Phase::Preparing, EventKind::SignOut) => {
                self.begin_release(DisarmIntent::SignOut, at_unix)
            }
            (Phase::Preparing, EventKind::Quit) => self.begin_release(DisarmIntent::Quit, at_unix),
            (Phase::Arming, EventKind::ArmAck) => self.arm_ack(),
            (Phase::Arming, EventKind::ArmError) => self.arm_error(at_unix, now_ms),
            (Phase::Arming, EventKind::UserDisconnect) => {
                self.begin_release(DisarmIntent::UserDisconnect, at_unix)
            }
            (Phase::Arming, EventKind::SignOut) => {
                self.begin_release(DisarmIntent::SignOut, at_unix)
            }
            (Phase::Arming, EventKind::Quit) => self.begin_release(DisarmIntent::Quit, at_unix),
            (Phase::Connecting, EventKind::PostureConnected) => self.posture_connected(),
            (
                Phase::Connecting | Phase::Verifying,
                EventKind::PostureError | EventKind::ProbeFail | EventKind::CarrierLost,
            ) => self.carrier_failed(at_unix, now_ms, FailureCode::PostureError),
            (Phase::Verifying, EventKind::ExitEvidence) => self.note_exit(at_unix),
            (Phase::Verifying, EventKind::AiRouteEvidence) => self.note_ai(at_unix),
            (Phase::Connected, EventKind::CarrierLost | EventKind::PostureError) => self
                .enter_offline(
                    at_unix,
                    now_ms,
                    FailureCode::CarrierLost,
                    FailureSource::Network,
                ),
            (Phase::ProtectedOffline, EventKind::ProbeOk) => self.probe_ok(),
            (Phase::ProtectedOffline, EventKind::ProbeFail | EventKind::PostureError) => {
                self.probe_failed(at_unix, now_ms)
            }
            (Phase::ProtectedOffline, EventKind::BudgetExhausted) => self.budget_exhausted(),
            (
                Phase::Off
                | Phase::Connected
                | Phase::ProtectedOffline
                | Phase::Connecting
                | Phase::Verifying
                | Phase::Failed,
                EventKind::UserDisconnect,
            ) => self.begin_release(DisarmIntent::UserDisconnect, at_unix),
            (
                Phase::Connected
                | Phase::ProtectedOffline
                | Phase::Connecting
                | Phase::Verifying
                | Phase::Failed
                | Phase::Off,
                EventKind::SignOut,
            ) => self.begin_release(DisarmIntent::SignOut, at_unix),
            (
                Phase::Connected
                | Phase::ProtectedOffline
                | Phase::Connecting
                | Phase::Verifying
                | Phase::Failed
                | Phase::Off,
                EventKind::Quit,
            ) => self.begin_release(DisarmIntent::Quit, at_unix),
            (Phase::Disarming, EventKind::DisarmAck) => self.disarm_ack(),
            (Phase::Disarming, EventKind::DisarmNoAck) => self.disarm_no_ack(at_unix, now_ms),
            (Phase::Disarming, EventKind::UserDisconnect) => {
                self.release_again(DisarmIntent::UserDisconnect, at_unix)
            }
            (Phase::Disarming, EventKind::SignOut) => {
                self.release_again(DisarmIntent::SignOut, at_unix)
            }
            (Phase::Disarming, EventKind::Quit) => self.release_again(DisarmIntent::Quit, at_unix),
            (_, EventKind::ProcessRestart) => self.process_restart(),
            (_, EventKind::Timeout) => Vec::new(),
            (phase, EventKind::CatalogFailure) if phase != Phase::Preparing => {
                self.note_nonfatal(FailureCode::Catalog, FailureSource::Core, catalog_copy())
            }
            (_, EventKind::UpdateFailed) => {
                self.note_nonfatal(FailureCode::Update, FailureSource::Core, update_copy())
            }
            (_, EventKind::AccountHold) => self.note_nonfatal(
                FailureCode::AccountHold,
                FailureSource::Account,
                account_copy(),
            ),
            (_, EventKind::CredentialRevoked) => self.note_nonfatal(
                FailureCode::CredentialRevoked,
                FailureSource::Account,
                revoked_copy(),
            ),
            _ => return self.rejected(),
        };
        Step {
            accepted: true,
            effects,
        }
    }

    /// Timers. Does not itself decide that a probe succeeded.
    pub fn tick(&mut self, now_ms: u64) -> Vec<Effect> {
        let mut effects = Vec::new();
        if self.phase == Phase::ProtectedOffline {
            if let Some(due) = self.next_due_ms {
                if now_ms >= due {
                    self.next_due_ms = None;
                    effects.push(Effect::Probe {
                        generation: self.generation,
                    });
                }
            }
        }
        if self.phase == Phase::Arming {
            if let Some(due) = self.arm_retry_due_ms {
                if now_ms >= due {
                    self.arm_retry_due_ms = None;
                    effects.push(Effect::RetryArm {
                        generation: self.generation,
                        strict: self.strict(),
                    });
                }
            }
        }
        if self.phase == Phase::Disarming {
            if let Some(due) = self.disarm_retry_due_ms {
                if now_ms >= due {
                    self.disarm_retry_due_ms = None;
                    if let Some(intent) = self.release_intent() {
                        effects.push(Effect::RetryDisarm {
                            generation: self.generation,
                            intent,
                        });
                    }
                }
            }
        }
        effects
    }

    pub fn status(&self) -> ClientStatus {
        ClientStatus {
            schema_version: STATUS_SCHEMA_VERSION,
            phase: self.phase,
            intent: self.intent.clone(),
            generation: self.generation,
            connected_at: self.connected_at,
            exit_choice: crate::ExitChoice::Auto,
            current_exit: None,
            exits: Vec::new(),
            policy: crate::PolicyView::default(),
            protection: ProtectionView {
                armed: self.armed(),
                mode: self.mode,
                held: self.held(),
                tunnel_held: self.tunnel_held(),
            },
            failure: self.failure.clone(),
            user_copy: self.user_copy.clone(),
        }
    }

    fn armed(&self) -> bool {
        self.arm_persisted
    }

    fn held(&self) -> bool {
        self.arm_persisted
    }

    fn tunnel_held(&self) -> bool {
        if !self.arm_persisted || self.ordinary_released {
            return false;
        }
        match self.phase {
            Phase::Off | Phase::Failed => false,
            Phase::Preparing => self.session_verified,
            Phase::Arming
            | Phase::Connecting
            | Phase::Verifying
            | Phase::Connected
            | Phase::ProtectedOffline
            | Phase::Disarming => true,
        }
    }

    fn strict(&self) -> bool {
        self.mode == ProtectionMode::Strict
    }

    fn rejected(&self) -> Step {
        Step {
            accepted: false,
            effects: Vec::new(),
        }
    }

    /// A releasing intent stays until a new user connect or the release itself
    /// finishes. Tunnel-side events from this generation must not replace it.
    /// A new [`EventKind::UserConnect`] is not one of those events.
    fn blocked_by_release(&self, kind: EventKind) -> bool {
        let Some(intent) = &self.intent else {
            return false;
        };
        if !intent.kind.releases() {
            return false;
        }
        matches!(
            kind,
            EventKind::PostureConnected
                | EventKind::PostureError
                | EventKind::ExitEvidence
                | EventKind::AiRouteEvidence
                | EventKind::CarrierLost
                | EventKind::ProbeOk
                | EventKind::ProbeFail
                | EventKind::Timeout
                | EventKind::BudgetExhausted
                | EventKind::CatalogFailure
                | EventKind::UpdateFailed
                | EventKind::AccountHold
                | EventKind::CredentialRevoked
                | EventKind::PrepareInvalid
                | EventKind::PrepareOk
                | EventKind::ArmAck
                | EventKind::ArmError
        )
    }

    fn user_connect(&mut self, at_unix: u64) -> Vec<Effect> {
        self.generation = self.generation.saturating_add(1);
        self.phase = Phase::Preparing;
        self.intent = Some(IntentRecord {
            kind: IntentKind::Connect,
            generation: self.generation,
            at: at_unix,
        });
        self.failure = None;
        self.exit_evidence = false;
        self.ai_evidence = false;
        self.connected_at = None;
        self.ordinary_released = false;
        self.next_due_ms = None;
        self.arm_retry_due_ms = None;
        self.disarm_retry_due_ms = None;
        self.backoff.reset();
        self.user_copy = Phase::Preparing.label().to_owned();
        Vec::new()
    }

    fn prepare_failed(&mut self, code: FailureCode) -> Vec<Effect> {
        self.phase = if self.session_verified {
            Phase::Failed
        } else {
            Phase::Off
        };
        self.user_copy = "Couldn't prepare the connection.".to_owned();
        self.record(code, FailureSource::Core, None);
        Vec::new()
    }

    fn prepare_ok(&mut self) -> Vec<Effect> {
        self.phase = Phase::Arming;
        self.arm_persisted = true;
        self.failure = None;
        self.user_copy = Phase::Arming.label().to_owned();
        vec![
            Effect::PersistArmIntent {
                generation: self.generation,
            },
            Effect::Arm {
                generation: self.generation,
                strict: self.strict(),
            },
        ]
    }

    fn arm_ack(&mut self) -> Vec<Effect> {
        self.phase = Phase::Connecting;
        self.arm_retry_due_ms = None;
        self.failure = None;
        self.exit_evidence = false;
        self.ai_evidence = false;
        self.user_copy = Phase::Connecting.label().to_owned();
        vec![
            Effect::SetUserEnabled {
                generation: self.generation,
                enabled: true,
            },
            Effect::Probe {
                generation: self.generation,
            },
        ]
    }

    fn arm_error(&mut self, at_unix: u64, now_ms: u64) -> Vec<Effect> {
        self.phase = Phase::Arming;
        self.arm_retry_due_ms = Some(now_ms.saturating_add(ARM_RETRY_MS));
        self.user_copy =
            "Protection could not turn on. Segue will keep trying. The AI lock stays on."
                .to_owned();
        self.record(
            FailureCode::ArmFailed,
            FailureSource::System,
            Some(at_unix.saturating_add(ARM_RETRY_MS / 1_000)),
        );
        vec![Effect::ScheduleArmRetry {
            generation: self.generation,
            delay_ms: ARM_RETRY_MS,
        }]
    }

    fn posture_connected(&mut self) -> Vec<Effect> {
        self.phase = Phase::Verifying;
        self.exit_evidence = false;
        self.ai_evidence = false;
        self.failure = None;
        self.user_copy = Phase::Verifying.label().to_owned();
        Vec::new()
    }

    fn note_exit(&mut self, at_unix: u64) -> Vec<Effect> {
        self.exit_evidence = true;
        self.maybe_connect(at_unix)
    }

    fn note_ai(&mut self, at_unix: u64) -> Vec<Effect> {
        self.ai_evidence = true;
        self.maybe_connect(at_unix)
    }

    fn maybe_connect(&mut self, at_unix: u64) -> Vec<Effect> {
        if self.exit_evidence && self.ai_evidence {
            self.phase = Phase::Connected;
            self.session_verified = true;
            self.ordinary_released = false;
            self.connected_at = Some(at_unix);
            self.backoff.reset();
            self.next_due_ms = None;
            self.failure = None;
            self.user_copy = Phase::Connected.label().to_owned();
        } else {
            self.user_copy = "Still checking the secure exit.".to_owned();
        }
        Vec::new()
    }

    fn carrier_failed(&mut self, at_unix: u64, now_ms: u64, code: FailureCode) -> Vec<Effect> {
        if self.session_verified {
            self.enter_offline(at_unix, now_ms, code, FailureSource::Core)
        } else {
            self.fail_unverified(code)
        }
    }

    fn fail_unverified(&mut self, code: FailureCode) -> Vec<Effect> {
        self.phase = Phase::Failed;
        self.next_due_ms = None;
        self.connected_at = None;
        self.user_copy = "Couldn't connect. The AI lock stays on until you disconnect.".to_owned();
        self.record(code, FailureSource::Core, None);
        if self.arm_persisted && !self.ordinary_released {
            self.ordinary_released = true;
            vec![Effect::ReleaseOrdinaryTraffic {
                generation: self.generation,
            }]
        } else {
            self.ordinary_released = true;
            Vec::new()
        }
    }

    fn enter_offline(
        &mut self,
        at_unix: u64,
        now_ms: u64,
        code: FailureCode,
        source: FailureSource,
    ) -> Vec<Effect> {
        self.phase = Phase::ProtectedOffline;
        self.ordinary_released = false;
        self.connected_at = None;
        self.user_copy = Phase::ProtectedOffline.label().to_owned();
        self.schedule(at_unix, now_ms, code, source)
    }

    fn probe_ok(&mut self) -> Vec<Effect> {
        self.phase = Phase::Connecting;
        self.ordinary_released = false;
        self.exit_evidence = false;
        self.ai_evidence = false;
        self.user_copy = Phase::Connecting.label().to_owned();
        vec![Effect::SetUserEnabled {
            generation: self.generation,
            enabled: true,
        }]
    }

    fn probe_failed(&mut self, at_unix: u64, now_ms: u64) -> Vec<Effect> {
        self.schedule(
            at_unix,
            now_ms,
            FailureCode::PostureError,
            FailureSource::Network,
        )
    }

    fn schedule(
        &mut self,
        at_unix: u64,
        now_ms: u64,
        code: FailureCode,
        source: FailureSource,
    ) -> Vec<Effect> {
        match self.backoff.next_delay_ms() {
            Some(delay) => {
                self.next_due_ms = Some(now_ms.saturating_add(delay));
                self.record(code, source, Some(at_unix.saturating_add(delay / 1_000)));
                vec![Effect::ScheduleBackoff {
                    generation: self.generation,
                    delay_ms: delay,
                }]
            }
            None => self.exhaust(),
        }
    }

    fn budget_exhausted(&mut self) -> Vec<Effect> {
        self.backoff.mark_exhausted();
        self.exhaust()
    }

    fn exhaust(&mut self) -> Vec<Effect> {
        self.next_due_ms = None;
        self.record(FailureCode::BudgetExhausted, FailureSource::Network, None);
        if self.mode == ProtectionMode::Strict {
            self.ordinary_released = false;
            self.user_copy = "Protection is on, but the connection is down. Other traffic stays held until you retry or disconnect.".to_owned();
            return Vec::new();
        }
        self.user_copy =
            "Still protecting AI apps. Other traffic is using your normal connection.".to_owned();
        if self.ordinary_released {
            return Vec::new();
        }
        self.ordinary_released = true;
        vec![Effect::ReleaseOrdinaryTraffic {
            generation: self.generation,
        }]
    }

    /// The only function that emits [`Effect::Disarm`] and
    /// [`Effect::DisconnectDataPlane`].
    fn begin_release(&mut self, intent: DisarmIntent, at_unix: u64) -> Vec<Effect> {
        self.set_release_intent(intent, at_unix);
        self.failure = None;
        self.next_due_ms = None;
        self.arm_retry_due_ms = None;
        self.connected_at = None;
        if !self.arm_persisted {
            self.phase = Phase::Off;
            self.user_copy = released_copy(intent);
            return Vec::new();
        }
        self.phase = Phase::Disarming;
        self.user_copy = releasing_copy(intent);
        vec![
            Effect::DisconnectDataPlane {
                generation: self.generation,
                intent,
            },
            Effect::Disarm {
                generation: self.generation,
                intent,
            },
        ]
    }

    fn release_again(&mut self, intent: DisarmIntent, at_unix: u64) -> Vec<Effect> {
        if self.release_intent() == Some(intent) {
            return Vec::new();
        }
        self.set_release_intent(intent, at_unix);
        self.failure = None;
        self.user_copy = releasing_copy(intent);
        vec![
            Effect::DisconnectDataPlane {
                generation: self.generation,
                intent,
            },
            Effect::Disarm {
                generation: self.generation,
                intent,
            },
        ]
    }

    fn disarm_ack(&mut self) -> Vec<Effect> {
        let intent = self.release_intent();
        self.phase = Phase::Off;
        self.arm_persisted = false;
        self.session_verified = false;
        self.ordinary_released = false;
        self.connected_at = None;
        self.failure = None;
        self.backoff.reset();
        self.next_due_ms = None;
        self.arm_retry_due_ms = None;
        self.disarm_retry_due_ms = None;
        self.exit_evidence = false;
        self.ai_evidence = false;
        self.user_copy = match intent {
            Some(intent) => released_copy(intent),
            None => Phase::Off.label().to_owned(),
        };
        Vec::new()
    }

    fn disarm_no_ack(&mut self, at_unix: u64, now_ms: u64) -> Vec<Effect> {
        let _ = at_unix;
        self.phase = Phase::Disarming;
        self.disarm_retry_due_ms = Some(now_ms.saturating_add(DISARM_RETRY_MS));
        self.failure = None;
        self.user_copy = "Disconnect did not finish. Protection stays on until it does.".to_owned();
        vec![Effect::ScheduleDisarmRetry {
            generation: self.generation,
            delay_ms: DISARM_RETRY_MS,
        }]
    }

    fn process_restart(&mut self) -> Vec<Effect> {
        let was_off = self.phase == Phase::Off && !self.arm_persisted && self.intent.is_none();
        self.phase = Phase::Off;
        self.connected_at = None;
        self.next_due_ms = None;
        self.arm_retry_due_ms = None;
        self.disarm_retry_due_ms = None;
        self.exit_evidence = false;
        self.ai_evidence = false;
        if was_off {
            return Vec::new();
        }
        if let Some(intent) = self.release_intent() {
            if self.arm_persisted {
                self.failure = None;
                self.user_copy = "Segue restarted while disconnecting. Protection stays on until the disconnect finishes.".to_owned();
                return vec![Effect::RetryDisarm {
                    generation: self.generation,
                    intent,
                }];
            }
            self.failure = None;
            self.user_copy = released_copy(intent);
            return Vec::new();
        }
        self.user_copy = if self.arm_persisted {
            "Segue restarted. The AI lock stays on.".to_owned()
        } else {
            "Segue restarted.".to_owned()
        };
        self.record(FailureCode::ProcessRestart, FailureSource::Core, None);
        Vec::new()
    }

    fn note_nonfatal(
        &mut self,
        code: FailureCode,
        source: FailureSource,
        copy: &str,
    ) -> Vec<Effect> {
        self.user_copy = copy.to_owned();
        self.record(code, source, None);
        Vec::new()
    }

    fn record(&mut self, code: FailureCode, source: FailureSource, retry_at: Option<u64>) {
        self.failure = Some(FailureView {
            code,
            stage: self.phase,
            source,
            retry_at,
        });
    }

    fn set_release_intent(&mut self, intent: DisarmIntent, at_unix: u64) {
        let kind = match intent {
            DisarmIntent::UserDisconnect => IntentKind::UserDisconnect,
            DisarmIntent::SignOut => IntentKind::SignOut,
            DisarmIntent::Quit => IntentKind::Quit,
        };
        self.intent = Some(IntentRecord {
            kind,
            generation: self.generation,
            at: at_unix,
        });
    }

    fn release_intent(&self) -> Option<DisarmIntent> {
        match self.intent.as_ref().map(|intent| intent.kind) {
            Some(IntentKind::UserDisconnect) => Some(DisarmIntent::UserDisconnect),
            Some(IntentKind::SignOut) => Some(DisarmIntent::SignOut),
            Some(IntentKind::Quit) => Some(DisarmIntent::Quit),
            _ => None,
        }
    }
}

fn releasing_copy(intent: DisarmIntent) -> String {
    match intent {
        DisarmIntent::UserDisconnect => "Disconnecting.".to_owned(),
        DisarmIntent::SignOut => "Signing out.".to_owned(),
        DisarmIntent::Quit => "Quitting.".to_owned(),
    }
}

fn released_copy(intent: DisarmIntent) -> String {
    match intent {
        DisarmIntent::UserDisconnect => "Disconnected.".to_owned(),
        DisarmIntent::SignOut => "Signed out.".to_owned(),
        DisarmIntent::Quit => "Quit.".to_owned(),
    }
}

fn catalog_copy() -> &'static str {
    "The server list could not be updated. The connection stays as it is."
}

fn update_copy() -> &'static str {
    "An update did not finish. The connection stays as it is."
}

fn account_copy() -> &'static str {
    "The account needs attention. The connection stays as it is."
}

fn revoked_copy() -> &'static str {
    "This device needs to sign in again. Protection stays on until you disconnect."
}

#[cfg(test)]
mod tests {
    use super::*;

    const AT: u64 = 1_700_000_000;

    fn drive(phase: Phase) -> Fsm {
        let mut fsm = Fsm::new(ProtectionMode::AiOnly);
        let seq: &[EventKind] = match phase {
            Phase::Off => &[],
            Phase::Preparing => &[EventKind::UserConnect],
            Phase::Arming => &[EventKind::UserConnect, EventKind::PrepareOk],
            Phase::Connecting => &[
                EventKind::UserConnect,
                EventKind::PrepareOk,
                EventKind::ArmAck,
            ],
            Phase::Verifying => &[
                EventKind::UserConnect,
                EventKind::PrepareOk,
                EventKind::ArmAck,
                EventKind::PostureConnected,
            ],
            Phase::Connected => &[
                EventKind::UserConnect,
                EventKind::PrepareOk,
                EventKind::ArmAck,
                EventKind::PostureConnected,
                EventKind::ExitEvidence,
                EventKind::AiRouteEvidence,
            ],
            Phase::ProtectedOffline => &[
                EventKind::UserConnect,
                EventKind::PrepareOk,
                EventKind::ArmAck,
                EventKind::PostureConnected,
                EventKind::ExitEvidence,
                EventKind::AiRouteEvidence,
                EventKind::CarrierLost,
            ],
            Phase::Disarming => &[
                EventKind::UserConnect,
                EventKind::PrepareOk,
                EventKind::ArmAck,
                EventKind::PostureConnected,
                EventKind::ExitEvidence,
                EventKind::AiRouteEvidence,
                EventKind::UserDisconnect,
            ],
            Phase::Failed => &[
                EventKind::UserConnect,
                EventKind::PrepareOk,
                EventKind::ArmAck,
                EventKind::PostureError,
            ],
        };
        for kind in seq {
            let step = fsm.apply(Event::bare(*kind), AT, 0);
            assert!(step.accepted, "{phase:?} via {kind:?}");
        }
        assert_eq!(fsm.phase(), phase);
        fsm
    }

    fn no_fresh_release(effects: &[Effect]) {
        assert!(
            effects.iter().all(|effect| !effect.is_fresh_release()),
            "{effects:?}"
        );
    }

    #[test]
    fn every_phase_is_reachable_and_failure_events_do_not_disarm() {
        let noisy = [
            EventKind::Timeout,
            EventKind::CatalogFailure,
            EventKind::UpdateFailed,
            EventKind::AccountHold,
            EventKind::CredentialRevoked,
            EventKind::BudgetExhausted,
        ];
        for phase in Phase::ALL {
            let base = drive(phase);
            for kind in noisy {
                let mut fsm = base.clone();
                let armed = fsm.armed();
                let intent = fsm.intent.clone();
                let step = fsm.apply(Event::bare(kind), AT, 0);
                no_fresh_release(&step.effects);
                if armed {
                    assert!(fsm.armed(), "{phase:?} {kind:?} cleared the lock");
                }
                if intent.as_ref().is_some_and(|item| item.kind.releases()) {
                    assert_eq!(
                        fsm.intent.as_ref().map(|item| item.kind),
                        intent.as_ref().map(|item| item.kind)
                    );
                    assert!(fsm.failure.is_none(), "a user stop must not gain a failure");
                }
            }
        }
    }

    #[test]
    fn process_restart_keeps_a_recorded_arm_and_does_not_disarm() {
        let mut fsm = drive(Phase::Connected);
        let step = fsm.apply(Event::bare(EventKind::ProcessRestart), AT, 0);
        no_fresh_release(&step.effects);
        assert_eq!(fsm.phase(), Phase::Off);
        assert!(fsm.armed());
        assert_eq!(
            fsm.intent.as_ref().map(|item| item.kind),
            Some(IntentKind::Connect)
        );
        assert!(!fsm.status().shows_connected());
        assert_eq!(
            fsm.failure.as_ref().map(|failure| failure.code),
            Some(FailureCode::ProcessRestart)
        );
    }

    #[test]
    fn a_user_stop_writes_no_failure_and_a_later_tunnel_event_sticks() {
        let mut fsm = drive(Phase::Connected);
        let step = fsm.apply(Event::bare(EventKind::UserDisconnect), AT, 0);
        assert!(step.effects.iter().any(Effect::is_fresh_release));
        assert!(fsm.failure.is_none());
        let step = fsm.apply(Event::bare(EventKind::PostureError), AT, 10);
        assert!(!step.accepted);
        assert_eq!(fsm.phase(), Phase::Disarming);
        assert!(fsm.failure.is_none());
        assert_eq!(
            fsm.intent.as_ref().map(|item| item.kind),
            Some(IntentKind::UserDisconnect)
        );
    }

    #[test]
    fn copy_does_not_carry_internal_codes() {
        let mut fsm = drive(Phase::Connected);
        let kinds = [
            EventKind::AccountHold,
            EventKind::CredentialRevoked,
            EventKind::CatalogFailure,
            EventKind::UpdateFailed,
            EventKind::CarrierLost,
            EventKind::BudgetExhausted,
        ];
        let forbidden = [
            "prepare_invalid",
            "arm_failed",
            "posture_error",
            "carrier_lost",
            "budget_exhausted",
            "credential_revoked",
            "account_hold",
            "process_restart",
            "PLAN_",
            "401",
            "403",
        ];
        for kind in kinds {
            fsm.apply(Event::bare(kind), AT, 0);
            let copy = fsm.status().user_copy.to_ascii_lowercase();
            for token in forbidden {
                assert!(
                    !copy.contains(token),
                    "{kind:?} copy {:?} contains {token}",
                    fsm.status().user_copy
                );
            }
        }
    }

    #[test]
    fn tick_probes_on_the_rung_and_not_before() {
        let mut fsm = drive(Phase::ProtectedOffline);
        assert!(fsm.tick(1_999).is_empty());
        let effects = fsm.tick(2_000);
        assert_eq!(
            effects,
            vec![Effect::Probe {
                generation: fsm.generation()
            }]
        );
        assert!(fsm.tick(2_000).is_empty(), "a probe is not double-fired");
    }
}
