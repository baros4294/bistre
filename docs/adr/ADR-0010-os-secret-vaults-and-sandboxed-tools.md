# ADR-0010: OS Secret Vaults, Capability-Scoped File Edits & Kernel-Bound Shell Cleanup

- **Status**: Accepted
- **Date**: 2026-11-21
- **Deciders**: Bistre Principal Architecture

## Context & Live-Verified Evidence
- Android `androidx.security:security-crypto` (`EncryptedSharedPreferences`) is officially deprecated in 1.1.0 (`developer.android.com`, verified 2026-11-21).
- Headless Linux and non-GNOME Wayland environments frequently lack D-Bus activation for `org.freedesktop.secrets` (`linux-credentials/oo7#603`).
- Naive path string joins suffer symlink-swap TOCTOU vulnerabilities, Windows Defender transiently locks newly written temp files (`ERROR_SHARING_VIOLATION`), and killing a shell parent leaves orphaned grandchild processes running.

## Decision
1. Define a single `SecretVault` trait in `crates/bistre-crypto` using `Zeroizing<Vec<u8>>`:
   - Android: Direct Android Keystore non-exportable `AES-256-GCM` key (StrongBox/TEE) wrapping an encrypted vault file with `android:allowBackup="false"`.
   - Windows: DPAPI (`CryptProtectData` `CurrentUser`).
   - Linux: `oo7` Secret Service D-Bus backend with automatic Argon2id + XChaCha20-Poly1305 passphrase-locked file vault fallback.
2. Perform all workspace edits through `cap-std 4.0.3` `Dir` capability handles (`openat2`/`O_NOFOLLOW`), verifying `blake3` line-range hash anchors prior to atomic temp-file swap (3-step exponential retry on Windows `ERROR_SHARING_VIOLATION`) and pre-image snapshot capture for 1-tap rewind.
3. Bind every spawned child to Bistre's lifetime. The audited `unsafe` lives in `bistre_crypto::containment` (`bistre-core` stays `unsafe`-free): on Windows `process_util::spawn_contained` puts each child in its own anonymous `KillOnCloseJob` (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, non-inheritable handle, closed on drop); on Linux/Android `no_window_command` installs `PR_SET_PDEATHSIG(SIGKILL)` plus a parent-PID re-check in `pre_exec`, and every child leads its own process group (`process_group(0)`). On timeout `run_bounded` keeps the root alive, walks the live tree (`taskkill /T /F` or a group `SIGKILL`), terminates the job, and only then kills and reaps the root. `pidfd` reaping is not used: the process-group kill already covers the tree.
4. Ban `openssl-sys` via `deny.toml`; use `rustls` + `rustls-platform-verifier 0.7.1`.

**Implementation (2026-11-23)**: all decisions are implemented. Android and Linux share one envelope format in `bistre-crypto` (XChaCha20-Poly1305 via `chacha20poly1305 0.11.0`, entry name as associated data, Argon2id via `argon2 0.6.0` for the passphrase fallback, `getrandom 0.4.3`); only the data key's home differs (Android Keystore wrap in `VaultKeyStore.kt`; Linux `oo7 0.7.1` Secret Service in `bistre_core::vault_key`, `tokio` + `native_crypto`, no OpenSSL). Plaintext entries from earlier builds are migrated on first open; a changed key sets the old vault aside instead of failing (Spec 07 §2). Verification: `bistre-crypto` tests `sealed_vault_encrypts_at_rest_and_survives_reopen`, `plaintext_entries_from_older_versions_are_encrypted_on_open`, `a_changed_key_sets_the_old_vault_aside_instead_of_failing`, `keyless_vault_reads_legacy_entries_but_never_writes_plaintext`, and `sealed::tests` (the first three fail if sealing leaks plaintext); the Linux resolver is type-checked against `oo7` for `x86_64-unknown-linux-gnu`; the Keystore wrap is compiled with Gradle. On-device runs (Android Keystore / StrongBox, a live Secret Service) still need real hardware.

## Rejected Alternatives
- **`EncryptedSharedPreferences`**: Deprecated upstream with unpatched keystore corruption edge cases.
- **Unscoped `std::fs` path joins & plain `Command::kill()`**: Vulnerable to symlink escapes and leaked grandchild processes.

## Consequences & Verification
- Verified via `bistre-crypto` vault round-trip tests, `deny.toml` OpenSSL ban, and Wave 1 tool sandbox/TOCTOU tests. Containment: `containment::tests::job_objects_are_independent_and_reject_null_handles`, `process_util::tests::spawned_children_join_the_kill_on_close_job` (fails without the job assignment), and `process_util::tests::timeout_kills_grandchildren_before_they_outlive_the_shell` (fails when the root is killed before the tree walk, the pre-2026-11-23 behavior).
- `PR_SET_PDEATHSIG` follows the spawning *thread*: children are spawned from long-lived Tokio worker threads, never from `spawn_blocking`. A grandchild can leave a Windows job when an ancestor job allows silent breakaway (observed under the developer test runner), which is why the live tree walk runs before the job is terminated.
- `clippy.toml` bans direct `tokio::process::Command::{spawn, output, status}`; `spawn_contained` and `run_bounded` are the only spawn paths (`run_bounded` caps each captured stream at `MAX_CAPTURE_BYTES` = 32 MiB and drains the rest).
