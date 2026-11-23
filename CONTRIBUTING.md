# Contributing to Bistre

Bistre is an MIT open-source project built around strict layer boundaries, zero telemetry, and mechanical verification gates.

## Before Opening a PR
1. Read [`AGENTS.md`](AGENTS.md) and the relevant spec in `docs/specs/`.
2. For any architectural change, add a numbered ADR in `docs/adr/` with live-verified sources, rejected alternatives, and verification gates, and index it in `AGENTS.md`.
3. Update all affected documentation (`docs/specs/*`, `docs/design/DESIGN.md`, `docs/adr/*`, `README.md`, `SECURITY.md`, `AGENTS.md`) in the **same PR** as code changes. When a task is finished, add a dated section to [`docs/SLICE-0-HANDOFF.md`](docs/SLICE-0-HANDOFF.md) (changes, verification results, open items, environment caveats) so the next contributor or AI agent can continue without the original conversation.
4. Run all local checks (formatting, `bistre_guard`, Rust Clippy + `cargo-deny`, i18n check + Rust parity, Flutter + Dart analysis with `bistre_lints`, and all tests):
   ```bash
   just check-all
   ```
   Batch your edits before compiling, use `just affected --run` while iterating, keep `target/` within budget with `just disk` / `just prune` (never `cargo clean`), and install the pre-commit hook once with `just install-hooks`. Heavy recipes hold a single-run lock, so never start two verification runs at once.
5. Keep non-generated `.rs` / `.dart` files `<= 1,500` lines (`just guard`, no allowlist); split by responsibility as described in [`docs/specs/00-architecture.md`](docs/specs/00-architecture.md#5-source-module-layout--1500-lines-per-file).
6. Never discard errors: Rust `let _ =` and Dart `catch` blocks with no code fail `just guard`. Propagate with `?`, or log through the named helpers (`bistre-core` `events::{emit, emit_logged, note_write}`, `FolioController._noteNonFatal`).
7. Never introduce Material/Cupertino UI libraries, third-party state frameworks, hardcoded UI strings, layout animations, raw `Color(...)` literals outside `bistre_theme.dart`, floating-point currency math, `openssl-sys`/`native-tls`, or FFI/SQLite layer violations.

## Translating Bistre in One Pass (Human or AI Agent)
1. Copy `l10n/catalog/en.bistre-l10n.json` to `l10n/catalog/<bcp47>.bistre-l10n.json`.
2. Update `"locale"` and `"direction"` (`"ltr"` or `"rtl"`).
3. Translate every `entries.<key>.message` using the per-key `context`, `tone`, `max_chars`, and `placeholders` metadata.
4. Validate and regenerate typed Dart keys and bundled locale assets:
   ```bash
   dart run tools/bistre_i18n/bin/bistre_i18n.dart check
   dart run tools/bistre_i18n/bin/bistre_i18n.dart gen
   ```
5. Verify tests pass: `cd apps/bistre_app && flutter test`.
