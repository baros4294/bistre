//! Envelope encryption for the Linux/Android secret vault (ADR-0010).
//!
//! Each vault entry is sealed with XChaCha20-Poly1305 under a 32-byte [`VaultKey`], using a
//! fresh random 24-byte nonce and the entry's name as associated data, so a ciphertext cannot be
//! moved to another entry. The key itself never touches the vault file: it comes from the Android
//! Keystore (a Keystore-wrapped data key), the Linux Secret Service, or an Argon2id derivation of
//! `BISTRE_VAULT_PASSPHRASE` with a per-data-directory salt ([`passphrase_vault_key`]).

use core::fmt;
use std::path::Path;

use argon2::Argon2;
use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use chacha20poly1305::aead::{Aead, Payload};
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce};
use zeroize::Zeroizing;

/// Prefix marking a sealed (encrypted) vault entry; entries without it are legacy plaintext.
pub const SEALED_PREFIX: &str = "x1:";

/// Length of a vault data key in bytes.
pub const VAULT_KEY_LEN: usize = 32;

const NONCE_LEN: usize = 24;
const SALT_LEN: usize = 16;

/// Salt file kept beside the vault for passphrase-derived keys (not secret, `0600`).
pub const PASSPHRASE_SALT_FILE: &str = "bistre_vault.salt";

fn vault_err(detail: &str) -> BistreError {
    BistreError::with_detail(DiagnosticKey::CryptoVaultUnavailable, detail)
}

/// 32-byte vault data key, zeroized on drop and never printed.
pub struct VaultKey(Zeroizing<[u8; VAULT_KEY_LEN]>);

impl fmt::Debug for VaultKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("VaultKey(..)")
    }
}

impl VaultKey {
    /// Generates a fresh random key from the OS CSPRNG.
    pub fn generate() -> BistreResult<Self> {
        let mut bytes = Zeroizing::new([0_u8; VAULT_KEY_LEN]);
        getrandom::fill(bytes.as_mut_slice()).map_err(|_| vault_err("rng_unavailable"))?;
        Ok(Self(bytes))
    }

    /// Wraps exactly [`VAULT_KEY_LEN`] key bytes handed over by a platform key store.
    pub fn from_slice(bytes: &[u8]) -> BistreResult<Self> {
        let array: [u8; VAULT_KEY_LEN] = bytes
            .try_into()
            .map_err(|_| vault_err("vault_key_length"))?;
        Ok(Self(Zeroizing::new(array)))
    }

    /// Raw key bytes, for handing to a platform key store only.
    pub fn as_bytes(&self) -> &[u8; VAULT_KEY_LEN] {
        &self.0
    }

    fn cipher(&self) -> BistreResult<XChaCha20Poly1305> {
        XChaCha20Poly1305::new_from_slice(self.0.as_slice())
            .map_err(|_| vault_err("vault_key_length"))
    }
}

/// Seals `plain` for the vault entry `name` into a `x1:<hex(nonce || ciphertext)>` string.
pub fn seal(key: &VaultKey, name: &str, plain: &[u8]) -> BistreResult<String> {
    let mut nonce = [0_u8; NONCE_LEN];
    getrandom::fill(&mut nonce).map_err(|_| vault_err("rng_unavailable"))?;
    let sealed = key
        .cipher()?
        .encrypt(
            &XNonce::from(nonce),
            Payload {
                msg: plain,
                aad: name.as_bytes(),
            },
        )
        .map_err(|_| vault_err("vault_seal_failed"))?;
    let mut blob = Vec::with_capacity(NONCE_LEN + sealed.len());
    blob.extend_from_slice(&nonce);
    blob.extend_from_slice(&sealed);
    Ok(format!("{SEALED_PREFIX}{}", hex::encode(blob)))
}

/// Opens a value produced by [`seal`] for the same entry `name`; a wrong key, a tampered value,
/// or a value moved from another entry fails authentication.
pub fn unseal(key: &VaultKey, name: &str, value: &str) -> BistreResult<Zeroizing<Vec<u8>>> {
    let hex_blob = value
        .strip_prefix(SEALED_PREFIX)
        .ok_or_else(|| vault_err("vault_entry_not_sealed"))?;
    let blob = hex::decode(hex_blob).map_err(|_| vault_err("vault_entry_corrupt"))?;
    if blob.len() < NONCE_LEN {
        return Err(vault_err("vault_entry_corrupt"));
    }
    let (nonce, sealed) = blob.split_at(NONCE_LEN);
    let nonce: [u8; NONCE_LEN] = nonce
        .try_into()
        .map_err(|_| vault_err("vault_entry_corrupt"))?;
    let plain = key
        .cipher()?
        .decrypt(
            &XNonce::from(nonce),
            Payload {
                msg: sealed,
                aad: name.as_bytes(),
            },
        )
        .map_err(|_| vault_err("vault_key_mismatch"))?;
    Ok(Zeroizing::new(plain))
}

/// Derives the vault key from a passphrase with Argon2id (library defaults: 19 MiB, t = 2, p = 1)
/// and the data directory's random salt, creating the salt file on first use.
pub fn passphrase_vault_key(data_dir: &Path, passphrase: &[u8]) -> BistreResult<VaultKey> {
    if passphrase.is_empty() {
        return Err(vault_err("vault_passphrase_empty"));
    }
    let salt = load_or_create_salt(&data_dir.join(PASSPHRASE_SALT_FILE))?;
    let mut out = Zeroizing::new([0_u8; VAULT_KEY_LEN]);
    Argon2::default()
        .hash_password_into(passphrase, &salt, out.as_mut_slice())
        .map_err(|_| vault_err("vault_passphrase_kdf"))?;
    Ok(VaultKey(out))
}

fn load_or_create_salt(path: &Path) -> BistreResult<[u8; SALT_LEN]> {
    match std::fs::read_to_string(path) {
        Ok(raw) => {
            let bytes = hex::decode(raw.trim()).map_err(|_| vault_err("vault_salt_corrupt"))?;
            bytes
                .try_into()
                .map_err(|_| vault_err("vault_salt_corrupt"))
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            let mut salt = [0_u8; SALT_LEN];
            getrandom::fill(&mut salt).map_err(|_| vault_err("rng_unavailable"))?;
            crate::write_atomic_restricted(path, hex::encode(salt).as_bytes())?;
            Ok(salt)
        }
        Err(_) => Err(vault_err("vault_salt_unreadable")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seal_round_trips_and_binds_the_entry_name() -> Result<(), Box<dyn std::error::Error>> {
        let key = VaultKey::generate()?;
        let sealed = seal(&key, "provider:openai", b"sk-secret")?;
        assert!(sealed.starts_with(SEALED_PREFIX));
        assert!(!sealed.contains(&hex::encode(b"sk-secret")));
        let opened = unseal(&key, "provider:openai", &sealed)?;
        assert_eq!(opened.as_slice(), b"sk-secret".as_slice());
        // Moving the ciphertext to another entry or using another key fails.
        assert!(unseal(&key, "provider:anthropic", &sealed).is_err());
        let other = VaultKey::generate()?;
        assert!(unseal(&other, "provider:openai", &sealed).is_err());
        Ok(())
    }

    #[test]
    fn passphrase_keys_are_stable_per_salt_and_differ_by_passphrase()
    -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let a = passphrase_vault_key(dir.path(), b"correct horse");
        let b = passphrase_vault_key(dir.path(), b"correct horse");
        let c = passphrase_vault_key(dir.path(), b"wrong horse");
        assert!(a.is_ok() && b.is_ok() && c.is_ok());
        if let (Ok(a), Ok(b), Ok(c)) = (a, b, c) {
            assert_eq!(a.as_bytes(), b.as_bytes());
            assert_ne!(a.as_bytes(), c.as_bytes());
        }
        assert!(passphrase_vault_key(dir.path(), b"").is_err());
        assert!(VaultKey::from_slice(&[0_u8; 31]).is_err());
        Ok(())
    }
}
