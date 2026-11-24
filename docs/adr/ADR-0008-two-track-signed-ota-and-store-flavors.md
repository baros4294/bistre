# ADR-0008: Two-Track `minisign`-Signed Silent OTA & Direct GitHub Distribution

- **Status**: Accepted (Amended 2026-11-22: Direct GitHub Distribution Only)
- **Date**: 2026-11-21
- **Deciders**: Bistre Principal Architecture

## Context & Live-Verified Evidence
- Bistre distributes exclusively via direct GitHub Releases (no Google Play or F-Droid store builds), eliminating multi-flavor store packaging overhead while retaining full cryptographic offline signature verification.
- Generic .NET/third-party desktop updater frameworks often omit built-in Ed25519 manifest signature verification and add heavy release toolchain dependencies.
- Overwriting running Windows `.exe`/`.dll` or Explorer-held `.lnk` shortcuts causes AV lock contention and vanishing icons. Linux Flatpak/Snap/distro packages break if an app attempts self-mutation.

## Decision
1. Split OTA into two cryptographically verified, zero-telemetry tracks signed with Ed25519 via zero-dependency `minisign-verify 0.3.0` (+ GitHub Sigstore build provenance attestations):
   - **Track A (Zero-Restart Data Packs)**: Non-executable AIO model catalog snapshots, hot-loadable ICU locale packs, and OpenAPI media schemas.
   - **Track B (Native Binaries)**:
     - Windows: Pure-Rust `bistre-updater` side-by-side layout under `%LocalAppData%\Bistre\versions\<semver>\` with static launcher and 3-boot crash-loop auto-rollback (`MAX_CRASH_BOOTS = 3`).
     - Linux: Atomic `.AppImage.new` → `rename()` swap; self-update strictly disabled when `FLATPAK_ID`, `SNAP`, or `/usr`/`/opt` package ownership is detected.
     - Android: Single direct GitHub `arm64-v8a` APK (`REQUEST_INSTALL_PACKAGES` in `src/main/AndroidManifest.xml`, `PackageInstaller` session API, Ed25519 manifest verification, and pinned APK signing-cert SHA-256 check; Play/F-Droid flavors removed).
2. Never interrupt active runs (`active_runs > 0` defers swap) and pair with Expand-Contract SQLite migrations (`ADR-0004`).

## Rejected Alternatives
- **Third-party .NET updater toolchains**: Missing native Ed25519 verification and add release toolchain complexity.
- **Play Store & F-Droid store flavors**: Unnecessary maintenance burden for a direct GitHub-published application.

## Consequences & Verification
- Verified via `bistre-crypto` tampered-signature tests, `bistre-updater` 3-boot rollback & Linux ownership unit tests, `bistre_guard` ensuring no `play`/`fdroid` flavor folders remain, and CI `aapt2`/pure-Dart ELF `PT_LOAD` (`just verify-16kb`)/`zipalign` checks on the direct `arm64-v8a` APK.
