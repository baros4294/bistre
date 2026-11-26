# Contributing to Bistre

Bistre is an MIT open-source project built around strict layer boundaries, zero telemetry, and mechanical verification gates. All participants are expected to uphold our [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Before Opening a PR
1. Read [`AGENTS.md`](AGENTS.md) and the relevant spec in `docs/specs/`.
2. For any architectural change, add a numbered ADR in `docs/adr/` with live-verified sources, rejected alternatives, and verification gates, and index it in `AGENTS.md`.
3. Update all affected documentation (`docs/specs/*`, `docs/design/DESIGN.md`, `docs/adr/*`, `README.md`, `SECURITY.md`, `AGENTS.md`) in the **same PR** as code changes, including [`docs/specs/00-architecture.md`](docs/specs/00-architecture.md#6-implementation-status) whenever a feature's status changes.
4. Run all local checks (formatting, `bistre_guard`, Rust Clippy + `cargo-deny`, i18n check + Rust parity, Flutter + Dart analysis with `bistre_lints`, and all tests):
   ```bash
   just check-all
   ```
   Batch your edits before compiling, use `just affected --run` while iterating, keep `target/` within budget with `just disk` / `just prune` (never `cargo clean`), and install the pre-commit hook once with `just install-hooks`. Heavy recipes hold a single-run lock, so never start two verification runs at once.
5. Keep non-generated `.rs` / `.dart` files `<= 1,500` lines (`just guard`, no allowlist); split by responsibility as described in [`docs/specs/00-architecture.md`](docs/specs/00-architecture.md#5-source-module-layout--1500-lines-per-file).
6. Never discard errors: Rust `let _ =`, Dart `catch` blocks with no code, and storage/vault results dropped with `.ok()` or `if let Ok(..)` outside tests fail `just guard`; `clippy.toml` bans `Result::unwrap_or_default`, raw `Mutex::lock` (use `bistre_protocol::lock_or_recover`), `reqwest` client builders outside `crates/bistre-core/src/http_clients.rs`, `std::thread::sleep`, and unbounded channels. Every remaining exception carries `#[expect(clippy::disallowed_methods, reason = "...")]`. Propagate with `?`, or log through the named helpers (`bistre-core` `events::{emit, emit_logged, note_write}`, `FolioController._noteNonFatal`).
7. Write the regression test first and see it fail. Rust wire tests use `crates/bistre-core/src/test_support.rs` (`MockServer` scripted loopback provider that records every request, plus SSE fixtures in `crates/bistre-core/fixtures/sse/<dialect>/`) and a paused Tokio clock instead of wall-clock asserts. Flutter behaviour tests use `apps/bistre_app/test/support/shell_harness.dart` (`ShellHarness.pump` at phone/desktop, 200% text and RTL over `FakeEngineGateway`, whose `gate`/`release` hold engine calls in flight and `emit` pushes engine events) with an injected `clock`.
8. Never introduce Material/Cupertino UI libraries, third-party state frameworks, hardcoded UI strings, layout animations outside disclosures, raw `Color(...)` literals outside `bistre_theme.dart`, floating-point currency math, `openssl-sys`/`native-tls`, or FFI/SQLite layer violations.

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

## CI at a Glance
Every pull request runs `.github/workflows/ci.yml`: security and hygiene (`actionlint`, `zizmor`, `gitleaks`), repo guard and docs, Rust on Linux and Windows (`fmt`, `clippy -D warnings`, `nextest`, doctests, crate-boundary `cargo tree`, `cargo deny` on Linux), Flutter on Linux and Windows (`analyze`, tests, release build; Linux also launches the release build and enforces Spec 11 launch and frame budgets), and Android (target clippy, release APK, 16 KB alignment, size budgets). Releases reuse the same workflow and sign the OTA manifest (Spec 10). Toolchain and Android SDK provisioning live once in `.github/scripts/` (`install-rust.sh`, `provision-android-sdk.sh`). On Linux, every `just ui-gallery` capture must match its baseline in `apps/bistre_app/test/goldens/linux/` byte for byte; CI uploads captures as the `ui-gallery-linux` artifact, and intended visual changes replace baseline PNGs in the same pull request after review.
