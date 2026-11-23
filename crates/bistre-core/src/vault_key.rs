//! Resolves the key that seals the Linux secret vault (ADR-0010, `SECURITY.md`).
//!
//! - Android: the key is created and wrapped by the Android Keystore in the app's Kotlin host and
//!   handed to `init_runtime`, so this module is not consulted.
//! - Windows: DPAPI protects entries without a separate key.
//! - Linux: `BISTRE_VAULT_PASSPHRASE` (headless / systemd credentials) derives the key with
//!   Argon2id; otherwise the key lives in the Secret Service (`oo7`, D-Bus or the Flatpak portal).
//!   Without either, the vault stays read-only for old plaintext entries and refuses new writes.

use std::path::Path;

use bistre_crypto::VaultKey;

/// Environment variable holding a passphrase for headless Linux hosts without a Secret Service.
pub const VAULT_PASSPHRASE_ENV: &str = "BISTRE_VAULT_PASSPHRASE";

/// Returns the platform vault key for `data_dir`, or `None` when this platform needs none
/// (Windows) or no key source is available (logged; writes are then refused).
#[cfg(target_os = "linux")]
pub async fn resolve_vault_key(data_dir: &Path) -> Option<VaultKey> {
    if let Some(passphrase) = std::env::var_os(VAULT_PASSPHRASE_ENV).filter(|v| !v.is_empty()) {
        let passphrase = zeroize::Zeroizing::new(passphrase.into_encoded_bytes());
        return match bistre_crypto::sealed::passphrase_vault_key(data_dir, &passphrase) {
            Ok(key) => Some(key),
            Err(err) => {
                tracing::warn!(
                    key = err.key.as_key(),
                    "vault passphrase key derivation failed"
                );
                None
            }
        };
    }
    match secret_service_key(data_dir).await {
        Ok(key) => Some(key),
        Err(err) => {
            tracing::warn!(
                key = err.key.as_key(),
                detail = err.detail_code.as_deref().unwrap_or(""),
                "no Secret Service vault key; new API keys cannot be stored until one is available"
            );
            None
        }
    }
}

/// Returns the platform vault key for `data_dir`, or `None` when this platform needs none
/// (Windows) or no key source is available (logged; writes are then refused).
#[cfg(not(target_os = "linux"))]
#[expect(
    clippy::unused_async,
    reason = "Same async signature as the Linux Secret Service resolver."
)]
pub async fn resolve_vault_key(_data_dir: &Path) -> Option<VaultKey> {
    None
}

#[cfg(target_os = "linux")]
async fn secret_service_key(data_dir: &Path) -> bistre_protocol::BistreResult<VaultKey> {
    use bistre_protocol::{BistreError, DiagnosticKey};

    let fail = |detail: &'static str| {
        move |_| BistreError::with_detail(DiagnosticKey::CryptoVaultUnavailable, detail)
    };
    let dir = data_dir.to_string_lossy().into_owned();
    let attributes = [
        ("application", "bistre"),
        ("purpose", "vault-key"),
        ("data_dir", dir.as_str()),
    ];
    let keyring = oo7::Keyring::new()
        .await
        .map_err(fail("secret_service_unavailable"))?;
    keyring
        .unlock()
        .await
        .map_err(fail("secret_service_locked"))?;
    let mut items = keyring
        .search_items(&attributes)
        .await
        .map_err(fail("secret_service_search"))?;
    if items.is_empty() {
        let key = VaultKey::generate()?;
        keyring
            .create_item(
                "Bistre secret vault key",
                &attributes,
                oo7::Secret::blob(key.as_bytes()),
                true,
            )
            .await
            .map_err(fail("secret_service_store"))?;
        // Read back so two processes starting together converge on the stored key.
        items = keyring
            .search_items(&attributes)
            .await
            .map_err(fail("secret_service_search"))?;
    }
    let item = items.first().ok_or_else(|| {
        BistreError::with_detail(
            DiagnosticKey::CryptoVaultUnavailable,
            "secret_service_store",
        )
    })?;
    item.unlock().await.map_err(fail("secret_service_locked"))?;
    let secret = item.secret().await.map_err(fail("secret_service_read"))?;
    VaultKey::from_slice(secret.as_bytes())
}
