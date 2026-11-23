# Bistre

Cross-platform, local-first, zero-telemetry, MIT-licensed all-in-one (AIO) AI client with a custom Sepia Book UI (`package:flutter/widgets.dart` only) and an IDE-grade pure-Rust native agentic harness.

## Architecture Highlights
- **Pure Rust Core (`crates/bistre-core`, `bistre-storage`, `bistre-crypto`, `bistre-protocol`)**: Canonical SQLite WAL Schema v8 + FTS5 conversation DAG, sleep-immune durable agent runs (`PowerCoordinator`, Win32 `PowerCreateRequest` / Linux `systemd-inhibit` / Android `BistreAgentService` `specialUse` FGS + optional Termux bridge), mid-stream steering queue, active-scoped `bistre-daemon`, in-process capability-scoped tools (`cap-std` + `blake3` + `imara-diff` + 1-click Rewind), Streamable HTTP MCP with dual negotiation (`2026-07-28` → `2025-11-25`, no SDK; `ADR-0018`), git worktree subagents, progressive `SKILL.md` & lifecycle hooks, scheduled cron/timer automations, cross-chat SQLite memory, and a full **Writing & Roleplay Studio** (CCv3/V2 PNG/JSON/`.charx` cards, Lorebook V3 + Chronological Progressions, Prompt-Cache Boundary Assembler, and linear-time safe regex pipeline).
- **Thin FRB v2 Native Assets Bridge (`crates/bistre-ffi`)**: DTO mapping and 16ms coalescing stream batching via `flutter_rust_bridge 2.13` + Dart build hooks (`hook/build.dart`).
- **Zero-UI-Lib Sepia Book UI (`apps/bistre_app`)**: Pure `package:flutter/widgets.dart` (mechanically linted by `tools/bistre_lints` inside `flutter analyze`), native Windows 11 DWM Sepia frame, Day Parchment & Night Candlelight WCAG AA/AAA themes with custom accent & local `.ttf`/`.otf` font support, exact 10 Ink Primitives, **56 bespoke `.vec` UI icons** + **42 offline full-color AI lab `.vec` marks**, pure-Dart GFM Tables, `NotoSansMath` LaTeX renderer, Mermaid `CustomPainter`, collapsible Thinking & Tool diff timelines, visual DAG Session Tree, 4-tab Studio Pane (`[Runs] [Files] [Story] [Prompt]`), Manuscript Beats→Prose canvas + Inline Rewrite Laser Tools, full-window 9-tab Settings, and runtime hot-loadable ICU localization (`en`, `vi`, `ar` RTL).
- **Targets**: Android (`arm64-v8a`, 16KB ELF aligned, direct GitHub APK), Windows x64, and Linux x64/arm64.

## Prerequisites
- Rust `1.100.0` (auto-pinned by `rust-toolchain.toml`, targets `x86_64-pc-windows-msvc`, `x86_64-unknown-linux-gnu`, `aarch64-linux-android`)
- Flutter `3.50.1` / Dart `3.14.0`
- Android SDK API 36 + NDK r30 (`30.0.16248370`) + Java 25 (for Android builds)
- Optional CLI runners: `cargo install --locked cargo-nextest cargo-deny flutter_rust_bridge_codegen@2.13.0 just`

## Quick Verification
```bash
just check-all        # full gate; records the verification ledger on success
just status           # storage warnings + files changed since the last green run
just affected --run   # run only the recipes your changes touch
just disk             # build-cache usage vs Spec 11 budgets (target/ <= 5.0 GiB)
just prune            # non-destructive cache pruning (never cargo clean)
just install-hooks    # pre-commit: MSVC link.exe PATH fix + fmt-check + guard
just verify-16kb <apk-or-so>
just perf             # streaming frame probe + 300-chat cold start / idle RSS (`--android` for adb)
```
Or run individual gates directly:
```bash
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo deny --locked check
cargo nextest run --locked --workspace
dart run tools/bistre_guard/bin/bistre_guard.dart
dart run tools/bistre_i18n/bin/bistre_i18n.dart check
flutter analyze apps/bistre_app
dart analyze tools/bistre_lints tools/bistre_i18n tools/bistre_guard
dart test tools/bistre_lints tools/bistre_i18n tools/bistre_guard
cd apps/bistre_app && flutter test
```

## Documentation
- Agent contract: [`AGENTS.md`](AGENTS.md)
- Research report & edge-case matrix: [`docs/RESEARCH-AND-EDGE-CASES.md`](docs/RESEARCH-AND-EDGE-CASES.md)
- Slice 0 handoff & verification receipt: [`docs/SLICE-0-HANDOFF.md`](docs/SLICE-0-HANDOFF.md)
- Design system: [`docs/design/DESIGN.md`](docs/design/DESIGN.md)
- Modular specs: [`docs/specs/`](docs/specs/)
- Architecture Decision Records: [`docs/adr/`](docs/adr/)

## License
MIT — see [`LICENSE`](LICENSE).
