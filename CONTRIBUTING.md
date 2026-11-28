# Contributing to Bistre

Bistre is an MIT open-source project built around strict layer boundaries, zero telemetry, and mechanical verification gates. All participants are expected to uphold our [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Before Opening a PR
1. Read [`AGENTS.md`](AGENTS.md) and the relevant spec in `docs/specs/`.
2. For any architectural change, add a numbered ADR in `docs/adr/` with live-verified sources, rejected alternatives, and verification gates, and index it in `AGENTS.md`.
3. Update all affected documentation (`docs/specs/*`, `docs/design/design.md`, `docs/adr/*`, `README.md`, `SECURITY.md`, `AGENTS.md`) in the same PR as code changes, including [`docs/specs/00-architecture.md`](docs/specs/00-architecture.md#6-implementation-status) whenever a feature's status changes.
4. Run all local checks (formatting, `bistre_guard`, Rust Clippy + `cargo-deny`, i18n check + Rust parity, Flutter + Dart analysis with `bistre_lints`, and all tests):
   ```bash
   just check-all
   ```
   Batch your edits before compiling, use `just affected --run` while iterating, keep `target/` within its 4 GiB budget with `just disk` / `just prune` (keeps the debug and Android caches, deletes release outputs and other targets; never `cargo clean`), and install the pre-commit hook once with `just install-hooks`. Heavy recipes hold a single-run lock, so never start two verification runs at once.
5. Keep every non-generated code file (`.rs`, `.dart`, `.kt`, `.cpp`, `.h`, scripts, and build or CI config) ≤ 1,000 lines (`just guard`, no allowlist); split by responsibility as described in [`docs/specs/00-architecture.md`](docs/specs/00-architecture.md#5-source-module-layout--1000-lines-per-file).
6. Never discard errors: Rust `let _ =`, Dart `catch` blocks with no code, and storage/vault results dropped with `.ok()` or `if let Ok(..)` outside tests fail `just guard`; `clippy.toml` bans `Result::unwrap_or_default`, raw `Mutex::lock` (use `bistre_protocol::lock_or_recover`), `reqwest` client builders outside `crates/bistre-core/src/http_clients.rs`, `std::thread::sleep`, and unbounded channels. Every remaining exception carries `#[expect(clippy::disallowed_methods, reason = "...")]`. Propagate with `?`, or log through the named helpers (`bistre-core` `events::{emit, emit_logged, note_write}`, `FolioController._noteNonFatal`).
7. Write the regression test first and see it fail. Rust wire tests use `crates/bistre-core/src/test_support.rs` (`MockServer` scripted loopback provider that records every request, plus SSE fixtures in `crates/bistre-core/fixtures/sse/<dialect>/`) and a paused Tokio clock instead of wall-clock asserts. Flutter behaviour tests use `apps/bistre_app/test/support/shell_harness.dart` (`ShellHarness.pump` at phone/desktop, 200% text and RTL over `FakeEngineGateway`, whose `gate`/`release` hold engine calls in flight and `emit` pushes engine events) with an injected `clock`.
8. Never introduce Material/Cupertino UI libraries, third-party state frameworks, hardcoded UI strings, layout animations outside disclosures, raw `Color(...)` literals outside `bistre_theme.dart`, floating-point currency math, `openssl-sys`/`native-tls`, or FFI/SQLite layer violations.
9. Write docs, comments, and PR text by `AGENTS.md` section 4. `just guard` rejects em dashes, filler words, and emoji in every text file, and in Markdown bold, italics, horizontal rules, plain numbers in backticks, rule words in capitals, exclamation marks, and ellipses.

## Translating Bistre in One Pass (Human or AI Agent)
1. Copy `l10n/catalog/en.bistre-l10n.json` to `l10n/catalog/<bcp47>.bistre-l10n.json`.
2. Update `"locale"` and `"direction"` (`"ltr"` or `"rtl"`).
3. Translate every `entries.<key>.message` using the per-key `context`, `tone`, `max_chars`, and `placeholders` metadata.
4. Validate and regenerate typed Dart keys and bundled locale assets:
   ```bash
   just i18n-gen
   just i18n-check
   ```
5. Verify tests pass: `cd apps/bistre_app && flutter test`.

## Android Dependency Checksums
Gradle checks every downloaded Android dependency against `apps/bistre_app/android/gradle/verification-metadata.xml` (sha256), so a changed or swapped artifact fails the build. After changing an Android dependency, plugin, or the Flutter or Gradle version (Dependabot does not update Gradle; these changes are made by hand), refresh the file from `apps/bistre_app/android`:

```
flutter build apk --config-only --release --target-platform android-arm64
./gradlew --write-verification-metadata sha256 assembleRelease -Ptarget-platform=android-arm64
```

Keep it LF and review the diff. AGP's `aapt2` jar differs per OS: a refresh on Windows writes only the `-windows.jar` entry, so keep or update the `-linux.jar` entry CI needs (checked against Google Maven's published `.sha256`).

## Versions and Releases
The app version lives in `Cargo.toml` (`[workspace.package] version`, which Rust reports as `CORE_VERSION`) and `apps/bistre_app/pubspec.yaml` (`X.Y.Z+build`, the Windows resource and the Android `versionCode`); nothing else carries a copy, and `just guard` keeps the two equal. `just version` prints it. Every pull request into `main` ships a version above `main`'s: when your branch has not raised it, `.github/workflows/version-bump.yml` commits the next patch to the branch and starts CI on it. For a larger step run `just bump minor`, `just bump major`, or `just bump X.Y.Z` before pushing; a version already above `main`'s is kept. Dependabot pull requests are not bumped; they ship with the next version. To release, tag the merged version on `main` (`git tag v$(just version)`) and push the tag: `release.yml` refuses a tag that differs from the built version (Spec 10).

## CI at a Glance
Every pull request runs `.github/workflows/ci.yml`: security and hygiene (`actionlint`, `zizmor`, `gitleaks`), repo guard and docs, Rust on Linux and Windows (`fmt`, `clippy -D warnings`, `nextest`, doctests, crate-boundary `cargo tree`, `cargo deny` on Linux), Flutter on Linux and Windows (`analyze`, tests, release build; Linux also launches the release build and enforces Spec 11 launch and frame budgets), and Android (target clippy, release APK, 16 KB alignment, size budgets). Releases reuse the same workflow and sign the OTA manifest (Spec 10). Toolchain and Android SDK provisioning live once in `.github/scripts/` (`install-rust.sh`, `provision-android-sdk.sh`). On Linux, every `just ui-gallery` capture must match its baseline in `apps/bistre_app/test/goldens/linux/` byte for byte; CI uploads captures as the `ui-gallery-linux` artifact, and intended visual changes replace baseline PNGs in the same pull request after review.
