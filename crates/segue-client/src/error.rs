//! Errors from pure plan preparation.
//!
//! Messages name the field that failed. They never include ticket bytes, outbound
//! secrets, or credential material.

use std::fmt;

/// [`crate::prepare`] refused an input. The same inputs always produce the same
/// error; nothing here depends on the clock or the disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrepareError {
    /// `listen` was missing, not an address, or not loopback.
    Listen,
    /// DNS listen was missing, not loopback, or port 0.
    DnsListen,
    /// No domestic resolver, or one of them is not `ip:port`.
    DnsDomestic,
    /// A domestic resolver is the DNS listen address (a query loop).
    DnsLoop,
    /// No nodes, or more than the catalog cap.
    Nodes,
    /// A node name is not a kernel exit name, or it is reserved.
    ExitName,
    /// Two nodes share a name.
    DuplicateNode,
    /// `relay` is not a literal `ip:port`, or the port is 0.
    Relay,
    /// An outbound is not an object, or it asks to skip certificate checks.
    Outbound,
    /// An outbound `server` or `address` is not a literal IP.
    OutboundAddress,
    /// `egress_group`, when set, is not `[A-Za-z0-9_-]{1,64}`.
    EgressGroup,
    /// The AI route tag is empty, reserved, or the same as a node name.
    AiRoute,
    /// No policy key, a duplicate `key_id`, or a key that is not base64 text.
    PolicyKey,
    /// A path the kernel will open is empty or contains a NUL.
    Path,
    /// A node role is not one this plan can carry. AI is a segue route, not a
    /// home-role carrier (the kernel rejects a home carrier on an exit).
    Role,
}

impl fmt::Display for PrepareError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match self {
            PrepareError::Listen => "listen must be a loopback ip:port",
            PrepareError::DnsListen => "dns listen must be a loopback ip:port",
            PrepareError::DnsDomestic => "dns needs at least one domestic ip:port resolver",
            PrepareError::DnsLoop => "a domestic resolver must not be the dns listen address",
            PrepareError::Nodes => "a plan needs between 1 and 200 nodes",
            PrepareError::ExitName => {
                "a node name must be [a-z0-9-]{1,32} and not a reserved route tag"
            }
            PrepareError::DuplicateNode => "two nodes share a name",
            PrepareError::Relay => "relay must be a literal ip:port",
            PrepareError::Outbound => {
                "an outbound must be an object and must not skip certificate checks"
            }
            PrepareError::OutboundAddress => "an outbound server or address must be a literal IP",
            PrepareError::EgressGroup => "egress_group must be [A-Za-z0-9_-]{1,64}",
            PrepareError::AiRoute => "ai_route must be [a-z0-9-]{1,32} and not a node name",
            PrepareError::PolicyKey => "policy needs unique key ids and base64 public keys",
            PrepareError::Path => "a plan path is empty or contains a NUL",
            PrepareError::Role => "a node role must be overseas; the AI route is not a carrier",
        };
        f.write_str(text)
    }
}

impl std::error::Error for PrepareError {}
