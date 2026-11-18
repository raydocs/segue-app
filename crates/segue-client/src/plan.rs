//! `prepare`: admitted catalog nodes, policy key refs, and ticket *paths*
//! become one kernel config.
//!
//! Pure and total. The same [`PrepareInput`] always yields the same bytes.
//! Ticket and bundle bytes are not inputs, so they cannot leak into the plan
//! JSON or into an error string. The shell writes those files; this function
//! only names them.
//!
//! The document is what `segue-kernel` accepts in product mode: `listen`,
//! `outbounds`, `exits`, `segue` routes, `policy`, `dns`, `udp`, optional
//! `control` and `sniff`. There is no inline `rules` or `default`. An absent
//! `egress_group` is omitted, so the kernel treats that exit as its own group.
//! This function does not restate the pin rule.

use std::collections::BTreeSet;
use std::net::{IpAddr, SocketAddr};

use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use crate::error::PrepareError;

/// Hard cap from the catalog admission rule. Enforced here so a plan cannot
/// outgrow it while admission lives in a later stage.
const MAX_NODES: usize = 200;

const RESERVED_NAMES: &[&str] = &["auto", "direct", "reject", "block", "proxy", "overseas"];

const FORBIDDEN_OUTBOUND_KEYS: &[&str] = &[
    "skip-cert-verify",
    "skip_cert_verify",
    "skipCertVerify",
    "allowInsecure",
    "allow_insecure",
    "insecure",
    "danger_accept_invalid_certs",
];

/// One already-admitted node. Admission (digest, revision, reserved names in
/// the catalog's own grammar) is a later stage; [`prepare`] checks only what
/// the kernel config will reject.
#[derive(Debug, Clone, PartialEq)]
pub struct CatalogNode {
    pub name: String,
    pub outbound: Value,
    pub relay: String,
    pub node_id: u64,
    pub egress_group: Option<String>,
    pub roles: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PolicyKeyRef {
    pub key_id: u32,
    /// Base64 text of a public key. Not verified here; the kernel verifies.
    pub public_key: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PrepareInput {
    pub listen: String,
    pub dns_listen: String,
    pub dns_domestic: Vec<String>,
    pub nodes: Vec<CatalogNode>,
    pub policy_bundle_path: String,
    pub policy_installed_path: String,
    pub public_keys: Vec<PolicyKeyRef>,
    pub ticket_path: String,
    /// Segue route tag for AI traffic. Also written as `policy.ai_route`.
    pub ai_route: String,
    pub control_listen: Option<String>,
    pub control_token_file: Option<String>,
    pub fake_ip_state: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlanFileRole {
    PolicyBundle,
    PolicyInstalled,
    Ticket,
    ControlToken,
    FakeIpState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanFile {
    pub path: String,
    pub role: PlanFileRole,
}

/// Kernel config JSON plus the paths the shell must have written first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KernelPlan {
    /// Compact JSON, object keys sorted, no trailing newline.
    pub config_json: String,
    /// Lower-case hex SHA-256 of [`Self::config_json`] as UTF-8.
    pub digest: String,
    pub files: Vec<PlanFile>,
}

/// Build the kernel plan. Does not read the filesystem or the clock.
pub fn prepare(input: &PrepareInput) -> Result<KernelPlan, PrepareError> {
    let listen = loopback_addr(&input.listen).ok_or(PrepareError::Listen)?;
    if listen.port() == 0 {
        return Err(PrepareError::Listen);
    }
    let dns_listen = loopback_addr(&input.dns_listen).ok_or(PrepareError::DnsListen)?;
    if dns_listen.port() == 0 {
        return Err(PrepareError::DnsListen);
    }
    if input.dns_domestic.is_empty() {
        return Err(PrepareError::DnsDomestic);
    }
    let mut domestic = Vec::with_capacity(input.dns_domestic.len());
    for raw in &input.dns_domestic {
        let addr = socket_addr(raw).ok_or(PrepareError::DnsDomestic)?;
        if addr.port() == 0 {
            return Err(PrepareError::DnsDomestic);
        }
        if addr == dns_listen {
            return Err(PrepareError::DnsLoop);
        }
        domestic.push(Value::String(addr.to_string()));
    }

    if input.nodes.is_empty() || input.nodes.len() > MAX_NODES {
        return Err(PrepareError::Nodes);
    }
    if !is_exit_name(&input.ai_route) || RESERVED_NAMES.contains(&input.ai_route.as_str()) {
        return Err(PrepareError::AiRoute);
    }

    let mut seen = BTreeSet::new();
    let mut outbounds = Map::new();
    let mut exits = Vec::with_capacity(input.nodes.len());
    for node in &input.nodes {
        if !is_exit_name(&node.name)
            || RESERVED_NAMES.contains(&node.name.as_str())
            || node.name == input.ai_route
        {
            return Err(PrepareError::ExitName);
        }
        if !seen.insert(node.name.clone()) {
            return Err(PrepareError::DuplicateNode);
        }
        for role in &node.roles {
            if role != "overseas" {
                return Err(PrepareError::Role);
            }
        }
        if let Some(group) = &node.egress_group {
            if !is_egress_group(group) {
                return Err(PrepareError::EgressGroup);
            }
        }
        let relay = socket_addr(&node.relay).ok_or(PrepareError::Relay)?;
        if relay.port() == 0 {
            return Err(PrepareError::Relay);
        }
        let outbound = sanitize_outbound(&node.outbound)?;
        outbounds.insert(node.name.clone(), outbound);

        let mut exit = Map::new();
        exit.insert("carrier".to_owned(), Value::String(node.name.clone()));
        if let Some(group) = &node.egress_group {
            exit.insert("egress_group".to_owned(), Value::String(group.clone()));
        }
        exit.insert("name".to_owned(), Value::String(node.name.clone()));
        exit.insert("node_id".to_owned(), Value::from(node.node_id));
        exit.insert("relay".to_owned(), Value::String(relay.to_string()));
        exits.push(Value::Object(exit));
    }

    check_path(&input.policy_bundle_path)?;
    check_path(&input.policy_installed_path)?;
    check_path(&input.ticket_path)?;
    check_path(&input.fake_ip_state)?;
    let keys = policy_keys(&input.public_keys)?;

    let mut policy = Map::new();
    policy.insert("ai_route".to_owned(), Value::String(input.ai_route.clone()));
    policy.insert(
        "bundle".to_owned(),
        Value::String(input.policy_bundle_path.clone()),
    );
    policy.insert(
        "installed".to_owned(),
        Value::String(input.policy_installed_path.clone()),
    );
    policy.insert("public_keys".to_owned(), Value::Array(keys));

    let segue_route = |class: &str, role: &str| {
        let mut route = Map::new();
        route.insert("exit_class".to_owned(), Value::String(class.to_owned()));
        route.insert("role".to_owned(), Value::String(role.to_owned()));
        route.insert(
            "ticket_file".to_owned(),
            Value::String(input.ticket_path.clone()),
        );
        Value::Object(route)
    };
    let mut segue = Map::new();
    segue.insert(input.ai_route.clone(), segue_route("ai", "home"));
    segue.insert("overseas".to_owned(), segue_route("overseas", "proxy"));

    let mut dns = Map::new();
    dns.insert("domestic".to_owned(), Value::Array(domestic));
    dns.insert(
        "fake_ip_range".to_owned(),
        Value::String("198.18.0.0/15".to_owned()),
    );
    dns.insert(
        "fake_ip_state".to_owned(),
        Value::String(input.fake_ip_state.clone()),
    );
    dns.insert("listen".to_owned(), Value::String(dns_listen.to_string()));

    let mut sniff = Map::new();
    sniff.insert("max_bytes".to_owned(), Value::from(16384_u64));
    sniff.insert("timeout_ms".to_owned(), Value::from(300_u64));

    let mut udp = Map::new();
    udp.insert("idle_timeout_secs".to_owned(), Value::from(60_u64));

    let mut root = Map::new();
    if let Some(control) = control_section(input)? {
        root.insert("control".to_owned(), control);
    }
    root.insert("dns".to_owned(), Value::Object(dns));
    root.insert("exits".to_owned(), Value::Array(exits));
    root.insert("listen".to_owned(), Value::String(listen.to_string()));
    root.insert("outbounds".to_owned(), Value::Object(outbounds));
    root.insert("policy".to_owned(), Value::Object(policy));
    root.insert("segue".to_owned(), Value::Object(segue));
    root.insert("sniff".to_owned(), Value::Object(sniff));
    root.insert("udp".to_owned(), Value::Object(udp));

    let config_json = serde_json::to_string(&Value::Object(root)).expect("plan json is finite");
    let digest = hex_sha256(config_json.as_bytes());

    let mut files = vec![
        PlanFile {
            path: input.policy_bundle_path.clone(),
            role: PlanFileRole::PolicyBundle,
        },
        PlanFile {
            path: input.policy_installed_path.clone(),
            role: PlanFileRole::PolicyInstalled,
        },
        PlanFile {
            path: input.ticket_path.clone(),
            role: PlanFileRole::Ticket,
        },
        PlanFile {
            path: input.fake_ip_state.clone(),
            role: PlanFileRole::FakeIpState,
        },
    ];
    if let Some(path) = &input.control_token_file {
        files.push(PlanFile {
            path: path.clone(),
            role: PlanFileRole::ControlToken,
        });
    }

    Ok(KernelPlan {
        config_json,
        digest,
        files,
    })
}

fn control_section(input: &PrepareInput) -> Result<Option<Value>, PrepareError> {
    match (&input.control_listen, &input.control_token_file) {
        (None, None) => Ok(None),
        (Some(listen), Some(path)) => {
            let addr = loopback_addr(listen).ok_or(PrepareError::Listen)?;
            check_path(path)?;
            let mut control = Map::new();
            control.insert("listen".to_owned(), Value::String(addr.to_string()));
            control.insert("token_file".to_owned(), Value::String(path.clone()));
            Ok(Some(Value::Object(control)))
        }
        _ => Err(PrepareError::Path),
    }
}

fn policy_keys(keys: &[PolicyKeyRef]) -> Result<Vec<Value>, PrepareError> {
    if keys.is_empty() {
        return Err(PrepareError::PolicyKey);
    }
    let mut seen = BTreeSet::new();
    let mut out = Vec::with_capacity(keys.len());
    for key in keys {
        if !seen.insert(key.key_id) || !is_base64_text(&key.public_key) {
            return Err(PrepareError::PolicyKey);
        }
        let mut obj = Map::new();
        obj.insert("key_id".to_owned(), Value::from(key.key_id));
        obj.insert(
            "public_key".to_owned(),
            Value::String(key.public_key.clone()),
        );
        out.push(Value::Object(obj));
    }
    Ok(out)
}

fn sanitize_outbound(value: &Value) -> Result<Value, PrepareError> {
    let obj = match value {
        Value::Object(map) => map,
        _ => return Err(PrepareError::Outbound),
    };
    reject_trust_bypass(value)?;
    let mut clean = Map::new();
    for (key, child) in obj {
        if key == "role" {
            if child.as_str() == Some("home") {
                return Err(PrepareError::Role);
            }
            // `proxy` / absent: the kernel strips role before the engine. A
            // carrier must not be home, so drop the key rather than forward it.
            continue;
        }
        if key == "server" || key == "address" {
            require_ip(child)?;
        }
        clean.insert(key.clone(), sanitize_child(child)?);
    }
    Ok(Value::Object(clean))
}

fn sanitize_child(value: &Value) -> Result<Value, PrepareError> {
    match value {
        Value::Object(map) => {
            let mut clean = Map::new();
            for (key, child) in map {
                if key == "server" || key == "address" {
                    require_ip(child)?;
                }
                clean.insert(key.clone(), sanitize_child(child)?);
            }
            Ok(Value::Object(clean))
        }
        Value::Array(items) => {
            let mut clean = Vec::with_capacity(items.len());
            for item in items {
                clean.push(sanitize_child(item)?);
            }
            Ok(Value::Array(clean))
        }
        other => Ok(other.clone()),
    }
}

fn require_ip(value: &Value) -> Result<(), PrepareError> {
    let Some(text) = value.as_str() else {
        return Err(PrepareError::OutboundAddress);
    };
    if text.parse::<IpAddr>().is_err() {
        return Err(PrepareError::OutboundAddress);
    }
    Ok(())
}

fn reject_trust_bypass(value: &Value) -> Result<(), PrepareError> {
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                if FORBIDDEN_OUTBOUND_KEYS.contains(&key.as_str()) {
                    return Err(PrepareError::Outbound);
                }
                reject_trust_bypass(child)?;
            }
            Ok(())
        }
        Value::Array(items) => {
            for item in items {
                reject_trust_bypass(item)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn is_exit_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    if bytes.is_empty() || bytes.len() > 32 {
        return false;
    }
    bytes
        .iter()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
}

fn is_egress_group(name: &str) -> bool {
    let bytes = name.as_bytes();
    if bytes.is_empty() || bytes.len() > 64 {
        return false;
    }
    bytes
        .iter()
        .all(|b| b.is_ascii_alphanumeric() || *b == b'-' || *b == b'_')
}

fn is_base64_text(text: &str) -> bool {
    let bytes = text.as_bytes();
    if bytes.is_empty() || bytes.len() > 128 {
        return false;
    }
    bytes.iter().all(|b| {
        b.is_ascii_alphanumeric()
            || *b == b'+'
            || *b == b'/'
            || *b == b'='
            || *b == b'-'
            || *b == b'_'
    })
}

fn check_path(path: &str) -> Result<(), PrepareError> {
    if path.is_empty() || path.as_bytes().contains(&0) {
        return Err(PrepareError::Path);
    }
    Ok(())
}

fn socket_addr(text: &str) -> Option<SocketAddr> {
    text.parse().ok()
}

fn loopback_addr(text: &str) -> Option<SocketAddr> {
    let addr = socket_addr(text)?;
    if addr.ip().is_loopback() {
        Some(addr)
    } else {
        None
    }
}

fn hex_sha256(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let dig = Sha256::digest(bytes);
    let mut out = String::with_capacity(dig.len() * 2);
    for byte in dig {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> PrepareInput {
        PrepareInput {
            listen: "127.0.0.1:1080".to_owned(),
            dns_listen: "127.0.0.1:5353".to_owned(),
            dns_domestic: vec!["223.5.5.5:53".to_owned()],
            nodes: vec![CatalogNode {
                name: "la-1".to_owned(),
                outbound: serde_json::json!({
                    "protocol": "vless",
                    "settings": {"address": "203.0.113.10", "port": 443}
                }),
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
    fn prepare_is_deterministic_and_has_no_inline_rules() {
        let plan = prepare(&sample()).unwrap();
        let again = prepare(&sample()).unwrap();
        assert_eq!(plan.config_json, again.config_json);
        assert_eq!(plan.digest, again.digest);
        assert_eq!(plan.digest.len(), 64);

        let expected = concat!(
            r#"{"dns":{"domestic":["223.5.5.5:53"],"fake_ip_range":"198.18.0.0/15","#,
            r#""fake_ip_state":"fakeip.state","listen":"127.0.0.1:5353"},"#,
            r#""exits":[{"carrier":"la-1","egress_group":"us-west","name":"la-1","node_id":12,"#,
            r#""relay":"203.0.113.10:7443"}],"listen":"127.0.0.1:1080","#,
            r#""outbounds":{"la-1":{"protocol":"vless","settings":{"address":"203.0.113.10","port":443}}},"#,
            r#""policy":{"ai_route":"ai","bundle":"policy.bundle","installed":"policy.installed","#,
            r#""public_keys":[{"key_id":1,"public_key":"AQIDBA=="}]},"#,
            r#""segue":{"ai":{"exit_class":"ai","role":"home","ticket_file":"device.ticket"},"#,
            r#""overseas":{"exit_class":"overseas","role":"proxy","ticket_file":"device.ticket"}},"#,
            r#""sniff":{"max_bytes":16384,"timeout_ms":300},"udp":{"idle_timeout_secs":60}}"#
        );
        assert_eq!(plan.config_json, expected);
        let parsed: Value = serde_json::from_str(&plan.config_json).unwrap();
        let obj = parsed.as_object().unwrap();
        assert!(obj.get("rules").is_none());
        assert!(obj.get("default").is_none());
        assert!(!plan.config_json.contains("SGT1."));
        assert!(plan.files.iter().any(|f| f.role == PlanFileRole::Ticket));
    }

    #[test]
    fn prepare_omits_an_absent_egress_group_and_strips_proxy_role() {
        let mut input = sample();
        input.nodes[0].egress_group = None;
        input.nodes[0].outbound = serde_json::json!({
            "protocol": "vless",
            "role": "proxy",
            "settings": {"address": "203.0.113.10", "port": 443}
        });
        let plan = prepare(&input).unwrap();
        let parsed: Value = serde_json::from_str(&plan.config_json).unwrap();
        let exit = &parsed["exits"][0];
        assert!(exit.get("egress_group").is_none());
        assert!(parsed["outbounds"]["la-1"].get("role").is_none());
    }

    #[test]
    fn prepare_rejects_hostnames_trust_bypass_and_reserved_names() {
        let mut input = sample();
        input.nodes[0].relay = "example.com:7443".to_owned();
        assert_eq!(prepare(&input).unwrap_err(), PrepareError::Relay);

        let mut input = sample();
        input.nodes[0].outbound["settings"]["address"] = Value::String("example.com".to_owned());
        assert_eq!(prepare(&input).unwrap_err(), PrepareError::OutboundAddress);

        let mut input = sample();
        input.nodes[0].outbound["skip-cert-verify"] = Value::Bool(true);
        assert_eq!(prepare(&input).unwrap_err(), PrepareError::Outbound);

        let mut input = sample();
        input.nodes[0].name = "auto".to_owned();
        assert_eq!(prepare(&input).unwrap_err(), PrepareError::ExitName);

        let mut input = sample();
        input.nodes[0].roles = vec!["home".to_owned()];
        assert_eq!(prepare(&input).unwrap_err(), PrepareError::Role);

        let mut input = sample();
        input.listen = "203.0.113.10:1080".to_owned();
        assert_eq!(prepare(&input).unwrap_err(), PrepareError::Listen);

        let mut input = sample();
        input.dns_domestic = vec!["127.0.0.1:5353".to_owned()];
        assert_eq!(prepare(&input).unwrap_err(), PrepareError::DnsLoop);
    }
}
