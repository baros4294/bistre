//! Cryptographic verification (`minisign-verify`), SHA-256 digest checks,
//! OS secret vault implementations, and child-process containment shims for Bistre (ADR-0010).
//!
//! Invariants:
//! - Offline Ed25519 signature verification via zero-dependency `minisign-verify 0.3`.
//! - Zero secret values logged; secrets wrapped in `Zeroizing<Vec<u8>>`.
//! - API keys remain locked to the execution node's `SecretVault`.

pub mod containment;
pub mod sealed;

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, RwLock};

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, SignedPackManifest};
use minisign_verify::{PublicKey, Signature};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

pub use sealed::VaultKey;

/// Computes lowercase hex-encoded SHA-256 digest of `payload`.
pub fn sha256_hex(payload: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(payload);
    hex::encode(hasher.finalize())
}

/// Incremental SHA-256 for streamed payloads (OTA downloads hash 64 KiB chunks as they arrive).
#[derive(Debug, Clone, Default)]
pub struct Sha256Stream {
    hasher: Sha256,
}

impl Sha256Stream {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn update(&mut self, chunk: &[u8]) {
        self.hasher.update(chunk);
    }

    /// Finishes the digest as lowercase hex.
    pub fn finalize_hex(self) -> String {
        hex::encode(self.hasher.finalize())
    }
}

/// Verifies a Minisign Ed25519 signature over `payload` against a base64-encoded public key.
///
/// Rejects legacy (non-prehashed) signatures unless explicitly encoded as valid minisign format,
/// enforcing strict Ed25519 verification with zero external C crypto dependencies.
pub fn verify_minisign_bytes(
    public_key_b64: &str,
    payload: &[u8],
    signature_text: &str,
) -> BistreResult<()> {
    let pk = PublicKey::from_base64(public_key_b64.trim()).map_err(|_| {
        BistreError::with_detail(DiagnosticKey::CryptoSignatureInvalid, "invalid_public_key")
    })?;
    let sig = Signature::decode(signature_text.trim()).map_err(|_| {
        BistreError::with_detail(
            DiagnosticKey::CryptoSignatureInvalid,
            "invalid_signature_format",
        )
    })?;
    pk.verify(payload, &sig, false).map_err(|_| {
        BistreError::with_detail(DiagnosticKey::CryptoSignatureInvalid, "signature_mismatch")
    })?;
    Ok(())
}

/// Verifies a signed pack manifest AND verifies that `pack_payload` matches `manifest.sha256_hex`.
pub fn verify_signed_pack(
    public_key_b64: &str,
    manifest_bytes: &[u8],
    manifest_sig_text: &str,
    pack_payload: &[u8],
) -> BistreResult<SignedPackManifest> {
    verify_minisign_bytes(public_key_b64, manifest_bytes, manifest_sig_text)?;
    let manifest: SignedPackManifest = serde_json_from_slice(manifest_bytes)?;
    let actual_hash = sha256_hex(pack_payload);
    if !constant_time_eq_ascii(
        actual_hash.as_bytes(),
        manifest.sha256_hex.trim().as_bytes(),
    ) {
        return Err(BistreError::with_detail(
            DiagnosticKey::CryptoSignatureInvalid,
            "payload_sha256_mismatch",
        ));
    }
    Ok(manifest)
}

fn serde_json_from_slice(bytes: &[u8]) -> BistreResult<SignedPackManifest> {
    let text = core::str::from_utf8(bytes).map_err(|_| {
        BistreError::with_detail(DiagnosticKey::CryptoSignatureInvalid, "manifest_utf8")
    })?;
    serde_json::from_str::<SignedPackManifest>(text).map_err(|_| {
        BistreError::with_detail(DiagnosticKey::CryptoSignatureInvalid, "manifest_json")
    })
}

/// Constant-time equality over byte slices of equal length.
fn constant_time_eq_ascii(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x.to_ascii_lowercase() ^ y.to_ascii_lowercase();
    }
    diff == 0
}

/// Execution-node-local secret storage boundary (ADR-0010).
///
/// Platform implementations ([`LocalSecretVault`]):
/// - Windows: DPAPI (`CryptProtectData` `CurrentUser`) encrypted entries persisted in `data_dir`.
/// - Linux/Android: XChaCha20-Poly1305 entries ([`sealed`]) under a key held by the Android
///   Keystore, the Linux Secret Service, or derived from `BISTRE_VAULT_PASSPHRASE`.
pub trait SecretVault: Send + Sync {
    fn put(&self, key: &str, secret: &[u8]) -> BistreResult<()>;
    fn get(&self, key: &str) -> BistreResult<Option<Zeroizing<Vec<u8>>>>;
    fn delete(&self, key: &str) -> BistreResult<()>;
    fn contains(&self, key: &str) -> BistreResult<bool> {
        Ok(self.get(key)?.is_some())
    }
}

/// Deterministic in-memory vault for unit tests and ephemeral sandbox runs.
#[derive(Debug, Default)]
pub struct EphemeralVault {
    entries: RwLock<HashMap<String, Zeroizing<Vec<u8>>>>,
}

impl EphemeralVault {
    pub fn new() -> Self {
        Self::default()
    }
}

impl SecretVault for EphemeralVault {
    fn put(&self, key: &str, secret: &[u8]) -> BistreResult<()> {
        let mut guard = self
            .entries
            .write()
            .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))?;
        guard.insert(key.to_owned(), Zeroizing::new(secret.to_vec()));
        Ok(())
    }

    fn get(&self, key: &str) -> BistreResult<Option<Zeroizing<Vec<u8>>>> {
        let guard = self
            .entries
            .read()
            .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))?;
        Ok(guard.get(key).cloned())
    }

    fn delete(&self, key: &str) -> BistreResult<()> {
        let mut guard = self
            .entries
            .write()
            .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))?;
        guard.remove(key);
        Ok(())
    }
}

/// Reserved entry holding a sealed constant, used to detect that the vault key changed.
const KEY_CHECK_ENTRY: &str = "__bistre_vault_check__";
const KEY_CHECK_PLAIN: &[u8] = b"bistre-vault-check-v1";
const RESERVED_PREFIX: &str = "__bistre_";

/// How [`LocalSecretVault`] protects entries at rest.
#[derive(Debug)]
pub enum VaultProtection {
    /// Windows DPAPI (`CryptProtectData` `CurrentUser`) per entry.
    #[cfg(windows)]
    Dpapi,
    /// XChaCha20-Poly1305 per entry under a platform-held key (Linux/Android).
    Sealed(VaultKey),
    /// No key source is available (Linux/Android without Keystore, Secret Service, or
    /// passphrase): existing plaintext entries from older versions stay readable so the app keeps
    /// working until a key source appears, but no new secret is ever written unencrypted.
    Unavailable,
}

/// Persistent node-local secret vault inside `<data_dir>` (ADR-0010).
#[derive(Debug)]
pub struct LocalSecretVault {
    vault_path: PathBuf,
    protection: VaultProtection,
    lock: Mutex<()>,
}

impl LocalSecretVault {
    /// Opens the vault in `data_dir`. With `key`, entries are sealed and any plaintext entries
    /// left by older versions are encrypted in place. Without a key, Windows uses DPAPI and
    /// Linux/Android open read-only for legacy entries ([`VaultProtection::Unavailable`]).
    ///
    /// If the vault was sealed under a different key (for example a reset keyring), the
    /// unreadable file is set aside as `bistre_vault.local.json.key-mismatch-<unix-ms>` and a fresh
    /// vault starts, so the app stays usable and the old file can still be recovered.
    pub fn open(data_dir: impl AsRef<Path>, key: Option<VaultKey>) -> BistreResult<Self> {
        let protection = match key {
            Some(key) => VaultProtection::Sealed(key),
            #[cfg(windows)]
            None => VaultProtection::Dpapi,
            #[cfg(not(windows))]
            None => VaultProtection::Unavailable,
        };
        Self::with_protection(data_dir.as_ref(), protection)
    }

    fn with_protection(dir: &Path, protection: VaultProtection) -> BistreResult<Self> {
        std::fs::create_dir_all(dir)
            .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))?;
        let filename = match protection {
            #[cfg(windows)]
            VaultProtection::Dpapi => "bistre_vault.dpapi.json",
            VaultProtection::Sealed(_) | VaultProtection::Unavailable => "bistre_vault.local.json",
        };
        let vault = Self {
            vault_path: dir.join(filename),
            protection,
            lock: Mutex::new(()),
        };
        if let VaultProtection::Sealed(key) = &vault.protection {
            vault.migrate_and_check(key)?;
        }
        Ok(vault)
    }

    /// `true` when new secrets are encrypted at rest.
    pub fn is_encrypted(&self) -> bool {
        !matches!(self.protection, VaultProtection::Unavailable)
    }

    fn migrate_and_check(&self, key: &VaultKey) -> BistreResult<()> {
        let mut map = self.read_map()?;
        if let Some(check) = map.get(KEY_CHECK_ENTRY)
            && sealed::unseal(key, KEY_CHECK_ENTRY, check).is_err()
        {
            self.set_aside_unreadable()?;
            map.clear();
        }
        let mut changed = false;
        for (name, value) in &mut map {
            if name.starts_with(RESERVED_PREFIX) || value.starts_with(sealed::SEALED_PREFIX) {
                continue;
            }
            let plain = Zeroizing::new(
                hex::decode(value.as_str())
                    .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))?,
            );
            *value = sealed::seal(key, name, &plain)?;
            changed = true;
        }
        if !map.contains_key(KEY_CHECK_ENTRY) {
            map.insert(
                KEY_CHECK_ENTRY.to_owned(),
                sealed::seal(key, KEY_CHECK_ENTRY, KEY_CHECK_PLAIN)?,
            );
            changed = true;
        }
        if changed {
            self.write_map(&map)?;
        }
        Ok(())
    }

    fn set_aside_unreadable(&self) -> BistreResult<()> {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis());
        let mut aside = self.vault_path.clone().into_os_string();
        aside.push(format!(".key-mismatch-{stamp}"));
        std::fs::rename(&self.vault_path, PathBuf::from(aside)).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::CryptoVaultUnavailable, "vault_set_aside")
        })
    }

    fn read_map(&self) -> BistreResult<BTreeMap<String, String>> {
        let raw = match std::fs::read_to_string(&self.vault_path) {
            Ok(raw) => raw,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(BTreeMap::new()),
            Err(_) => return Err(BistreError::new(DiagnosticKey::CryptoVaultUnavailable)),
        };
        if raw.trim().is_empty() {
            return Ok(BTreeMap::new());
        }
        serde_json::from_str::<BTreeMap<String, String>>(&raw)
            .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))
    }

    fn write_map(&self, map: &BTreeMap<String, String>) -> BistreResult<()> {
        let encoded = serde_json::to_string_pretty(map)
            .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))?;
        write_atomic_restricted(&self.vault_path, encoded.as_bytes())
    }

    fn lock(&self) -> BistreResult<std::sync::MutexGuard<'_, ()>> {
        self.lock
            .lock()
            .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))
    }
}

fn reject_reserved(key: &str) -> BistreResult<()> {
    if key.starts_with(RESERVED_PREFIX) {
        return Err(BistreError::with_detail(
            DiagnosticKey::InternalError,
            "reserved_vault_key",
        ));
    }
    Ok(())
}

impl SecretVault for LocalSecretVault {
    fn put(&self, key: &str, secret: &[u8]) -> BistreResult<()> {
        reject_reserved(key)?;
        let _guard = self.lock()?;
        let value = match &self.protection {
            #[cfg(windows)]
            VaultProtection::Dpapi => hex::encode(protect_bytes(secret)?),
            VaultProtection::Sealed(vault_key) => sealed::seal(vault_key, key, secret)?,
            VaultProtection::Unavailable => {
                return Err(BistreError::with_detail(
                    DiagnosticKey::CryptoVaultUnavailable,
                    "no_vault_key",
                ));
            }
        };
        let mut map = self.read_map()?;
        map.insert(key.to_owned(), value);
        self.write_map(&map)
    }

    fn get(&self, key: &str) -> BistreResult<Option<Zeroizing<Vec<u8>>>> {
        reject_reserved(key)?;
        let _guard = self.lock()?;
        let map = self.read_map()?;
        let Some(value) = map.get(key) else {
            return Ok(None);
        };
        let plain = match &self.protection {
            #[cfg(windows)]
            VaultProtection::Dpapi => unprotect_bytes(
                &hex::decode(value)
                    .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))?,
            )?,
            VaultProtection::Sealed(vault_key) if value.starts_with(sealed::SEALED_PREFIX) => {
                sealed::unseal(vault_key, key, value)?
            }
            VaultProtection::Unavailable if value.starts_with(sealed::SEALED_PREFIX) => {
                return Err(BistreError::with_detail(
                    DiagnosticKey::CryptoVaultUnavailable,
                    "no_vault_key",
                ));
            }
            // Legacy plaintext written by an older version (migrated on the next keyed open).
            VaultProtection::Sealed(_) | VaultProtection::Unavailable => Zeroizing::new(
                hex::decode(value)
                    .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))?,
            ),
        };
        Ok(Some(plain))
    }

    fn delete(&self, key: &str) -> BistreResult<()> {
        reject_reserved(key)?;
        let _guard = self.lock()?;
        let mut map = self.read_map()?;
        if map.remove(key).is_some() {
            self.write_map(&map)?;
        }
        Ok(())
    }

    fn contains(&self, key: &str) -> BistreResult<bool> {
        reject_reserved(key)?;
        let _guard = self.lock()?;
        Ok(self.read_map()?.contains_key(key))
    }
}

/// Atomically replaces `path` with `bytes`: owner-only (`0o600` on Unix) temp file, `sync_all`,
/// then rename over the target.
pub(crate) fn write_atomic_restricted(path: &Path, bytes: &[u8]) -> BistreResult<()> {
    use std::io::Write;

    let vault_err = || BistreError::new(DiagnosticKey::CryptoVaultUnavailable);
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    let mut options = std::fs::OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&tmp).map_err(|_| vault_err())?;
    file.write_all(bytes).map_err(|_| vault_err())?;
    file.sync_all().map_err(|_| vault_err())?;
    drop(file);
    std::fs::rename(&tmp, path).map_err(|_| vault_err())
}

#[cfg(windows)]
#[expect(
    unsafe_code,
    reason = "Audited Win32 DPAPI FFI wrapper for CurrentUser secret protection (ADR-0010)."
)]
fn protect_bytes(plain: &[u8]) -> BistreResult<Vec<u8>> {
    use core::ptr;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData,
    };

    let len = u32::try_from(plain.len())
        .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))?;
    let mut input_buf = Zeroizing::new(plain.to_vec());
    let in_blob = CRYPT_INTEGER_BLOB {
        cbData: len,
        pbData: input_buf.as_mut_ptr(),
    };
    let mut out_blob = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: ptr::null_mut(),
    };

    // SAFETY: `in_blob` points to valid memory for `len` bytes; `out_blob` is initialized
    // and written by Windows DPAPI. Returned buffer is freed via `LocalFree` immediately after copy.
    let ok = unsafe {
        CryptProtectData(
            &raw const in_blob,
            ptr::null(),
            ptr::null(),
            ptr::null_mut(),
            ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &raw mut out_blob,
        )
    };
    if ok == 0 || out_blob.pbData.is_null() {
        return Err(BistreError::new(DiagnosticKey::CryptoVaultUnavailable));
    }

    let out_len = usize::try_from(out_blob.cbData)
        .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))?;
    // SAFETY: DPAPI returned success with `out_blob.pbData` valid for `out_len` bytes, allocated
    // with `LocalAlloc`, which we copy into an owned Vec and immediately free with `LocalFree`.
    let result = unsafe {
        let slice = core::slice::from_raw_parts(out_blob.pbData, out_len);
        let vec = slice.to_vec();
        let freed = LocalFree(out_blob.pbData.cast());
        debug_assert!(freed.is_null(), "LocalFree failed for a DPAPI buffer");
        vec
    };
    Ok(result)
}

#[cfg(windows)]
#[expect(
    unsafe_code,
    reason = "Audited Win32 DPAPI FFI wrapper for CurrentUser secret unprotection (ADR-0010)."
)]
fn unprotect_bytes(cipher: &[u8]) -> BistreResult<Zeroizing<Vec<u8>>> {
    use core::ptr;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptUnprotectData,
    };

    let len = u32::try_from(cipher.len())
        .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))?;
    let mut cipher_buf = cipher.to_vec();
    let in_blob = CRYPT_INTEGER_BLOB {
        cbData: len,
        pbData: cipher_buf.as_mut_ptr(),
    };
    let mut out_blob = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: ptr::null_mut(),
    };

    // SAFETY: `in_blob` points to valid memory for `len` bytes; `out_blob` is initialized
    // and populated by Windows DPAPI. We zero and free the DPAPI plaintext buffer before returning.
    let ok = unsafe {
        CryptUnprotectData(
            &raw const in_blob,
            ptr::null_mut(),
            ptr::null(),
            ptr::null_mut(),
            ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &raw mut out_blob,
        )
    };
    if ok == 0 || out_blob.pbData.is_null() {
        return Err(BistreError::new(DiagnosticKey::CryptoVaultUnavailable));
    }

    let out_len = usize::try_from(out_blob.cbData)
        .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))?;
    // SAFETY: DPAPI returned success with `out_blob.pbData` valid for `out_len` bytes.
    // We copy into `Zeroizing<Vec<u8>>`, zero the DPAPI buffer in place, and free via `LocalFree`.
    let plain = unsafe {
        let slice = core::slice::from_raw_parts_mut(out_blob.pbData, out_len);
        let owned = Zeroizing::new(slice.to_vec());
        slice.fill(0);
        let freed = LocalFree(out_blob.pbData.cast());
        debug_assert!(freed.is_null(), "LocalFree failed for a DPAPI buffer");
        owned
    };
    Ok(plain)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    // Official minisign-verify 0.3.0 RFC test vector (payload = b"test").
    const TEST_PK: &str = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
    const TEST_SIG: &str = "untrusted comment: signature from minisign secret key\n\
RUQf6LRCGA9i559r3g7V1qNyJDApGip8MfqcadIgT9CuhV3EMhHoN1mGTkUidF/z7SrlQgXdy8ofjb7bNJJylDOocrCo8KLzZwo=\n\
trusted comment: timestamp:1633700835\tfile:test\tprehashed\n\
wLMDjy9FLAuxZ3q4NlEvkgtyhrr0gtTu6KC4KBJdITbbOeAi1zBIYo0v4iTgt8jJpIidRJnp94ABQkJAgAooBQ==";

    #[test]
    fn minisign_valid_signature_succeeds() {
        let res = verify_minisign_bytes(TEST_PK, b"test", TEST_SIG);
        assert!(res.is_ok());
    }

    #[test]
    fn minisign_tampered_payload_fails() {
        let res = verify_minisign_bytes(TEST_PK, b"tampered", TEST_SIG);
        assert_eq!(
            res.err().map(|e| e.key),
            Some(DiagnosticKey::CryptoSignatureInvalid)
        );
    }

    #[test]
    fn minisign_wrong_key_fails() {
        let wrong_pk = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO4";
        let res = verify_minisign_bytes(wrong_pk, b"test", TEST_SIG);
        assert_eq!(
            res.err().map(|e| e.key),
            Some(DiagnosticKey::CryptoSignatureInvalid)
        );
    }

    #[test]
    fn ephemeral_vault_round_trips_and_deletes() {
        let vault = EphemeralVault::new();
        assert!(vault.put("openai_key", b"dummy-secret-value").is_ok());
        let fetched = vault.get("openai_key").ok().flatten();
        assert_eq!(
            fetched.as_deref().map(Vec::as_slice),
            Some(b"dummy-secret-value".as_slice())
        );
        assert!(vault.delete("openai_key").is_ok());
        assert_eq!(vault.get("openai_key").ok().flatten(), None);
    }

    #[cfg(windows)]
    #[test]
    fn local_secret_vault_persists_and_encrypts_on_windows() {
        let dir = tempdir().ok();
        assert!(dir.is_some());
        let Some(dir) = dir else { return };

        let secret = b"sk-test-local-vault-secret-987654";
        let vault = LocalSecretVault::open(dir.path(), None).ok();
        assert!(vault.is_some());
        let Some(vault) = vault else { return };

        assert!(vault.put("provider:openai", secret).is_ok());
        assert_eq!(vault.contains("provider:openai").ok(), Some(true));

        // Reopen fresh handle to verify durability across restarts.
        let reopened = LocalSecretVault::open(dir.path(), None).ok();
        assert!(reopened.is_some());
        let Some(reopened) = reopened else { return };
        let decrypted = reopened.get("provider:openai").ok().flatten();
        assert_eq!(
            decrypted.as_deref().map(Vec::as_slice),
            Some(secret.as_slice())
        );

        let on_disk = std::fs::read_to_string(dir.path().join("bistre_vault.dpapi.json")).ok();
        assert!(on_disk.is_some());
        if let Some(raw) = on_disk {
            assert!(!raw.contains("sk-test-local-vault-secret-987654"));
            assert!(!raw.contains(&hex::encode(secret)));
        }

        assert!(reopened.delete("provider:openai").is_ok());
        assert_eq!(reopened.get("provider:openai").ok().flatten(), None);
    }

    fn sealed_vault(dir: &Path, key: &[u8; 32]) -> Option<LocalSecretVault> {
        let key = VaultKey::from_slice(key).ok()?;
        LocalSecretVault::open(dir, Some(key)).ok()
    }

    #[test]
    fn sealed_vault_encrypts_at_rest_and_survives_reopen() {
        let dir = tempdir().ok();
        let Some(dir) = dir else { return };
        let secret = b"sk-sealed-secret-112233";
        let vault = sealed_vault(dir.path(), &[7_u8; 32]);
        assert!(vault.as_ref().is_some_and(LocalSecretVault::is_encrypted));
        let Some(vault) = vault else { return };
        assert!(vault.put("provider:openai", secret).is_ok());

        let raw = std::fs::read_to_string(dir.path().join("bistre_vault.local.json"));
        assert!(raw.as_ref().is_ok_and(|r| !r.contains(&hex::encode(secret))
            && !r.contains("sk-sealed-secret")
            && r.contains(sealed::SEALED_PREFIX)));

        let reopened = sealed_vault(dir.path(), &[7_u8; 32]);
        let got = reopened
            .as_ref()
            .and_then(|v| v.get("provider:openai").ok().flatten());
        assert_eq!(got.as_deref().map(Vec::as_slice), Some(secret.as_slice()));
        assert!(vault.put(KEY_CHECK_ENTRY, b"x").is_err());
    }

    #[test]
    fn plaintext_entries_from_older_versions_are_encrypted_on_open() {
        let dir = tempdir().ok();
        let Some(dir) = dir else { return };
        let secret = b"sk-legacy-plaintext-445566";
        let legacy = format!("{{\"provider:openai\": \"{}\"}}", hex::encode(secret));
        assert!(std::fs::write(dir.path().join("bistre_vault.local.json"), legacy).is_ok());

        let vault = sealed_vault(dir.path(), &[9_u8; 32]);
        let got = vault
            .as_ref()
            .and_then(|v| v.get("provider:openai").ok().flatten());
        assert_eq!(got.as_deref().map(Vec::as_slice), Some(secret.as_slice()));
        let raw = std::fs::read_to_string(dir.path().join("bistre_vault.local.json"));
        assert!(raw.is_ok_and(|r| !r.contains(&hex::encode(secret))));
    }

    #[test]
    fn a_changed_key_sets_the_old_vault_aside_instead_of_failing() {
        let dir = tempdir().ok();
        let Some(dir) = dir else { return };
        let first = sealed_vault(dir.path(), &[1_u8; 32]);
        assert!(first.is_some_and(|v| v.put("provider:openai", b"sk-old").is_ok()));

        let second = sealed_vault(dir.path(), &[2_u8; 32]);
        assert!(
            second
                .as_ref()
                .is_some_and(|v| v.get("provider:openai").ok().flatten().is_none())
        );
        let set_aside = std::fs::read_dir(dir.path()).map(|entries| {
            entries
                .flatten()
                .any(|e| e.file_name().to_string_lossy().contains(".key-mismatch-"))
        });
        assert!(set_aside.is_ok_and(|found| found));
        assert!(second.is_some_and(|v| v.put("provider:openai", b"sk-new").is_ok()));
    }

    #[test]
    fn keyless_vault_reads_legacy_entries_but_never_writes_plaintext() {
        let dir = tempdir().ok();
        let Some(dir) = dir else { return };
        let legacy = format!("{{\"provider:openai\": \"{}\"}}", hex::encode(b"sk-legacy"));
        assert!(std::fs::write(dir.path().join("bistre_vault.local.json"), legacy).is_ok());
        let vault = LocalSecretVault::with_protection(dir.path(), VaultProtection::Unavailable);
        assert!(vault.as_ref().is_ok_and(|v| !v.is_encrypted()));
        let Ok(vault) = vault else { return };
        let got = vault.get("provider:openai").ok().flatten();
        assert_eq!(
            got.as_deref().map(Vec::as_slice),
            Some(b"sk-legacy".as_slice())
        );
        let refused = vault.put("provider:anthropic", b"sk-new");
        assert!(refused.is_err_and(|e| e.detail_code.as_deref() == Some("no_vault_key")));
        assert!(vault.delete("provider:openai").is_ok());
    }
}
