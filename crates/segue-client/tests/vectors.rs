//! Replays `vectors/fsm` and `vectors/intent`. A shell row marked `todo` is
//! not a pass. `segue-client` rows are `enabled` and are asserted.

use std::fs;
use std::path::PathBuf;

use segue_client::{Effect, Event, EventKind, Fsm, ProtectionMode};
use serde::Deserialize;

#[derive(Deserialize)]
struct FsmFile {
    #[serde(rename = "fixtureVersion")]
    fixture_version: u32,
    cases: Vec<FsmCase>,
}

#[derive(Deserialize)]
struct FsmCase {
    id: String,
    #[serde(default)]
    mode: Option<String>,
    #[serde(default)]
    setup: Vec<Step>,
    event: Step,
    expect: Expect,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Step {
    Name(String),
    Obj {
        name: String,
        generation: Option<u64>,
    },
}

impl Step {
    fn name(&self) -> &str {
        match self {
            Step::Name(name) => name,
            Step::Obj { name, .. } => name,
        }
    }

    fn generation(&self) -> Option<u64> {
        match self {
            Step::Name(_) => None,
            Step::Obj { generation, .. } => *generation,
        }
    }
}

#[derive(Deserialize)]
struct Expect {
    phase: String,
    armed: bool,
    held: bool,
    shows_connected: bool,
    intent: Option<String>,
    disarm: bool,
    tunnel_held: bool,
    #[serde(default = "accepted_by_default")]
    accepted: bool,
    #[serde(default)]
    generation: Option<u64>,
    #[serde(default)]
    failure_written: Option<bool>,
}

fn accepted_by_default() -> bool {
    true
}

#[derive(Deserialize)]
struct IntentFile {
    #[serde(rename = "fixtureVersion")]
    fixture_version: u32,
    scenarios: Vec<Scenario>,
}

#[derive(Deserialize)]
struct Scenario {
    id: String,
    #[serde(default)]
    mode: Option<String>,
    steps: Vec<Step>,
    expect: IntentExpect,
    enforcement: std::collections::BTreeMap<String, String>,
}

#[derive(Deserialize)]
struct IntentExpect {
    phase: String,
    intent: Option<String>,
    armed: bool,
    held: bool,
    shows_connected: bool,
    tunnel_held: bool,
    failure_written: bool,
    disarm_steps: u64,
}

const REQUIRED_FSM: &[&str] = &[
    "off-user-connect",
    "failed-user-connect",
    "protected-offline-user-connect",
    "reconnect-after-disconnect",
    "preparing-invalid-never-verified",
    "preparing-invalid-after-verified",
    "preparing-cancel",
    "preparing-ok",
    "preparing-catalog-failure",
    "arming-ack",
    "arming-error",
    "arming-user-disconnect",
    "connecting-posture-connected",
    "connecting-error-never-verified",
    "connecting-error-verified",
    "verifying-exit-only",
    "verifying-ai-only",
    "verifying-becomes-connected",
    "verifying-ai-then-exit",
    "connected-carrier-lost",
    "connected-network-change",
    "protected-offline-probe-ok",
    "protected-offline-probe-fail",
    "connected-user-disconnect",
    "protected-offline-user-disconnect",
    "connected-sign-out",
    "connected-quit",
    "connecting-quit",
    "disarming-ack",
    "disarming-no-ack",
    "crash-from-connected",
    "crash-from-disarming",
    "crash-from-off",
    "budget-exhausted-ai-only",
    "budget-exhausted-strict",
    "connected-timeout",
    "connected-catalog-failure",
    "connected-update-failed",
    "connected-account-hold",
    "connected-credential-revoked",
    "late-posture-after-disconnect",
    "stale-generation-ignored",
    "off-arm-ack-rejected",
];

fn counts_as_pass(enforcement: &str) -> bool {
    enforcement == "enabled"
}

#[test]
fn fsm_vectors_cover_the_table() {
    let mut seen = Vec::new();
    for path in json_files("fsm") {
        let file: FsmFile = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(file.fixture_version, 1, "{}", path.display());
        for case in file.cases {
            let (status_bits, accepted, disarm, history) =
                run_case(&case.mode, &case.setup, Some(&case.event));
            assert_release_history(&case.id, &history);
            assert_eq!(accepted, case.expect.accepted, "{}", case.id);
            assert_eq!(status_bits.phase, case.expect.phase, "{}", case.id);
            assert_eq!(status_bits.armed, case.expect.armed, "{}", case.id);
            assert_eq!(status_bits.held, case.expect.held, "{}", case.id);
            assert_eq!(
                status_bits.shows_connected, case.expect.shows_connected,
                "{}",
                case.id
            );
            assert_eq!(status_bits.intent, case.expect.intent, "{}", case.id);
            assert_eq!(
                status_bits.tunnel_held, case.expect.tunnel_held,
                "{}",
                case.id
            );
            assert_eq!(disarm, case.expect.disarm, "{}", case.id);
            if let Some(generation) = case.expect.generation {
                assert_eq!(status_bits.generation, generation, "{}", case.id);
            }
            if let Some(failure) = case.expect.failure_written {
                assert_eq!(status_bits.failure_written, failure, "{}", case.id);
            }
            seen.push(case.id);
        }
    }
    for id in REQUIRED_FSM {
        assert!(seen.iter().any(|seen| seen == id), "missing fsm case {id}");
    }
}

#[test]
fn intent_vectors_assert_enabled_rows_and_do_not_count_todo_as_a_pass() {
    assert!(!counts_as_pass("todo"));
    assert!(!counts_as_pass("expected-failure"));
    assert!(counts_as_pass("enabled"));

    let mut checked = 0_u32;
    let mut shell_todos = 0_u32;
    let mut shell_passes = 0_u32;
    for path in json_files("intent") {
        let file: IntentFile = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(file.fixture_version, 1);
        for scenario in file.scenarios {
            let crate_flag = scenario
                .enforcement
                .get("segue-client")
                .expect("segue-client enforcement")
                .as_str();
            assert_eq!(crate_flag, "enabled", "{}", scenario.id);
            assert!(
                counts_as_pass(crate_flag),
                "todo is not a pass for {}",
                scenario.id
            );
            let (bits, history) = replay(&scenario.mode, &scenario.steps);
            assert_release_history(&scenario.id, &history);
            assert_eq!(bits.phase, scenario.expect.phase, "{}", scenario.id);
            assert_eq!(bits.intent, scenario.expect.intent, "{}", scenario.id);
            assert_eq!(bits.armed, scenario.expect.armed, "{}", scenario.id);
            assert_eq!(bits.held, scenario.expect.held, "{}", scenario.id);
            assert_eq!(
                bits.shows_connected, scenario.expect.shows_connected,
                "{}",
                scenario.id
            );
            assert_eq!(
                bits.tunnel_held, scenario.expect.tunnel_held,
                "{}",
                scenario.id
            );
            assert_eq!(
                bits.failure_written, scenario.expect.failure_written,
                "{}",
                scenario.id
            );
            let disarm_steps = history
                .iter()
                .filter(|(_, effects)| effects.iter().any(Effect::is_fresh_release))
                .count() as u64;
            assert_eq!(
                disarm_steps, scenario.expect.disarm_steps,
                "{}",
                scenario.id
            );
            checked += 1;
            for (shell, flag) in &scenario.enforcement {
                if shell == "segue-client" {
                    continue;
                }
                if flag == "todo" {
                    shell_todos += 1;
                    assert!(!counts_as_pass(flag));
                } else if counts_as_pass(flag) {
                    shell_passes += 1;
                }
            }
        }
    }
    assert!(checked > 0);
    assert!(
        shell_todos > 0,
        "shell todos must be recorded and not treated as passes"
    );
    assert_eq!(
        shell_passes, 0,
        "no shell has an enabled probe in this crate"
    );
}

struct Bits {
    phase: String,
    armed: bool,
    held: bool,
    shows_connected: bool,
    intent: Option<String>,
    tunnel_held: bool,
    generation: u64,
    failure_written: bool,
}

fn replay(mode: &Option<String>, steps: &[Step]) -> (Bits, Vec<(String, Vec<Effect>)>) {
    let mut fsm = Fsm::new(parse_mode(mode.as_deref()));
    let mut history = Vec::new();
    for step in steps {
        let (_accepted, effects) = apply(&mut fsm, step);
        history.push((step.name().to_owned(), effects));
    }
    (bits_of(&fsm), history)
}

fn run_case(
    mode: &Option<String>,
    setup: &[Step],
    event: Option<&Step>,
) -> (Bits, bool, bool, Vec<(String, Vec<Effect>)>) {
    let mut fsm = Fsm::new(parse_mode(mode.as_deref()));
    let mut history = Vec::new();
    for step in setup {
        let (accepted, effects) = apply(&mut fsm, step);
        assert!(accepted, "setup step {} rejected", step.name());
        history.push((step.name().to_owned(), effects));
    }
    let (accepted, disarm, effects) = if let Some(event) = event {
        let (accepted, effects) = apply(&mut fsm, event);
        let disarm = effects.iter().any(Effect::is_fresh_release);
        history.push((event.name().to_owned(), effects));
        (accepted, disarm, history)
    } else {
        (true, false, history)
    };
    (bits_of(&fsm), accepted, disarm, effects)
}

fn bits_of(fsm: &Fsm) -> Bits {
    let status = fsm.status();
    Bits {
        phase: phase_name(status.phase),
        armed: status.protection.armed,
        held: status.protection.held,
        shows_connected: status.shows_connected(),
        intent: status.intent.map(|intent| intent_name(intent.kind)),
        tunnel_held: status.protection.tunnel_held,
        generation: status.generation,
        failure_written: status.failure.is_some(),
    }
}

fn apply(fsm: &mut Fsm, step: &Step) -> (bool, Vec<Effect>) {
    let event = Event {
        kind: parse_kind(step.name()),
        generation: step.generation(),
    };
    let step = fsm.apply(event, 1_700_000_000, 0);
    (step.accepted, step.effects)
}

fn assert_release_history(id: &str, history: &[(String, Vec<Effect>)]) {
    let mut released = false;
    for (name, effects) in history {
        for effect in effects {
            match effect {
                Effect::Disarm { .. } | Effect::DisconnectDataPlane { .. } => {
                    assert!(
                        matches!(name.as_str(), "user_disconnect" | "sign_out" | "quit"),
                        "{id}: {name} emitted {effect:?}"
                    );
                    released = true;
                }
                Effect::RetryDisarm { .. } => {
                    assert!(
                        released,
                        "{id}: {name} retried disarm without a user release"
                    );
                }
                Effect::ReleaseOrdinaryTraffic { .. } => {
                    assert!(
                        !matches!(name.as_str(), "user_disconnect" | "sign_out" | "quit"),
                        "{id}: a user release must not be the ordinary-traffic release"
                    );
                }
                _ => {}
            }
        }
    }
}

fn parse_mode(mode: Option<&str>) -> ProtectionMode {
    match mode {
        None | Some("ai_only") => ProtectionMode::AiOnly,
        Some("strict") => ProtectionMode::Strict,
        Some(other) => panic!("unknown mode {other}"),
    }
}

fn parse_kind(name: &str) -> EventKind {
    match name {
        "user_connect" => EventKind::UserConnect,
        "prepare_invalid" => EventKind::PrepareInvalid,
        "prepare_ok" => EventKind::PrepareOk,
        "arm_ack" => EventKind::ArmAck,
        "arm_error" => EventKind::ArmError,
        "posture_connected" => EventKind::PostureConnected,
        "posture_error" => EventKind::PostureError,
        "exit_evidence" => EventKind::ExitEvidence,
        "ai_route_evidence" => EventKind::AiRouteEvidence,
        "carrier_lost" | "network_change" => EventKind::CarrierLost,
        "probe_ok" => EventKind::ProbeOk,
        "probe_fail" => EventKind::ProbeFail,
        "user_disconnect" => EventKind::UserDisconnect,
        "sign_out" => EventKind::SignOut,
        "quit" => EventKind::Quit,
        "disarm_ack" => EventKind::DisarmAck,
        "disarm_no_ack" => EventKind::DisarmNoAck,
        "process_restart" | "crash" => EventKind::ProcessRestart,
        "budget_exhausted" => EventKind::BudgetExhausted,
        "catalog_failure" => EventKind::CatalogFailure,
        "update_failed" => EventKind::UpdateFailed,
        "account_hold" => EventKind::AccountHold,
        "credential_revoked" => EventKind::CredentialRevoked,
        "timeout" => EventKind::Timeout,
        other => panic!("unknown event {other}"),
    }
}

fn phase_name(phase: segue_client::Phase) -> String {
    match phase {
        segue_client::Phase::Off => "off",
        segue_client::Phase::Preparing => "preparing",
        segue_client::Phase::Arming => "arming",
        segue_client::Phase::Connecting => "connecting",
        segue_client::Phase::Verifying => "verifying",
        segue_client::Phase::Connected => "connected",
        segue_client::Phase::ProtectedOffline => "protected_offline",
        segue_client::Phase::Disarming => "disarming",
        segue_client::Phase::Failed => "failed",
    }
    .to_owned()
}

fn intent_name(kind: segue_client::IntentKind) -> String {
    match kind {
        segue_client::IntentKind::Connect => "connect",
        segue_client::IntentKind::UserDisconnect => "user_disconnect",
        segue_client::IntentKind::SignOut => "sign_out",
        segue_client::IntentKind::Quit => "quit",
    }
    .to_owned()
}

fn json_files(subdir: &str) -> Vec<PathBuf> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("vectors")
        .join(subdir);
    let mut files: Vec<_> = fs::read_dir(&root)
        .unwrap_or_else(|error| panic!("read {}: {error}", root.display()))
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("json"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no vectors in {}", root.display());
    files
}
