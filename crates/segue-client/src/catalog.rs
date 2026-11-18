//! Signed catalog admission and the nodes [`crate::prepare`] consumes.
//!
//! The document is compact JSON, schema 1, Ed25519 over
//! [`CATALOG_SIG_CONTEXT`] plus the canonical body. Revision moves only
//! forward. The same revision with the same digest is idempotent; the same
//! revision with any other digest is refused.
//!
//! An absent `egress_group` is left absent. The kernel then treats that exit
//! as its own group and pins AI there. This module carries the field and does
//! not restate the pin.
//!
//! Node names use the kernel exit grammar (`[a-z0-9-]{1,32}`, not a reserved
//! route tag) so an admitted node is a [`crate::CatalogNode`] `prepare` can
//! take. The design's wider label class is tightened to that grammar here.

use std::collections::BTreeSet;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use serde::Deserialize;
use serde_json::Value;

use crate::canonical::canonical_json;
use crate::envelope::{self, CATALOG_SIG_CONTEXT, MAX_CATALOG_BYTES};
use crate::keys::TrustedKey;
use crate::persist::SequenceFloor;
use crate::plan::{
    is_kernel_egress_group, is_kernel_exit_name, is_reserved_route_name, CatalogNode,
};
use crate::status::ExitView;

const MAX_NODES: usize = 200;

const FORBIDDEN_OUTBOUND_KEYS: &[&str] = &[
    "skip-cert-verify",
    "skip_cert_verify",
    "skipCertVerify",
    "allowInsecure",
    "allow_insecure",
    "insecure",
    "danger_accept_invalid_certs",
];

/// Admitted catalog. `nodes` is the [`crate::PrepareInput`] node list.
#[derive(Debug, Clone, PartialEq)]
pub struct CatalogInstall {
    pub revision: u64,
    pub digest: String,
    pub idempotent: bool,
    pub issued_at: u64,
    pub expires_at: u64,
    pub ai_route: String,
    pub nodes: Vec<CatalogNode>,
    /// Picker rows. `egress_group` is `None` when the document omitted it.
    pub exits: Vec<ExitView>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CatalogError {
    #[error("the catalog is too large")]
    Oversized,
    #[error("the catalog is malformed")]
    Malformed,
    #[error("no catalog key is configured")]
    NoKey,
    #[error("a catalog key id is configured twice")]
    DuplicateKey,
    #[error("a catalog key is not an Ed25519 public key")]
    BadKey,
    #[error("the catalog is signed by an unknown key")]
    UnknownKey,
    #[error("the catalog signature is not valid")]
    BadSignature,
    #[error("this catalog version is not supported")]
    Schema,
    #[error("the catalog has expired")]
    Expired,
    #[error("the catalog revision is not newer than the one already installed")]
    Rollback,
    #[error("this catalog revision does not match the one already installed")]
    DigestConflict,
    #[error("the catalog has no nodes")]
    Empty,
    #[error("the catalog has too many nodes")]
    TooManyNodes,
    #[error("a node name is not usable as an exit")]
    Name,
    #[error("a node name is reserved")]
    ReservedName,
    #[error("two nodes share a name")]
    DuplicateName,
    #[error("two nodes share an id")]
    DuplicateId,
    #[error("a node's id does not match its node_id")]
    Identity,
    #[error("a relay is not a literal ip:port")]
    Relay,
    #[error("an outbound server must be a literal public IP")]
    PublicIp,
    #[error("an outbound tries to skip certificate checks")]
    TrustBypass,
    #[error("an egress group is not usable")]
    EgressGroup,
    #[error("the catalog AI route is not usable")]
    AiRoute,
    #[error("a node role is not overseas")]
    Role,
    #[error("a region is not usable")]
    Region,
    #[error("the catalog has a field this version does not understand")]
    UnknownField,
}

impl CatalogError {
    pub fn code(&self) -> &'static str {
        match self {
            CatalogError::Oversized => "oversized",
            CatalogError::Malformed => "malformed",
            CatalogError::NoKey => "no_key",
            CatalogError::DuplicateKey => "duplicate_key",
            CatalogError::BadKey => "bad_key",
            CatalogError::UnknownKey => "unknown_key",
            CatalogError::BadSignature => "bad_signature",
            CatalogError::Schema => "schema",
            CatalogError::Expired => "expired",
            CatalogError::Rollback => "rollback",
            CatalogError::DigestConflict => "digest_conflict",
            CatalogError::Empty => "empty",
            CatalogError::TooManyNodes => "too_many_nodes",
            CatalogError::Name => "name",
            CatalogError::ReservedName => "reserved_name",
            CatalogError::DuplicateName => "duplicate_name",
            CatalogError::DuplicateId => "duplicate_id",
            CatalogError::Identity => "identity",
            CatalogError::Relay => "relay",
            CatalogError::PublicIp => "public_ip",
            CatalogError::TrustBypass => "trust_bypass",
            CatalogError::EgressGroup => "egress_group",
            CatalogError::AiRoute => "ai_route",
            CatalogError::Role => "role",
            CatalogError::Region => "region",
            CatalogError::UnknownField => "unknown_field",
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct CatalogDoc {
    #[serde(rename = "schemaVersion")]
    schema_version: u64,
    revision: u64,
    issued_at: u64,
    expires_at: u64,
    ai_route: String,
    nodes: Vec<NodeDoc>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NodeDoc {
    id: u64,
    name: String,
    region: String,
    outbound: Value,
    relay: String,
    node_id: u64,
    #[serde(default)]
    egress_group: Option<String>,
    #[serde(default)]
    roles: Vec<String>,
}

/// Admit `bytes`. `floor` is the persisted high-water; `None` means nothing
/// has been admitted yet (the floor is revision 0).
pub fn admit_catalog(
    bytes: &[u8],
    now: u64,
    keys: &[TrustedKey],
    floor: Option<&SequenceFloor>,
) -> Result<CatalogInstall, CatalogError> {
    if bytes.len() > MAX_CATALOG_BYTES {
        return Err(CatalogError::Oversized);
    }
    let digest = envelope::hex_sha256(bytes);
    let opened = envelope::open(bytes, keys, CATALOG_SIG_CONTEXT).map_err(map_envelope)?;
    let doc = decode_body(&opened.body)?;
    if doc.schema_version != 1 {
        return Err(CatalogError::Schema);
    }
    if doc.issued_at >= doc.expires_at {
        return Err(CatalogError::Malformed);
    }
    if now >= doc.expires_at {
        return Err(CatalogError::Expired);
    }
    if !is_kernel_exit_name(&doc.ai_route) {
        return Err(CatalogError::AiRoute);
    }
    let nodes = admit_nodes(&doc)?;
    if nodes.iter().any(|node| node.node.name == doc.ai_route) {
        return Err(CatalogError::AiRoute);
    }
    decide_revision(doc.revision, &digest, floor)?;
    let idempotent =
        floor.is_some_and(|known| known.sequence == doc.revision && known.digest == digest);
    Ok(CatalogInstall {
        revision: doc.revision,
        digest,
        idempotent,
        issued_at: doc.issued_at,
        expires_at: doc.expires_at,
        ai_route: doc.ai_route,
        exits: nodes
            .iter()
            .map(|node| ExitView {
                name: node.node.name.clone(),
                region: node.region.clone(),
                egress_group: node.node.egress_group.clone(),
            })
            .collect(),
        nodes: nodes.into_iter().map(|node| node.node).collect(),
    })
}

struct AdmittedNode {
    region: String,
    node: CatalogNode,
}

fn decide_revision(
    revision: u64,
    digest: &str,
    floor: Option<&SequenceFloor>,
) -> Result<(), CatalogError> {
    let floor_seq = floor.map(|known| known.sequence).unwrap_or(0);
    if revision > floor_seq {
        return Ok(());
    }
    if floor.is_some_and(|known| known.sequence == revision && known.digest == digest) {
        return Ok(());
    }
    if floor.is_some_and(|known| known.sequence == revision) {
        return Err(CatalogError::DigestConflict);
    }
    Err(CatalogError::Rollback)
}

fn decode_body(body: &[u8]) -> Result<CatalogDoc, CatalogError> {
    let text = std::str::from_utf8(body).map_err(|_| CatalogError::Malformed)?;
    let value: Value = serde_json::from_str(text).map_err(|_| CatalogError::Malformed)?;
    if canonical_json(&value).as_bytes() != body {
        return Err(CatalogError::Malformed);
    }
    if has_unknown_field(&value) {
        return Err(CatalogError::UnknownField);
    }
    serde_json::from_value(value).map_err(|_| CatalogError::Malformed)
}

const DOC_KEYS: &[&str] = &[
    "ai_route",
    "expires_at",
    "issued_at",
    "nodes",
    "revision",
    "schemaVersion",
];
const NODE_KEYS: &[&str] = &[
    "egress_group",
    "id",
    "name",
    "node_id",
    "outbound",
    "region",
    "relay",
    "roles",
];

fn has_unknown_field(value: &Value) -> bool {
    let Some(doc) = value.as_object() else {
        return false;
    };
    if doc.keys().any(|key| !DOC_KEYS.contains(&key.as_str())) {
        return true;
    }
    let Some(nodes) = doc.get("nodes").and_then(Value::as_array) else {
        return false;
    };
    nodes.iter().any(|node| {
        node.as_object()
            .is_some_and(|fields| fields.keys().any(|key| !NODE_KEYS.contains(&key.as_str())))
    })
}

fn admit_nodes(doc: &CatalogDoc) -> Result<Vec<AdmittedNode>, CatalogError> {
    if doc.nodes.is_empty() {
        return Err(CatalogError::Empty);
    }
    if doc.nodes.len() > MAX_NODES {
        return Err(CatalogError::TooManyNodes);
    }
    let mut names = BTreeSet::new();
    let mut ids = BTreeSet::new();
    let mut out = Vec::with_capacity(doc.nodes.len());
    for node in &doc.nodes {
        if is_reserved_route_name(&node.name) {
            return Err(CatalogError::ReservedName);
        }
        if !is_kernel_exit_name(&node.name) {
            return Err(CatalogError::Name);
        }
        if !names.insert(node.name.clone()) {
            return Err(CatalogError::DuplicateName);
        }
        if node.id != node.node_id {
            return Err(CatalogError::Identity);
        }
        if !ids.insert(node.id) {
            return Err(CatalogError::DuplicateId);
        }
        if !is_region(&node.region) {
            return Err(CatalogError::Region);
        }
        let relay = check_relay(&node.relay)?;
        let egress_group = match &node.egress_group {
            None => None,
            Some(group) if is_kernel_egress_group(group) => Some(group.clone()),
            Some(_) => return Err(CatalogError::EgressGroup),
        };
        let roles = check_roles(&node.roles)?;
        let outbound = check_outbound(&node.outbound)?;
        out.push(AdmittedNode {
            region: node.region.clone(),
            node: CatalogNode {
                name: node.name.clone(),
                outbound,
                relay,
                node_id: node.node_id,
                egress_group,
                roles,
            },
        });
    }
    Ok(out)
}

fn check_roles(roles: &[String]) -> Result<Vec<String>, CatalogError> {
    let mut seen = BTreeSet::new();
    for role in roles {
        if role != "overseas" || !seen.insert(role.as_str()) {
            return Err(CatalogError::Role);
        }
    }
    Ok(roles.to_vec())
}

fn check_relay(text: &str) -> Result<String, CatalogError> {
    let addr: SocketAddr = text.parse().map_err(|_| CatalogError::Relay)?;
    if addr.port() == 0 || addr.ip().is_unspecified() || addr.ip().is_multicast() {
        return Err(CatalogError::Relay);
    }
    Ok(text.to_owned())
}

fn check_outbound(value: &Value) -> Result<Value, CatalogError> {
    if !value.is_object() {
        return Err(CatalogError::Malformed);
    }
    let mut saw_address = false;
    let cleaned = walk_outbound(value, &mut saw_address)?;
    if !saw_address {
        return Err(CatalogError::PublicIp);
    }
    Ok(cleaned)
}

fn walk_outbound(value: &Value, saw_address: &mut bool) -> Result<Value, CatalogError> {
    match value {
        Value::Object(map) => {
            let mut clean = serde_json::Map::new();
            for (key, child) in map {
                if FORBIDDEN_OUTBOUND_KEYS.contains(&key.as_str()) {
                    return Err(CatalogError::TrustBypass);
                }
                if key == "role" {
                    if child.as_str() == Some("proxy") {
                        continue;
                    }
                    return Err(CatalogError::Role);
                }
                if key == "server" || key == "address" {
                    require_public_ip(child)?;
                    *saw_address = true;
                }
                clean.insert(key.clone(), walk_outbound(child, saw_address)?);
            }
            Ok(Value::Object(clean))
        }
        Value::Array(items) => {
            let mut clean = Vec::with_capacity(items.len());
            for item in items {
                clean.push(walk_outbound(item, saw_address)?);
            }
            Ok(Value::Array(clean))
        }
        other => Ok(other.clone()),
    }
}

fn require_public_ip(value: &Value) -> Result<(), CatalogError> {
    let Some(text) = value.as_str() else {
        return Err(CatalogError::PublicIp);
    };
    let ip: IpAddr = text.parse().map_err(|_| CatalogError::PublicIp)?;
    if is_public_literal(ip) {
        Ok(())
    } else {
        Err(CatalogError::PublicIp)
    }
}

/// Literal IP that is not a local, private, or fake-IP address.
/// Documentation ranges (RFC 5737 and RFC 3849) are accepted so tests can
/// use synthetic addresses.
pub(crate) fn is_public_literal(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_public_v4(v4),
        IpAddr::V6(v6) => is_public_v6(v6),
    }
}

fn is_public_v4(v4: Ipv4Addr) -> bool {
    if v4.is_private()
        || v4.is_loopback()
        || v4.is_link_local()
        || v4.is_broadcast()
        || v4.is_unspecified()
        || v4.is_multicast()
    {
        return false;
    }
    let octets = v4.octets();
    if octets[0] == 0 || octets[0] >= 240 {
        return false;
    }
    // Carrier-grade NAT 100.64.0.0/10.
    if octets[0] == 100 && (octets[1] & 0b1100_0000) == 64 {
        return false;
    }
    // Benchmarking / fake-IP 198.18.0.0/15.
    if octets[0] == 198 && (octets[1] == 18 || octets[1] == 19) {
        return false;
    }
    // IETF protocol assignments 192.0.0.0/24. TEST-NET-1 is 192.0.2.0/24.
    if octets[0] == 192 && octets[1] == 0 && octets[2] == 0 {
        return false;
    }
    true
}

fn is_public_v6(v6: Ipv6Addr) -> bool {
    if v6.is_loopback() || v6.is_unspecified() || v6.is_multicast() {
        return false;
    }
    let first = v6.segments()[0];
    // fe80::/10
    if first & 0xffc0 == 0xfe80 {
        return false;
    }
    // fc00::/7
    if first & 0xfe00 == 0xfc00 {
        return false;
    }
    if let Some(v4) = v6.to_ipv4_mapped() {
        return is_public_v4(v4);
    }
    true
}

fn is_region(name: &str) -> bool {
    let bytes = name.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 32
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-' || *byte == b'_')
}

fn map_envelope(error: envelope::EnvelopeError) -> CatalogError {
    match error {
        envelope::EnvelopeError::Malformed => CatalogError::Malformed,
        envelope::EnvelopeError::NoKey => CatalogError::NoKey,
        envelope::EnvelopeError::DuplicateKey => CatalogError::DuplicateKey,
        envelope::EnvelopeError::BadKey => CatalogError::BadKey,
        envelope::EnvelopeError::UnknownKey(_) => CatalogError::UnknownKey,
        envelope::EnvelopeError::BadSignature => CatalogError::BadSignature,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plan::{prepare, PolicyKeyRef, PrepareInput};
    use crate::seal;

    fn keys(seed: &[u8; 32]) -> Vec<TrustedKey> {
        vec![TrustedKey {
            key_id: 1,
            public_key: seal::public_key(seed),
        }]
    }

    fn document() -> Value {
        serde_json::json!({
            "schemaVersion": 1,
            "revision": 2,
            "issued_at": 1_700_000_000_u64,
            "expires_at": 1_800_000_000_u64,
            "ai_route": "ai",
            "nodes": [{
                "id": 12,
                "name": "la-1",
                "region": "us",
                "outbound": {"protocol": "vless", "settings": {"address": "203.0.113.10", "port": 443}},
                "relay": "198.51.100.4:7443",
                "node_id": 12,
                "egress_group": "us-west",
                "roles": ["overseas"]
            }]
        })
    }

    fn admit(bytes: &[u8], floor: Option<&SequenceFloor>) -> Result<CatalogInstall, CatalogError> {
        let seed = seal::seed_from_label("unit");
        admit_catalog(bytes, 1_700_001_000, &keys(&seed), floor)
    }

    #[test]
    fn admitted_nodes_prepare_and_keep_the_egress_group() {
        let seed = seal::seed_from_label("unit");
        let bytes = seal::catalog_document(&seed, 1, &document());
        let install = admit(&bytes, None).unwrap();
        assert!(!install.idempotent);
        assert_eq!(install.revision, 2);
        assert_eq!(install.digest.len(), 64);
        assert_eq!(install.exits[0].egress_group.as_deref(), Some("us-west"));
        let plan = prepare(&sample_input(&install)).unwrap();
        assert!(plan.config_json.contains("\"egress_group\":\"us-west\""));
        assert!(!plan.config_json.contains("skip-cert-verify"));

        let again = admit(&bytes, Some(&floor(&install))).unwrap();
        assert!(again.idempotent);
        assert_eq!(again.digest, install.digest);
    }

    #[test]
    fn absent_egress_group_stays_absent() {
        let mut doc = document();
        doc["nodes"][0]
            .as_object_mut()
            .unwrap()
            .remove("egress_group");
        let seed = seal::seed_from_label("unit");
        let bytes = seal::catalog_document(&seed, 1, &doc);
        let install = admit(&bytes, None).unwrap();
        assert!(install.nodes[0].egress_group.is_none());
        assert!(install.exits[0].egress_group.is_none());
        let plan = prepare(&sample_input(&install)).unwrap();
        assert!(!plan.config_json.contains("egress_group"));
    }

    #[test]
    fn rejects_rollback_private_ip_and_trust_bypass() {
        let seed = seal::seed_from_label("unit");
        let bytes = seal::catalog_document(&seed, 1, &document());
        let install = admit(&bytes, None).unwrap();
        let mut older = document();
        older["revision"] = Value::from(1_u64);
        let older_bytes = seal::catalog_document(&seed, 1, &older);
        assert_eq!(
            admit(&older_bytes, Some(&floor(&install)))
                .unwrap_err()
                .code(),
            "rollback"
        );
        let mut changed = document();
        changed["nodes"][0]["region"] = Value::String("eu".to_owned());
        let changed_bytes = seal::catalog_document(&seed, 1, &changed);
        assert_eq!(
            admit(&changed_bytes, Some(&floor(&install)))
                .unwrap_err()
                .code(),
            "digest_conflict"
        );

        let mut private_ip = document();
        private_ip["nodes"][0]["outbound"]["settings"]["address"] =
            Value::String("10.0.0.4".to_owned());
        assert_eq!(
            admit(&seal::catalog_document(&seed, 1, &private_ip), None)
                .unwrap_err()
                .code(),
            "public_ip"
        );
        let mut bypass = document();
        bypass["nodes"][0]["outbound"]["skip-cert-verify"] = Value::Bool(true);
        assert_eq!(
            admit(&seal::catalog_document(&seed, 1, &bypass), None)
                .unwrap_err()
                .code(),
            "trust_bypass"
        );
        assert_eq!(
            admit_catalog(&bytes, 1_700_001_000, &[], None)
                .unwrap_err()
                .code(),
            "no_key"
        );
    }

    fn floor(install: &CatalogInstall) -> SequenceFloor {
        SequenceFloor {
            sequence: install.revision,
            digest: install.digest.clone(),
        }
    }

    fn sample_input(install: &CatalogInstall) -> PrepareInput {
        PrepareInput {
            listen: "127.0.0.1:1080".to_owned(),
            dns_listen: "127.0.0.1:5353".to_owned(),
            dns_domestic: vec!["223.5.5.5:53".to_owned()],
            nodes: install.nodes.clone(),
            policy_bundle_path: "policy.bundle".to_owned(),
            policy_installed_path: "policy.installed".to_owned(),
            public_keys: vec![PolicyKeyRef {
                key_id: 1,
                public_key: "AQIDBA==".to_owned(),
            }],
            ticket_path: "device.ticket".to_owned(),
            ai_route: install.ai_route.clone(),
            control_listen: None,
            control_token_file: None,
            fake_ip_state: "fakeip.state".to_owned(),
        }
    }
}
