# Spec 10 — Silent Two-Track OTA Updates & Direct GitHub Distribution

## 1. Cryptographic Trust & Zero-Telemetry Feed
All updates are 100% open-source, self-hostable (configurable feed URL, default GitHub Releases), and zero-telemetry (plain HTTPS GET of static `manifest.json` + `manifest.json.minisig`, zero device identifiers).
- Every manifest and artifact is verified offline via `bistre-crypto` (`minisign-verify 0.3.0`, pinned Ed25519 public key) plus SHA-256 digest match and monotonic anti-rollback version floor before staging.
- Release workflows additionally emit GitHub Sigstore build provenance attestations (`actions/attest-build-provenance`) and a CycloneDX SBOM of the shipped Rust engine (`cargo-cyclonedx`, rejected when it lists fewer than `50` libraries).
- **Windows release smoke check**: the tagged release verifies `bistre_app.exe` `ProductVersion` equals the tag, `ProductName` is `Bistre` (`apps/bistre_app/windows/runner/Runner.rc` carries real product metadata; version flows from `apps/bistre_app/pubspec.yaml`), and `shell32!ExtractIconExW` finds an embedded icon.
- **Supply-chain workflows**: `.github/workflows/codeql.yml` (path-selected `rust` + `actions`, weekly), `.github/workflows/scorecard.yml` (top-level `permissions: {}`, SARIF upload), and zero-checkout `.github/workflows/dependabot-automerge.yml` (merges only minor/patch Dependabot PRs after CI succeeded on the exact head SHA via `gh pr merge --squash --match-head-commit`; Dependabot cooldown stays `7`/`14` days).
- **Workflow lint**: every workflow passes `zizmor --persona auditor` (the CI setting) and `actionlint` (verified locally 2026-11-23 with `zizmor 1.33.1` offline and `actionlint 1.7.12` via `uvx`). Every job has an explicit `name` equal to its check context (matrix values appended as GitHub does by default), every permission beyond `contents: read` carries an explanatory comment, and Rust toolchains install through a `rustup toolchain install "$RUST_VERSION" --profile minimal` script step instead of a third-party toolchain action.
- **Android release signing (when provisioned)**: the keystore is decoded strictly into `$RUNNER_TEMP` with `0600` permissions and removed in an always-run cleanup step, verified as a `PrivateKeyEntry` with `keytool -J-Duser.language=en`, and any certificate whose SHA-256 has ever been exposed publicly is rejected.

## 2. Track A — Zero-Restart Signed Data Packs (All Platforms)
Covers non-executable JSON/binary data only: AIO model catalog snapshots, hot-loadable ICU locale packs, and built-in tool/media OpenAPI schemas.
- Verified atomically via `bistre-core::verify_data_pack` and activated immediately in memory with zero restart.

## 3. Track B — Frictionless Native Binary Updates (Direct GitHub Distribution)
- **Windows (`bistre-updater`)**: Side-by-side layout under `%LocalAppData%\Bistre\versions\<semver>\` fronted by a static launcher (`bistre-launcher.exe`). Never overwrites running `.exe`/`.dll` files or Start Menu `.lnk` shortcuts. Stages verified new version in background; swaps pointer only when `active_runs == 0` (on next idle relaunch or user-accepted restart).
- **Linux**: Self-managed `.AppImage` updates atomically via `.AppImage.new` → `rename()`. **Automatically disables binary self-update** when `FLATPAK_ID`, `SNAP`, or read-only `/usr`/`/opt` package-manager ownership is detected (`detect_update_ownership`), displaying a passive package-manager update notice instead.
- **Android (Direct GitHub APK Only)**: Single `arm64-v8a` 16KB-aligned APK published directly on GitHub Releases (`REQUEST_INSTALL_PACKAGES` in `src/main/AndroidManifest.xml`, `PackageInstaller` session API, Ed25519 manifest verification, and pinned APK signing-cert SHA-256 check; Play Store and F-Droid store flavors removed).

## 4. Active-Run Drain, Expand-Contract DB Safety, UI Surface & 3-Boot Rollback
- **End-User OTA Controls (`crates/bistre-core/src/ota.rs` + `Updates & Storage` Settings view)**: `check_for_updates` fetches the user's configured `manifest.json` + `.minisig`, verifies offline Ed25519 signature + semver floor, surfaces release notes and an Ed25519 verified badge inside `Settings → Updates & Storage`, and stages verified downloads via `stage_update` into `<data_dir>/updates/` with SHA-256 verification.
- Track B NEVER interrupts active LLM streams, agent tasks, or media jobs (`active_runs > 0` flags `active_runs_blocking` and defers swap until idle).
- Expand-Contract SQLite migrations guarantee `N-1` binary compatibility with `N` schema + `.pre-vN.bak` safety copies.
- `LauncherWatchdogState` (`crates/bistre-updater`) tracks `pending_boot_attempts`; if the new binary fails to signal `mark_boot_healthy()` within 15s across 3 consecutive launches (`MAX_CRASH_BOOTS = 3`), the launcher automatically reverts `active_version` to `last_healthy_version`.

## 5. Payload Integrity (`crates/bistre-core/src/ota.rs`)
- Feeds, signatures, and payloads require `https://` (plain `http://` only for loopback test feeds); manifests and signatures are read with a `1 MiB` cap.
- A payload without a SHA-256 (`<64 hex>` or GitHub `asset.digest` `sha256:<hex>`) is never staged (`DiagnosticKey::OtaIntegrityFailed`). Downloads stream chunk by chunk into `bistre_crypto::Sha256Stream` and a `.partial` file with a hard `256 MiB` cap (also checked against `Content-Length` and the manifest size); only a verified payload is renamed into place, and an unverified partial file is deleted.
- Version precedence follows SemVer 2.0 including prereleases (`1.0.0 > 1.0.0-rc.10 > 1.0.0-rc.2`; build metadata ignored).
