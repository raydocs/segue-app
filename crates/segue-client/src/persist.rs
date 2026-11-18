//! Sequence floors stored through [`crate::StateStore`].
//!
//! One record is `{sequence} {digest}` in ASCII. The digest is the lower-case
//! hex SHA-256 of the exact bytes that were admitted. A torn or edited floor
//! is an error: treating it as "no floor" would let an older document back in.

use crate::ports::{StateKey, StateStore, StoreError};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SequenceFloor {
    pub sequence: u64,
    pub digest: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PersistError {
    Store(StoreError),
    Corrupt,
}

impl From<StoreError> for PersistError {
    fn from(error: StoreError) -> Self {
        PersistError::Store(error)
    }
}

pub(crate) fn read_floor(
    store: &impl StateStore,
    key: StateKey,
) -> Result<Option<SequenceFloor>, PersistError> {
    let Some(bytes) = store.get(key)? else {
        return Ok(None);
    };
    if bytes.is_empty() {
        return Ok(None);
    }
    parse_floor(&bytes).map(Some).ok_or(PersistError::Corrupt)
}

pub(crate) fn write_floor(
    store: &impl StateStore,
    key: StateKey,
    floor: &SequenceFloor,
) -> Result<(), PersistError> {
    let text = format!("{} {}", floor.sequence, floor.digest);
    store.put(key, text.as_bytes())?;
    Ok(())
}

pub(crate) fn read_unix(store: &impl StateStore, key: StateKey) -> Result<u64, PersistError> {
    let Some(bytes) = store.get(key)? else {
        return Ok(0);
    };
    if bytes.is_empty() {
        return Ok(0);
    }
    parse_unix(&bytes).ok_or(PersistError::Corrupt)
}

pub(crate) fn write_unix(
    store: &impl StateStore,
    key: StateKey,
    value: u64,
) -> Result<(), PersistError> {
    store.put(key, value.to_string().as_bytes())?;
    Ok(())
}

fn parse_floor(bytes: &[u8]) -> Option<SequenceFloor> {
    let text = std::str::from_utf8(bytes).ok()?;
    let (sequence, digest) = text.split_once(' ')?;
    if digest.len() != 64 || !is_lower_hex(digest) {
        return None;
    }
    let sequence = parse_u64(sequence)?;
    Some(SequenceFloor {
        sequence,
        digest: digest.to_owned(),
    })
}

fn parse_unix(bytes: &[u8]) -> Option<u64> {
    let text = std::str::from_utf8(bytes).ok()?;
    parse_u64(text)
}

fn parse_u64(text: &str) -> Option<u64> {
    if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    if text.len() > 1 && text.starts_with('0') {
        return None;
    }
    text.parse().ok()
}

fn is_lower_hex(text: &str) -> bool {
    text.bytes()
        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
