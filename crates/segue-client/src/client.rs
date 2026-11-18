//! The shell-facing owner of the state machine and the five ports.
//!
//! `disconnect`, `sign_out`, and `quit` are the only methods that can ask the
//! protector to disarm or the data plane to disconnect. There is no
//! `release`. Port failures become state-machine events; they do not clear
//! the AI lock on their own.

use std::collections::VecDeque;

use crate::account::{AccountError, AccountFailure, AccountSession, Device};
use crate::catalog::{self, CatalogError, CatalogInstall};
use crate::fsm::{Effect, Event, EventKind, Fsm, Step};
use crate::keys::TrustedKey;
use crate::persist::{self, PersistError, SequenceFloor};
use crate::plan::{self, KernelPlan, PrepareInput};
use crate::policy::{self, PolicyForward};
use crate::ports::{
    ArmEvidence, ArmIntent, ArmRequest, Clock, CredentialError, CredentialKey, CredentialStore,
    DataPlane, DisarmIntent, DisarmRequest, Egress, HttpTransport, ProbeResult, Protector, Secret,
    StateKey, StateStore, StoreError,
};
use crate::status::{
    ClientEvent, ClientStatus, ExitChoice, ExitView, Phase, PolicyView, ProtectionMode,
};
use crate::ticket::{self, TicketError, TicketView};
use crate::PrepareError;

/// What the shell knows before the first catalog is loaded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientConfig {
    pub protection: ProtectionMode,
    pub anchor_revision: u64,
    pub exit_ifaces: Vec<String>,
    pub egress: Vec<Egress>,
    pub policy_version: u64,
    pub catalog_keys: Vec<TrustedKey>,
    pub policy_keys: Vec<TrustedKey>,
    pub ticket_keys: Vec<TrustedKey>,
    /// Renewal margin subtracted from a ticket's `not_after`.
    pub ticket_refresh_margin_secs: u64,
}

impl Default for ClientConfig {
    fn default() -> Self {
        Self {
            protection: ProtectionMode::AiOnly,
            anchor_revision: 0,
            exit_ifaces: Vec::new(),
            egress: Vec::new(),
            policy_version: 0,
            catalog_keys: Vec::new(),
            policy_keys: Vec::new(),
            ticket_keys: Vec::new(),
            ticket_refresh_margin_secs: crate::DEFAULT_TICKET_REFRESH_MARGIN_SECS,
        }
    }
}

pub struct Ports<H, S, D, P, C, B> {
    pub http: H,
    pub credentials: S,
    pub data_plane: D,
    pub protector: P,
    pub clock: C,
    /// Catalog, policy, and ticket cache. `put` is atomic; ticket bytes are a secret.
    pub state: B,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ClientError {
    #[error("that transition is not allowed")]
    Rejected,
    #[error(transparent)]
    Prepare(#[from] PrepareError),
    #[error(transparent)]
    Catalog(#[from] CatalogError),
    #[error(transparent)]
    Policy(#[from] crate::PolicyError),
    #[error(transparent)]
    Ticket(#[from] TicketError),
    #[error(transparent)]
    Account(#[from] AccountError),
    #[error(transparent)]
    Credential(#[from] CredentialError),
    #[error(transparent)]
    State(#[from] StoreError),
    #[error("stored state could not be read")]
    Floor,
}

struct HeldPolicy {
    version: u64,
    expires_at: u64,
    bytes: Vec<u8>,
}

pub struct Client<H, S, D, P, C, B> {
    fsm: Fsm,
    ports: Ports<H, S, D, P, C, B>,
    config: ClientConfig,
    plan: Option<KernelPlan>,
    events: VecDeque<ClientEvent>,
    effects: Vec<Effect>,
    now_ms: u64,
    exit_choice: ExitChoice,
    current_exit: Option<String>,
    exits: Vec<ExitView>,
    policy: PolicyView,
    catalog: Option<CatalogInstall>,
    policy_held: Option<HeldPolicy>,
    ticket: Option<Secret>,
    ticket_view: Option<TicketView>,
    server_time: u64,
    session: Option<AccountSession>,
    device: Option<Device>,
}

impl<H, S, D, P, C, B> Client<H, S, D, P, C, B>
where
    H: HttpTransport,
    S: CredentialStore,
    D: DataPlane,
    P: Protector,
    C: Clock,
    B: StateStore,
{
    pub fn new(config: ClientConfig, ports: Ports<H, S, D, P, C, B>) -> Result<Self, ClientError> {
        let now_ms = ports.clock.monotonic_ms();
        let mode = config.protection;
        Ok(Self {
            fsm: Fsm::new(mode),
            ports,
            config,
            plan: None,
            events: VecDeque::new(),
            effects: Vec::new(),
            now_ms,
            exit_choice: ExitChoice::Auto,
            current_exit: None,
            exits: Vec::new(),
            policy: PolicyView::default(),
            catalog: None,
            policy_held: None,
            ticket: None,
            ticket_view: None,
            server_time: 0,
            session: None,
            device: None,
        })
    }

    /// Admit a signed catalog, cache it, and return the nodes [`prepare`](Self::prepare)
    /// takes. An absent egress group stays absent.
    pub fn install_catalog(&mut self, bytes: &[u8]) -> Result<CatalogInstall, ClientError> {
        let now = self.ports.clock.now_unix();
        let floor = self.floor(StateKey::CatalogFloor)?;
        match catalog::admit_catalog(bytes, now, &self.config.catalog_keys, floor.as_ref()) {
            Ok(install) => {
                self.persist_wire(
                    StateKey::CatalogWire,
                    StateKey::CatalogFloor,
                    bytes,
                    install.revision,
                    &install.digest,
                    install.idempotent,
                )?;
                self.config.anchor_revision = install.revision;
                self.exits = install.exits.clone();
                self.catalog = Some(install.clone());
                Ok(install)
            }
            Err(error) => {
                self.note_content_failure(EventKind::CatalogFailure);
                Err(error.into())
            }
        }
    }

    /// Check the policy envelope and cache the original bytes for the data plane.
    /// The rule table is not parsed.
    pub fn install_policy(&mut self, bytes: &[u8]) -> Result<PolicyForward, ClientError> {
        let now = self.ports.clock.now_unix();
        let server_time = self.observed_server_time()?;
        let floor = self.floor(StateKey::PolicyFloor)?;
        match policy::admit_policy(
            bytes,
            now,
            server_time,
            &self.config.policy_keys,
            floor.as_ref(),
        ) {
            Ok(forward) => {
                self.persist_wire(
                    StateKey::PolicyWire,
                    StateKey::PolicyFloor,
                    bytes,
                    forward.version,
                    &forward.digest,
                    forward.idempotent,
                )?;
                self.remember_policy(&forward);
                Ok(forward)
            }
            Err(error) => {
                self.note_content_failure(EventKind::PrepareInvalid);
                Err(error.into())
            }
        }
    }

    /// Store a ticket as a secret. The returned view does not contain the bytes.
    pub fn install_ticket(&mut self, bytes: &[u8]) -> Result<TicketView, ClientError> {
        let now = self.ports.clock.now_unix();
        let floor = self.floor(StateKey::TicketFloor)?;
        let device = self.device.as_ref().map(|device| device.device_id);
        match ticket::admit_ticket(
            bytes,
            now,
            self.config.ticket_refresh_margin_secs,
            &self.config.ticket_keys,
            floor.as_ref(),
            device,
        ) {
            Ok(admitted) => {
                self.persist_wire(
                    StateKey::TicketWire,
                    StateKey::TicketFloor,
                    bytes,
                    admitted.view.not_after,
                    &admitted.digest,
                    admitted.view.idempotent,
                )?;
                self.ticket = Some(Secret::new(bytes));
                self.ticket_view = Some(admitted.view.clone());
                Ok(admitted.view)
            }
            Err(error) => {
                self.note_content_failure(EventKind::PrepareInvalid);
                Err(error.into())
            }
        }
    }

    /// Reload the cache and re-check signatures. Missing keys are fine.
    /// An expired catalog is dropped from memory; its revision floor stays.
    pub fn load_cached(&mut self) -> Result<(), ClientError> {
        self.server_time = self.observed_server_time()?;
        self.load_catalog_cache()?;
        self.load_policy_cache()?;
        self.load_ticket_cache()?;
        Ok(())
    }

    /// Record a control-plane `Date`. The value only moves forward.
    pub fn note_server_date(&mut self, unix: u64) -> Result<(), ClientError> {
        let current = self.observed_server_time()?;
        if unix <= current {
            return Ok(());
        }
        persist::write_unix(&self.ports.state, StateKey::ServerTime, unix).map_err(persist_err)?;
        self.server_time = unix;
        Ok(())
    }

    /// Keep the access token in memory and the refresh token in the credential store.
    pub fn set_session(&mut self, session: AccountSession) -> Result<(), ClientError> {
        session.persist_refresh_token(&self.ports.credentials)?;
        self.session = Some(session);
        Ok(())
    }

    pub fn set_device(&mut self, device: Device) -> Result<(), ClientError> {
        let checked = Device::new(
            device.device_id,
            device.name,
            device.platform,
            device.install_id,
        )?;
        let secret = Secret::new(checked.device_id.to_string().as_bytes());
        self.ports
            .credentials
            .set(CredentialKey::DeviceId, &secret)?;
        self.device = Some(checked);
        Ok(())
    }

    /// Apply an account response. Holds keep tokens and do not disarm.
    /// A session end deletes the refresh token and still does not disarm.
    pub fn note_account_failure(&mut self, failure: AccountFailure) -> Result<(), ClientError> {
        match failure {
            AccountFailure::SessionEnded => {
                self.session = None;
                self.ports.credentials.delete(CredentialKey::RefreshToken)?;
                self.note_content_failure(EventKind::CredentialRevoked);
            }
            AccountFailure::PlanExpired | AccountFailure::QuotaExhausted => {
                if let Some(session) = &mut self.session {
                    if let Some(entitlement) = failure.entitlement() {
                        session.set_entitlement(entitlement);
                    }
                }
                self.note_content_failure(EventKind::AccountHold);
            }
        }
        Ok(())
    }

    pub fn installed_catalog(&self) -> Option<&CatalogInstall> {
        self.catalog.as_ref()
    }

    /// Exact policy envelope for the data plane. `None` until one is installed
    /// or loaded. Not a parsed rule table.
    pub fn policy_forward_bytes(&self) -> Option<&[u8]> {
        self.policy_held.as_ref().map(|held| held.bytes.as_slice())
    }

    /// Ticket bytes for the kernel's `ticket_file`. The binding writes them
    /// mode `0600`. Do not log the slice.
    pub fn ticket_file_bytes(&self) -> Option<&[u8]> {
        self.ticket.as_ref().map(Secret::expose)
    }

    pub fn ticket_view(&self) -> Option<TicketView> {
        self.ticket_view.clone().map(|view| {
            view.at(
                self.ports.clock.now_unix(),
                self.config.ticket_refresh_margin_secs,
            )
        })
    }

    pub fn session(&self) -> Option<&AccountSession> {
        self.session.as_ref()
    }

    pub fn http(&self) -> &H {
        &self.ports.http
    }

    pub fn credentials(&self) -> &S {
        &self.ports.credentials
    }

    pub fn prepare(&mut self, input: &PrepareInput) -> Result<KernelPlan, ClientError> {
        let plan = match plan::prepare(input) {
            Ok(plan) => plan,
            Err(error) => {
                if self.fsm.phase() == Phase::Preparing {
                    let _ = self.dispatch(Event::bare(EventKind::PrepareInvalid));
                }
                return Err(error.into());
            }
        };
        self.plan = Some(plan.clone());
        if self.fsm.phase() == Phase::Preparing {
            self.dispatch(Event::bare(EventKind::PrepareOk))?;
        }
        Ok(plan)
    }

    /// Start a connect. If [`Self::prepare`] already stored a plan, arming
    /// follows immediately. Otherwise the phase stays [`Phase::Preparing`]
    /// until `prepare` succeeds.
    pub fn connect(&mut self) -> Result<(), ClientError> {
        self.now_ms = self.ports.clock.monotonic_ms();
        self.dispatch(Event::bare(EventKind::UserConnect))?;
        if self.plan.is_some() && self.fsm.phase() == Phase::Preparing {
            self.dispatch(Event::bare(EventKind::PrepareOk))?;
        }
        Ok(())
    }

    pub fn disconnect(&mut self, intent: DisarmIntent) -> Result<(), ClientError> {
        self.now_ms = self.ports.clock.monotonic_ms();
        let kind = match intent {
            DisarmIntent::UserDisconnect => EventKind::UserDisconnect,
            DisarmIntent::SignOut => EventKind::SignOut,
            DisarmIntent::Quit => EventKind::Quit,
        };
        self.dispatch(Event::bare(kind))
    }

    pub fn sign_out(&mut self) -> Result<(), ClientError> {
        self.disconnect(DisarmIntent::SignOut)
    }

    pub fn quit(&mut self) -> Result<(), ClientError> {
        self.disconnect(DisarmIntent::Quit)
    }

    /// Record an exit choice. Does not arm, disarm, or change phase.
    pub fn select_exit(&mut self, choice: ExitChoice) -> Result<(), ClientError> {
        self.exit_choice = choice;
        Ok(())
    }

    /// Feed a protector or kernel observation. Generation-stamped events that
    /// do not match the current attempt are refused.
    pub fn push(&mut self, event: Event) -> Result<(), ClientError> {
        self.now_ms = self.ports.clock.monotonic_ms();
        self.dispatch(event)
    }

    pub fn tick(&mut self, now_ms: u64) -> Result<(), ClientError> {
        self.now_ms = now_ms;
        let effects = self.fsm.tick(now_ms);
        self.run_effects(effects)
    }

    pub fn status(&self) -> ClientStatus {
        let mut status = self.fsm.status();
        status.exit_choice = self.exit_choice.clone();
        status.current_exit = self.current_exit.clone();
        status.exits = self.exits.clone();
        status.policy = self.live_policy_view();
        status
    }

    pub fn poll_event(&mut self) -> Option<ClientEvent> {
        self.events.pop_front()
    }

    pub fn take_effects(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.effects)
    }

    fn note_content_failure(&mut self, kind: EventKind) {
        let phase = self.fsm.phase();
        let account = matches!(kind, EventKind::AccountHold | EventKind::CredentialRevoked);
        if phase == Phase::Off && !account {
            return;
        }
        if kind == EventKind::PrepareInvalid && phase != Phase::Preparing {
            return;
        }
        let _ = self.dispatch(Event::bare(kind));
    }

    fn persist_wire(
        &self,
        wire: StateKey,
        floor_key: StateKey,
        bytes: &[u8],
        sequence: u64,
        digest: &str,
        idempotent: bool,
    ) -> Result<(), ClientError> {
        let missing = self.ports.state.get(wire)?.is_none();
        if !idempotent || missing {
            self.ports.state.put(wire, bytes)?;
        }
        if !idempotent {
            persist::write_floor(
                &self.ports.state,
                floor_key,
                &SequenceFloor {
                    sequence,
                    digest: digest.to_owned(),
                },
            )
            .map_err(persist_err)?;
        }
        Ok(())
    }

    fn floor(&self, key: StateKey) -> Result<Option<SequenceFloor>, ClientError> {
        persist::read_floor(&self.ports.state, key).map_err(persist_err)
    }

    fn observed_server_time(&mut self) -> Result<u64, ClientError> {
        let stored =
            persist::read_unix(&self.ports.state, StateKey::ServerTime).map_err(persist_err)?;
        if stored > self.server_time {
            self.server_time = stored;
        }
        Ok(self.server_time)
    }

    fn remember_policy(&mut self, forward: &PolicyForward) {
        self.config.policy_version = forward.version;
        self.policy_held = Some(HeldPolicy {
            version: forward.version,
            expires_at: forward.expires_at,
            bytes: forward.bytes.clone(),
        });
        self.policy = self.live_policy_view();
    }

    fn live_policy_view(&self) -> PolicyView {
        let Some(held) = &self.policy_held else {
            return PolicyView::default();
        };
        let now = self.ports.clock.now_unix();
        let basis = policy::expiry_basis(now, self.server_time);
        PolicyView {
            valid: basis < held.expires_at,
            version: Some(held.version),
            expires_at: Some(held.expires_at),
        }
    }

    fn load_catalog_cache(&mut self) -> Result<(), ClientError> {
        let Some(wire) = self.ports.state.get(StateKey::CatalogWire)? else {
            return Ok(());
        };
        let now = self.ports.clock.now_unix();
        let floor = self.floor(StateKey::CatalogFloor)?;
        match catalog::admit_catalog(&wire, now, &self.config.catalog_keys, floor.as_ref()) {
            Ok(install) => {
                if !install.idempotent {
                    persist::write_floor(
                        &self.ports.state,
                        StateKey::CatalogFloor,
                        &SequenceFloor {
                            sequence: install.revision,
                            digest: install.digest.clone(),
                        },
                    )
                    .map_err(persist_err)?;
                }
                self.config.anchor_revision = install.revision;
                self.exits = install.exits.clone();
                self.catalog = Some(install);
                Ok(())
            }
            Err(CatalogError::Expired) => {
                self.catalog = None;
                self.exits.clear();
                Ok(())
            }
            Err(error) => Err(error.into()),
        }
    }

    fn load_policy_cache(&mut self) -> Result<(), ClientError> {
        let Some(wire) = self.ports.state.get(StateKey::PolicyWire)? else {
            return Ok(());
        };
        let now = self.ports.clock.now_unix();
        let server_time = self.server_time;
        let floor = self.floor(StateKey::PolicyFloor)?;
        let inspected = policy::inspect_policy(&wire, now, server_time, &self.config.policy_keys)?;
        if let Some(known) = &floor {
            if inspected.version < known.sequence {
                return Ok(());
            }
            if inspected.version == known.sequence && inspected.digest != known.digest {
                return Err(ClientError::Floor);
            }
        }
        if floor.as_ref().map(|known| known.sequence).unwrap_or(0) < inspected.version {
            persist::write_floor(
                &self.ports.state,
                StateKey::PolicyFloor,
                &SequenceFloor {
                    sequence: inspected.version,
                    digest: inspected.digest.clone(),
                },
            )
            .map_err(persist_err)?;
        }
        self.remember_policy(&inspected);
        Ok(())
    }

    fn load_ticket_cache(&mut self) -> Result<(), ClientError> {
        let Some(wire) = self.ports.state.get(StateKey::TicketWire)? else {
            return Ok(());
        };
        let now = self.ports.clock.now_unix();
        let view = ticket::inspect_ticket(
            &wire,
            now,
            self.config.ticket_refresh_margin_secs,
            &self.config.ticket_keys,
        )?;
        let floor = self.floor(StateKey::TicketFloor)?;
        if let Some(known) = &floor {
            if view.not_after < known.sequence {
                return Ok(());
            }
            if view.not_after == known.sequence {
                let digest = crate::envelope::hex_sha256(&wire);
                if digest != known.digest {
                    return Err(ClientError::Floor);
                }
            }
        }
        self.ticket = Some(Secret::new(&wire));
        self.ticket_view = Some(view);
        Ok(())
    }

    fn dispatch(&mut self, event: Event) -> Result<(), ClientError> {
        let mut queue = VecDeque::new();
        queue.push_back((event, true));
        while let Some((event, external)) = queue.pop_front() {
            let before = self.fsm.status();
            let step = self
                .fsm
                .apply(event, self.ports.clock.now_unix(), self.now_ms);
            if !step.accepted {
                if external {
                    return Err(ClientError::Rejected);
                }
                continue;
            }
            self.note_transition(&before);
            let follow = self.follow_ups(&step)?;
            for next in follow {
                queue.push_back((next, false));
            }
        }
        Ok(())
    }

    fn run_effects(&mut self, effects: Vec<Effect>) -> Result<(), ClientError> {
        let mut queue = VecDeque::new();
        for effect in effects {
            self.effects.push(effect.clone());
            if let Some(next) = self.execute(effect)? {
                queue.push_back(next);
            }
        }
        while let Some(event) = queue.pop_front() {
            self.dispatch(event)?;
        }
        Ok(())
    }

    fn follow_ups(&mut self, step: &Step) -> Result<Vec<Event>, ClientError> {
        let mut follow = Vec::new();
        for effect in &step.effects {
            self.effects.push(effect.clone());
            if matches!(effect, Effect::ReleaseOrdinaryTraffic { .. }) {
                self.events.push_back(ClientEvent::OrdinaryTrafficReleased {
                    generation: self.fsm.generation(),
                });
            }
            if let Some(next) = self.execute(effect.clone())? {
                follow.push(next);
            }
        }
        Ok(follow)
    }

    fn execute(&mut self, effect: Effect) -> Result<Option<Event>, ClientError> {
        let next = match effect {
            Effect::PersistArmIntent { .. }
            | Effect::ScheduleArmRetry { .. }
            | Effect::ScheduleBackoff { .. }
            | Effect::ScheduleDisarmRetry { .. } => None,
            Effect::Arm { generation, strict } | Effect::RetryArm { generation, strict } => {
                let request = self.arm_request(generation, strict);
                match self.ports.protector.arm(&request) {
                    Ok(_) => Some(Event::bare(EventKind::ArmAck)),
                    Err(_) => Some(Event::bare(EventKind::ArmError)),
                }
            }
            Effect::SetUserEnabled { enabled, .. } => {
                if self.ports.data_plane.set_user_enabled(enabled).is_err() {
                    Some(Event::bare(EventKind::PostureError))
                } else {
                    None
                }
            }
            Effect::Probe { .. } => match self.ports.data_plane.probe() {
                Ok(ProbeResult::Ready) => None,
                Ok(ProbeResult::Down) | Err(_) => Some(Event::bare(EventKind::ProbeFail)),
            },
            Effect::ReleaseOrdinaryTraffic { .. } => {
                let _ = self.ports.data_plane.release_ordinary();
                None
            }
            Effect::DisconnectDataPlane { intent, .. } => {
                let _ = self.ports.data_plane.disconnect(intent);
                None
            }
            Effect::Disarm { generation, intent } | Effect::RetryDisarm { generation, intent } => {
                let request = DisarmRequest {
                    schema_version: 1,
                    generation,
                    intent,
                };
                match self.ports.protector.disarm(&request) {
                    Ok(_) => Some(Event::bare(EventKind::DisarmAck)),
                    Err(_) => Some(Event::bare(EventKind::DisarmNoAck)),
                }
            }
        };
        Ok(next)
    }

    fn arm_request(&self, generation: u64, strict: bool) -> ArmRequest {
        ArmRequest {
            schema_version: 1,
            generation,
            intent: ArmIntent::UserConnect,
            anchor_revision: self.config.anchor_revision,
            manifest_digest: self
                .plan
                .as_ref()
                .map(|plan| plan.digest.clone())
                .unwrap_or_default(),
            egress: self.config.egress.clone(),
            exit_ifaces: self.config.exit_ifaces.clone(),
            strict,
            evidence: ArmEvidence {
                policy_version: self.config.policy_version,
                posture: "connecting".to_owned(),
            },
        }
    }

    fn note_transition(&mut self, before: &ClientStatus) {
        let after = self.fsm.status();
        if before.phase != after.phase {
            self.events.push_back(ClientEvent::PhaseChanged {
                from: before.phase,
                to: after.phase,
                generation: after.generation,
            });
        }
        let before_kind = before.intent.as_ref().map(|intent| intent.kind);
        if let Some(intent) = &after.intent {
            if before_kind != Some(intent.kind) || before.generation != after.generation {
                self.events.push_back(ClientEvent::IntentRecorded {
                    kind: intent.kind,
                    generation: intent.generation,
                    at: intent.at,
                });
            }
        }
        if after.phase == Phase::Connected && before.phase != Phase::Connected {
            self.events.push_back(ClientEvent::Connected {
                generation: after.generation,
                at: after.connected_at.unwrap_or(0),
            });
        }
        match (&before.failure, &after.failure) {
            (None, Some(failure)) => {
                self.events.push_back(ClientEvent::FailureRecorded {
                    code: failure.code,
                    generation: after.generation,
                });
            }
            (Some(_), None) => {
                self.events.push_back(ClientEvent::FailureCleared {
                    generation: after.generation,
                });
            }
            (Some(left), Some(right)) if left.code != right.code => {
                self.events.push_back(ClientEvent::FailureRecorded {
                    code: right.code,
                    generation: after.generation,
                });
            }
            _ => {}
        }
        if before.user_copy != after.user_copy {
            self.events.push_back(ClientEvent::CopyChanged {
                user_copy: after.user_copy,
            });
        }
    }
}

fn persist_err(error: PersistError) -> ClientError {
    match error {
        PersistError::Store(store) => ClientError::State(store),
        PersistError::Corrupt => ClientError::Floor,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::account::{AccountSession, Device, Entitlement, Platform};
    use crate::keys::TrustedKey;
    use crate::plan::{CatalogNode, PolicyKeyRef};
    use crate::ports::{
        Ack, ApiRequest, ApiResponse, ArmAck, CredentialError, CredentialKey, DataPlaneError,
        ProtectorError, ProtectorEvidence, ProtectorStatus, Secret, StateKey, StateStore,
        StoreError, TransportError,
    };
    use crate::seal;
    use std::cell::{Cell, RefCell};
    use std::collections::BTreeMap;
    use std::rc::Rc;

    struct Inner {
        arms: Cell<u32>,
        disarms: RefCell<Vec<DisarmIntent>>,
        disconnects: RefCell<Vec<DisarmIntent>>,
        releases: Cell<u32>,
        fail_arm: Cell<bool>,
        fail_disarm: Cell<bool>,
        probe: Cell<ProbeResult>,
        unix: Cell<u64>,
        mono: Cell<u64>,
        state: RefCell<BTreeMap<StateKey, Vec<u8>>>,
        refresh: RefCell<Option<Vec<u8>>>,
    }

    #[derive(Clone)]
    struct Fake(Rc<Inner>);

    impl Fake {
        fn new() -> Self {
            Self(Rc::new(Inner {
                arms: Cell::new(0),
                disarms: RefCell::new(Vec::new()),
                disconnects: RefCell::new(Vec::new()),
                releases: Cell::new(0),
                fail_arm: Cell::new(false),
                fail_disarm: Cell::new(false),
                probe: Cell::new(ProbeResult::Ready),
                unix: Cell::new(1_700_000_000),
                mono: Cell::new(0),
                state: RefCell::new(BTreeMap::new()),
                refresh: RefCell::new(None),
            }))
        }
    }

    impl HttpTransport for Fake {
        fn send(&self, _req: &ApiRequest) -> Result<ApiResponse, TransportError> {
            Err(TransportError::Unavailable)
        }
    }

    impl CredentialStore for Fake {
        fn get(&self, key: CredentialKey) -> Result<Option<Secret>, CredentialError> {
            match key {
                CredentialKey::RefreshToken => {
                    Ok(self.0.refresh.borrow().as_ref().map(Secret::new))
                }
                CredentialKey::DeviceId => Ok(None),
            }
        }
        fn set(&self, key: CredentialKey, value: &Secret) -> Result<(), CredentialError> {
            if key == CredentialKey::RefreshToken {
                *self.0.refresh.borrow_mut() = Some(value.expose().to_vec());
            }
            Ok(())
        }
        fn delete(&self, key: CredentialKey) -> Result<(), CredentialError> {
            if key == CredentialKey::RefreshToken {
                *self.0.refresh.borrow_mut() = None;
            }
            Ok(())
        }
    }

    impl StateStore for Fake {
        fn get(&self, key: StateKey) -> Result<Option<Vec<u8>>, StoreError> {
            Ok(self.0.state.borrow().get(&key).cloned())
        }
        fn put(&self, key: StateKey, bytes: &[u8]) -> Result<(), StoreError> {
            self.0.state.borrow_mut().insert(key, bytes.to_vec());
            Ok(())
        }
        fn delete(&self, key: StateKey) -> Result<(), StoreError> {
            self.0.state.borrow_mut().remove(&key);
            Ok(())
        }
    }

    impl DataPlane for Fake {
        fn apply(&self, _plan: &KernelPlan) -> Result<(), DataPlaneError> {
            Ok(())
        }
        fn set_user_enabled(&self, _enabled: bool) -> Result<(), DataPlaneError> {
            Ok(())
        }
        fn probe(&self) -> Result<ProbeResult, DataPlaneError> {
            Ok(self.0.probe.get())
        }
        fn disconnect(&self, intent: DisarmIntent) -> Result<(), DataPlaneError> {
            self.0.disconnects.borrow_mut().push(intent);
            Ok(())
        }
        fn release_ordinary(&self) -> Result<(), DataPlaneError> {
            self.0.releases.set(self.0.releases.get() + 1);
            Ok(())
        }
    }

    impl Protector for Fake {
        fn arm(&self, req: &ArmRequest) -> Result<ArmAck, ProtectorError> {
            assert_eq!(req.intent, ArmIntent::UserConnect);
            assert!(!req.strict);
            assert_eq!(req.schema_version, 1);
            self.0.arms.set(self.0.arms.get() + 1);
            if self.0.fail_arm.get() {
                return Err(ProtectorError::Refused);
            }
            Ok(ArmAck {
                generation: req.generation,
                rules_digest: "rules".to_owned(),
            })
        }
        fn disarm(&self, req: &DisarmRequest) -> Result<Ack, ProtectorError> {
            self.0.disarms.borrow_mut().push(req.intent);
            if self.0.fail_disarm.get() {
                return Err(ProtectorError::Unavailable);
            }
            Ok(Ack {
                generation: req.generation,
            })
        }
        fn status(&self) -> ProtectorStatus {
            ProtectorStatus {
                armed: false,
                generation: 0,
                held: false,
                rules_digest: String::new(),
                evidence: ProtectorEvidence {
                    tcp_proof_ms: None,
                    dns_readback: false,
                },
                last_error: None,
            }
        }
    }

    impl Clock for Fake {
        fn now_unix(&self) -> u64 {
            self.0.unix.get()
        }
        fn monotonic_ms(&self) -> u64 {
            self.0.mono.get()
        }
    }

    fn client(fake: &Fake) -> Client<Fake, Fake, Fake, Fake, Fake, Fake> {
        Client::new(
            ClientConfig::default(),
            Ports {
                http: fake.clone(),
                credentials: fake.clone(),
                data_plane: fake.clone(),
                protector: fake.clone(),
                clock: fake.clone(),
                state: fake.clone(),
            },
        )
        .unwrap()
    }

    fn sample_input() -> PrepareInput {
        PrepareInput {
            listen: "127.0.0.1:1080".to_owned(),
            dns_listen: "127.0.0.1:5353".to_owned(),
            dns_domestic: vec!["223.5.5.5:53".to_owned()],
            nodes: vec![CatalogNode {
                name: "la-1".to_owned(),
                outbound: serde_json::json!({"protocol": "vless", "settings": {"address": "203.0.113.10", "port": 443}}),
                relay: "203.0.113.10:7443".to_owned(),
                node_id: 12,
                egress_group: Some("us-west".to_owned()),
                roles: vec!["overseas".to_owned()],
            }],
            policy_bundle_path: "policy.bundle".to_owned(),
            policy_installed_path: "policy.installed".to_owned(),
            public_keys: vec![PolicyKeyRef {
                key_id: 1,
                public_key: "AQIDBA==".to_owned(),
            }],
            ticket_path: "device.ticket".to_owned(),
            ai_route: "ai".to_owned(),
            control_listen: None,
            control_token_file: None,
            fake_ip_state: "fakeip.state".to_owned(),
        }
    }

    #[test]
    fn connect_arms_once_and_a_lost_arm_reply_does_not_disarm() {
        let fake = Fake::new();
        fake.0.fail_arm.set(true);
        let mut client = client(&fake);
        client.prepare(&sample_input()).unwrap();
        client.connect().unwrap();
        assert_eq!(client.status().phase, Phase::Arming);
        assert!(client.status().protection.armed);
        assert_eq!(fake.0.arms.get(), 1);
        assert!(fake.0.disarms.borrow().is_empty());
        assert!(fake.0.disconnects.borrow().is_empty());
        let rendered = serde_json::to_string(&client.status()).unwrap();
        assert!(!rendered.contains("SGT1."));
        assert!(!rendered.contains("device.ticket"));
    }

    #[test]
    fn an_acked_arm_reaches_connecting_without_showing_connected() {
        let fake = Fake::new();
        let mut client = client(&fake);
        client.prepare(&sample_input()).unwrap();
        client.connect().unwrap();
        assert_eq!(client.status().phase, Phase::Connecting);
        assert!(!client.status().shows_connected());
        assert_eq!(fake.0.arms.get(), 1);
        assert!(fake.0.disarms.borrow().is_empty());
    }

    #[test]
    fn only_the_three_release_methods_disarm() {
        let fake = Fake::new();
        let mut client = client(&fake);
        client.prepare(&sample_input()).unwrap();
        client.connect().unwrap();
        client
            .push(Event::bare(EventKind::PostureConnected))
            .unwrap();
        client.push(Event::bare(EventKind::ExitEvidence)).unwrap();
        client
            .push(Event::bare(EventKind::AiRouteEvidence))
            .unwrap();
        assert!(client.status().shows_connected());
        client
            .select_exit(ExitChoice::Named("la-1".to_owned()))
            .unwrap();
        assert!(fake.0.disarms.borrow().is_empty());
        client.push(Event::bare(EventKind::CarrierLost)).unwrap();
        client
            .push(Event::bare(EventKind::BudgetExhausted))
            .unwrap();
        assert_eq!(client.status().phase, Phase::ProtectedOffline);
        assert!(client.status().protection.held);
        assert!(!client.status().protection.tunnel_held);
        assert_eq!(fake.0.releases.get(), 1);
        assert!(fake.0.disarms.borrow().is_empty());

        client.disconnect(DisarmIntent::UserDisconnect).unwrap();
        assert_eq!(
            fake.0.disarms.borrow().as_slice(),
            &[DisarmIntent::UserDisconnect]
        );
        assert_eq!(client.status().phase, Phase::Off);
        assert!(!client.status().protection.armed);
    }

    #[test]
    fn a_lost_disarm_reply_stays_disarming() {
        let fake = Fake::new();
        fake.0.fail_disarm.set(true);
        let mut client = client(&fake);
        client.prepare(&sample_input()).unwrap();
        client.connect().unwrap();
        client.push(Event::bare(EventKind::PostureError)).unwrap();
        assert_eq!(client.status().phase, Phase::Failed);
        assert!(client.status().protection.armed);
        client.sign_out().unwrap();
        assert_eq!(client.status().phase, Phase::Disarming);
        assert_eq!(fake.0.disarms.borrow().as_slice(), &[DisarmIntent::SignOut]);
        assert!(client.status().failure.is_none());
        let pushed = client.push(Event::bare(EventKind::PostureError));
        assert_eq!(pushed, Err(ClientError::Rejected));
        assert_eq!(client.status().phase, Phase::Disarming);
    }

    fn trusted(fake: &Fake) -> Client<Fake, Fake, Fake, Fake, Fake, Fake> {
        let catalog_seed = seal::seed_from_label("client-catalog");
        let policy_seed = seal::seed_from_label("client-policy");
        let ticket_seed = seal::seed_from_label("client-ticket");
        let mut client = client(fake);
        client.config.catalog_keys = vec![TrustedKey {
            key_id: 1,
            public_key: seal::public_key(&catalog_seed),
        }];
        client.config.policy_keys = vec![TrustedKey {
            key_id: 1,
            public_key: seal::public_key(&policy_seed),
        }];
        client.config.ticket_keys = vec![TrustedKey {
            key_id: 1,
            public_key: seal::public_key(&ticket_seed),
        }];
        client.config.ticket_refresh_margin_secs = 60;
        client
    }

    fn catalog_doc(revision: u64, egress: bool) -> serde_json::Value {
        let mut node = serde_json::json!({
            "id": 12,
            "name": "la-1",
            "region": "us",
            "outbound": {"protocol": "vless", "settings": {"address": "203.0.113.10", "port": 443}},
            "relay": "198.51.100.4:7443",
            "node_id": 12,
            "roles": ["overseas"]
        });
        if egress {
            node["egress_group"] = serde_json::json!("us-west");
        }
        serde_json::json!({
            "schemaVersion": 1,
            "revision": revision,
            "issued_at": 1_700_000_000_u64,
            "expires_at": 1_800_000_000_u64,
            "ai_route": "ai",
            "nodes": [node]
        })
    }

    #[test]
    fn install_catalog_feeds_prepare_and_the_cache_rejects_rollback() {
        let fake = Fake::new();
        let mut client = trusted(&fake);
        let seed = seal::seed_from_label("client-catalog");
        let bytes = seal::catalog_document(&seed, 1, &catalog_doc(2, false));
        let installed = client.install_catalog(&bytes).unwrap();
        assert!(installed.nodes[0].egress_group.is_none());
        assert!(installed.exits[0].egress_group.is_none());
        let mut input = sample_input();
        input.nodes = installed.nodes.clone();
        input.ai_route = installed.ai_route.clone();
        let plan = client.prepare(&input).unwrap();
        assert!(!plan.config_json.contains("egress_group"));
        assert_eq!(client.status().exits[0].name, "la-1");

        let again = Client::new(
            ClientConfig {
                catalog_keys: client.config.catalog_keys.clone(),
                ..ClientConfig::default()
            },
            Ports {
                http: fake.clone(),
                credentials: fake.clone(),
                data_plane: fake.clone(),
                protector: fake.clone(),
                clock: fake.clone(),
                state: fake.clone(),
            },
        )
        .unwrap();
        let mut reloaded = again;
        reloaded.load_cached().unwrap();
        assert_eq!(
            reloaded.installed_catalog().unwrap().digest,
            installed.digest
        );

        let older = seal::catalog_document(&seed, 1, &catalog_doc(1, true));
        let error = client.install_catalog(&older).unwrap_err();
        assert!(matches!(
            error,
            ClientError::Catalog(crate::CatalogError::Rollback)
        ));
        assert_eq!(client.installed_catalog().unwrap().revision, 2);
        assert!(fake.0.disarms.borrow().is_empty());
    }

    #[test]
    fn policy_bytes_are_forwarded_and_server_time_blocks_a_stale_bundle() {
        let fake = Fake::new();
        let mut client = trusted(&fake);
        let seed = seal::seed_from_label("client-policy");
        let body = serde_json::json!({
            "version": 7,
            "expires_at": 1_800_000_000_u64,
            "rules": [{"note": "not parsed"}]
        });
        let bytes = seal::policy_document(&seed, 1, &body);
        let forward = client.install_policy(&bytes).unwrap();
        assert_eq!(client.policy_forward_bytes(), Some(bytes.as_slice()));
        assert_eq!(forward.bytes, bytes);
        assert!(client.status().policy.valid);
        assert_eq!(client.status().policy.version, Some(7));

        client.note_server_date(1_800_000_000).unwrap();
        let mut newer = body;
        newer["version"] = serde_json::json!(8);
        let rejected = client.install_policy(&seal::policy_document(&seed, 1, &newer));
        assert!(matches!(
            rejected.unwrap_err(),
            ClientError::Policy(crate::PolicyError::ServerTime)
        ));
        assert_eq!(client.policy_forward_bytes().unwrap(), bytes.as_slice());
        assert!(!client.status().policy.valid);
    }

    #[test]
    fn a_ticket_stays_out_of_status_and_an_account_hold_does_not_disarm() {
        let fake = Fake::new();
        let mut client = trusted(&fake);
        client
            .set_device(Device::new(9, "laptop", Platform::Macos, "install-1").unwrap())
            .unwrap();
        let seed = seal::seed_from_label("client-ticket");
        let claims = crate::canonical_json(&serde_json::json!({
            "v": 1,
            "key_id": 1,
            "device_id": 9,
            "account_id": 4,
            "plan": "plus",
            "exit_classes": ["overseas", "ai"],
            "ai_anchor_node_id": 12,
            "not_before": 1_700_000_000_u64,
            "not_after": 1_700_010_000_u64
        }));
        let bytes = seal::ticket(&seed, claims.as_bytes());
        let view = client.install_ticket(&bytes).unwrap();
        assert_eq!(view.device_id, 9);
        assert!(!view.expired);
        assert_eq!(client.ticket_file_bytes(), Some(bytes.as_slice()));
        let status = serde_json::to_string(&client.status()).unwrap();
        assert!(!status.contains("SGT1."));
        assert!(!format!("{view:?}").contains("SGT1."));

        let session = AccountSession::new(
            4,
            "plus",
            Entitlement::Active,
            b"access-secret",
            b"refresh-secret",
            1_800_000_000,
        )
        .unwrap();
        client.set_session(session).unwrap();
        client.prepare(&sample_input()).unwrap();
        client.connect().unwrap();
        client
            .note_account_failure(crate::AccountFailure::QuotaExhausted)
            .unwrap();
        assert_eq!(client.status().phase, Phase::Connecting);
        assert!(client.status().protection.armed);
        assert!(fake.0.disarms.borrow().is_empty());
        assert!(fake.0.refresh.borrow().is_some());
        client
            .note_account_failure(crate::AccountFailure::SessionEnded)
            .unwrap();
        assert!(client.session().is_none());
        assert!(fake.0.refresh.borrow().is_none());
        assert!(client.status().protection.armed);
        assert!(fake.0.disarms.borrow().is_empty());
    }
}
