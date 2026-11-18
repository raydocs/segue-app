//! The shell-facing owner of the state machine and the five ports.
//!
//! `disconnect`, `sign_out`, and `quit` are the only methods that can ask the
//! protector to disarm or the data plane to disconnect. There is no
//! `release`. Port failures become state-machine events; they do not clear
//! the AI lock on their own.

use std::collections::VecDeque;

use crate::fsm::{Effect, Event, EventKind, Fsm, Step};
use crate::plan::{self, KernelPlan, PrepareInput};
use crate::ports::{
    ArmEvidence, ArmIntent, ArmRequest, Clock, CredentialStore, DataPlane, DisarmIntent,
    DisarmRequest, Egress, HttpTransport, ProbeResult, Protector,
};
use crate::status::{
    ClientEvent, ClientStatus, ExitChoice, ExitView, Phase, PolicyView, ProtectionMode,
};
use crate::PrepareError;

/// What the shell knows before the first catalog is loaded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientConfig {
    pub protection: ProtectionMode,
    pub anchor_revision: u64,
    pub exit_ifaces: Vec<String>,
    pub egress: Vec<Egress>,
    pub policy_version: u64,
}

impl Default for ClientConfig {
    fn default() -> Self {
        Self {
            protection: ProtectionMode::AiOnly,
            anchor_revision: 0,
            exit_ifaces: Vec::new(),
            egress: Vec::new(),
            policy_version: 0,
        }
    }
}

pub struct Ports<H, S, D, P, C> {
    pub http: H,
    pub credentials: S,
    pub data_plane: D,
    pub protector: P,
    pub clock: C,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ClientError {
    #[error("that transition is not allowed")]
    Rejected,
    #[error(transparent)]
    Prepare(#[from] PrepareError),
}

pub struct Client<H, S, D, P, C> {
    fsm: Fsm,
    ports: Ports<H, S, D, P, C>,
    config: ClientConfig,
    plan: Option<KernelPlan>,
    events: VecDeque<ClientEvent>,
    effects: Vec<Effect>,
    now_ms: u64,
    exit_choice: ExitChoice,
    current_exit: Option<String>,
    exits: Vec<ExitView>,
    policy: PolicyView,
}

impl<H, S, D, P, C> Client<H, S, D, P, C>
where
    H: HttpTransport,
    S: CredentialStore,
    D: DataPlane,
    P: Protector,
    C: Clock,
{
    pub fn new(config: ClientConfig, ports: Ports<H, S, D, P, C>) -> Result<Self, ClientError> {
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
        })
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
        status.policy = self.policy.clone();
        status
    }

    pub fn poll_event(&mut self) -> Option<ClientEvent> {
        self.events.pop_front()
    }

    pub fn take_effects(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.effects)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plan::{CatalogNode, PolicyKeyRef};
    use crate::ports::{
        Ack, ApiRequest, ApiResponse, ArmAck, CredentialError, CredentialKey, DataPlaneError,
        ProtectorError, ProtectorEvidence, ProtectorStatus, Secret, TransportError,
    };
    use std::cell::{Cell, RefCell};
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
            }))
        }
    }

    impl HttpTransport for Fake {
        fn send(&self, _req: &ApiRequest) -> Result<ApiResponse, TransportError> {
            Err(TransportError::Unavailable)
        }
    }

    impl CredentialStore for Fake {
        fn get(&self, _key: CredentialKey) -> Result<Option<Secret>, CredentialError> {
            Ok(None)
        }
        fn set(&self, _key: CredentialKey, _value: &Secret) -> Result<(), CredentialError> {
            Ok(())
        }
        fn delete(&self, _key: CredentialKey) -> Result<(), CredentialError> {
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

    fn client(fake: &Fake) -> Client<Fake, Fake, Fake, Fake, Fake> {
        Client::new(
            ClientConfig::default(),
            Ports {
                http: fake.clone(),
                credentials: fake.clone(),
                data_plane: fake.clone(),
                protector: fake.clone(),
                clock: fake.clone(),
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
}
