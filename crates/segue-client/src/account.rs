//! Account session and device identity.
//!
//! The access token stays in memory. The refresh token is written only through
//! [`crate::CredentialStore`]. Neither token is part of [`crate::ClientStatus`],
//! and [`AccountSession`]'s debug text redacts both.
//!
//! `401` ends the session. `403 PLAN_EXPIRED` and `403 QUOTA_EXHAUSTED` are an
//! account hold: tokens stay, and the hold does not disarm protection.

use crate::ports::{CredentialKey, CredentialStore, Secret};

/// What the account is allowed to do right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Entitlement {
    Active,
    PlanExpired,
    QuotaExhausted,
}

/// Where this install runs. The control plane names the device with this.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Macos,
    Windows,
    Ios,
    Android,
    Linux,
}

/// `{device_id, name, platform, install_id}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    pub device_id: u64,
    pub name: String,
    pub platform: Platform,
    pub install_id: String,
}

impl Device {
    pub fn new(
        device_id: u64,
        name: impl Into<String>,
        platform: Platform,
        install_id: impl Into<String>,
    ) -> Result<Self, AccountError> {
        let name = name.into();
        let install_id = install_id.into();
        if !is_label(&name, 64) || !is_label(&install_id, 64) {
            return Err(AccountError::Malformed);
        }
        Ok(Self {
            device_id,
            name,
            platform,
            install_id,
        })
    }
}

/// In-memory session. Dropping it zeroizes both tokens.
pub struct AccountSession {
    pub account_id: u64,
    pub plan: String,
    pub entitlement: Entitlement,
    access_token: Secret,
    refresh_token: Secret,
    pub expires_at: u64,
}

impl AccountSession {
    pub fn new(
        account_id: u64,
        plan: impl Into<String>,
        entitlement: Entitlement,
        access_token: impl AsRef<[u8]>,
        refresh_token: impl AsRef<[u8]>,
        expires_at: u64,
    ) -> Result<Self, AccountError> {
        let plan = plan.into();
        let access = access_token.as_ref();
        let refresh = refresh_token.as_ref();
        if !is_label(&plan, 32) || access.is_empty() || refresh.is_empty() {
            return Err(AccountError::Malformed);
        }
        if access.len() > 4096 || refresh.len() > 4096 {
            return Err(AccountError::Malformed);
        }
        Ok(Self {
            account_id,
            plan,
            entitlement,
            access_token: Secret::new(access),
            refresh_token: Secret::new(refresh),
            expires_at,
        })
    }

    /// Memory only. Not written to the credential store.
    pub fn access_token(&self) -> &[u8] {
        self.access_token.expose()
    }

    pub fn refresh_token(&self) -> &Secret {
        &self.refresh_token
    }

    /// The only persistence path for the refresh token.
    pub fn persist_refresh_token(
        &self,
        store: &impl CredentialStore,
    ) -> Result<(), crate::ports::CredentialError> {
        store.set(CredentialKey::RefreshToken, &self.refresh_token)
    }

    pub fn access_expired(&self, now: u64) -> bool {
        now >= self.expires_at
    }

    pub fn set_entitlement(&mut self, entitlement: Entitlement) {
        self.entitlement = entitlement;
    }
}

impl std::fmt::Debug for AccountSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AccountSession")
            .field("account_id", &self.account_id)
            .field("plan", &self.plan)
            .field("entitlement", &self.entitlement)
            .field("access_token", &self.access_token)
            .field("refresh_token", &self.refresh_token)
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

/// A classified account response. Unrelated HTTP statuses are not this type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccountFailure {
    /// `401`. The session is over. Drop tokens.
    SessionEnded,
    /// `403 PLAN_EXPIRED`. Keep tokens.
    PlanExpired,
    /// `403 QUOTA_EXHAUSTED`. Keep tokens.
    QuotaExhausted,
}

impl AccountFailure {
    /// Hold statuses keep the refresh token. A session end does not.
    pub fn keeps_tokens(self) -> bool {
        matches!(
            self,
            AccountFailure::PlanExpired | AccountFailure::QuotaExhausted
        )
    }

    pub fn entitlement(self) -> Option<Entitlement> {
        match self {
            AccountFailure::PlanExpired => Some(Entitlement::PlanExpired),
            AccountFailure::QuotaExhausted => Some(Entitlement::QuotaExhausted),
            AccountFailure::SessionEnded => None,
        }
    }

    pub fn user_copy(self) -> &'static str {
        match self {
            AccountFailure::SessionEnded => "Sign in again to refresh this device.",
            AccountFailure::PlanExpired => "The plan has expired. Protection stays on.",
            AccountFailure::QuotaExhausted => "The plan's quota is used up. Protection stays on.",
        }
    }

    pub fn code(self) -> &'static str {
        match self {
            AccountFailure::SessionEnded => "session_ended",
            AccountFailure::PlanExpired => "plan_expired",
            AccountFailure::QuotaExhausted => "quota_exhausted",
        }
    }
}

/// Classify an account HTTP response. `None` means this is not an account
/// decision (a transport failure, for example) and tokens are left alone.
pub fn classify_account_response(status: u16, code: &str) -> Option<AccountFailure> {
    match (status, code) {
        (401, _) => Some(AccountFailure::SessionEnded),
        (403, "PLAN_EXPIRED") => Some(AccountFailure::PlanExpired),
        (403, "QUOTA_EXHAUSTED") => Some(AccountFailure::QuotaExhausted),
        _ => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum AccountError {
    #[error("the account document is not usable")]
    Malformed,
}

fn is_label(text: &str, max: usize) -> bool {
    let bytes = text.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= max
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-' || *byte == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ports::CredentialError;
    use std::cell::RefCell;

    struct Mem {
        refresh: RefCell<Option<Vec<u8>>>,
    }

    impl CredentialStore for Mem {
        fn get(&self, key: CredentialKey) -> Result<Option<Secret>, CredentialError> {
            match key {
                CredentialKey::RefreshToken => Ok(self.refresh.borrow().as_ref().map(Secret::new)),
                CredentialKey::DeviceId => Ok(None),
            }
        }
        fn set(&self, key: CredentialKey, value: &Secret) -> Result<(), CredentialError> {
            match key {
                CredentialKey::RefreshToken => {
                    *self.refresh.borrow_mut() = Some(value.expose().to_vec());
                }
                CredentialKey::DeviceId => {}
            }
            Ok(())
        }
        fn delete(&self, key: CredentialKey) -> Result<(), CredentialError> {
            if key == CredentialKey::RefreshToken {
                *self.refresh.borrow_mut() = None;
            }
            Ok(())
        }
    }

    #[test]
    fn holds_keep_tokens_and_debug_redacts_them() {
        assert!(AccountFailure::PlanExpired.keeps_tokens());
        assert!(AccountFailure::QuotaExhausted.keeps_tokens());
        assert!(!AccountFailure::SessionEnded.keeps_tokens());
        assert_eq!(
            classify_account_response(403, "PLAN_EXPIRED"),
            Some(AccountFailure::PlanExpired)
        );
        assert_eq!(
            classify_account_response(403, "QUOTA_EXHAUSTED"),
            Some(AccountFailure::QuotaExhausted)
        );
        assert_eq!(
            classify_account_response(401, "WHATEVER"),
            Some(AccountFailure::SessionEnded)
        );
        assert_eq!(classify_account_response(500, "PLAN_EXPIRED"), None);
        assert_eq!(classify_account_response(403, "OTHER"), None);

        let session = AccountSession::new(
            7,
            "plus",
            Entitlement::Active,
            b"access-secret",
            b"refresh-secret",
            1_800_000_000,
        )
        .unwrap();
        let rendered = format!("{session:?}");
        assert!(!rendered.contains("access-secret"));
        assert!(!rendered.contains("refresh-secret"));
        assert!(rendered.contains("redacted"));

        let store = Mem {
            refresh: RefCell::new(None),
        };
        session.persist_refresh_token(&store).unwrap();
        let saved = store.get(CredentialKey::RefreshToken).unwrap().unwrap();
        assert_eq!(saved.expose(), b"refresh-secret");
        assert!(store.get(CredentialKey::DeviceId).unwrap().is_none());
    }

    #[test]
    fn device_names_are_labels() {
        assert!(Device::new(4, "laptop", Platform::Macos, "install-1").is_ok());
        assert!(Device::new(4, "bad name", Platform::Macos, "install-1").is_err());
        assert!(Device::new(4, "laptop", Platform::Macos, "").is_err());
    }
}
