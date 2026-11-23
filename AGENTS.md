# AGENTS.md — Bistre Engineering Contract

## 1. Identity
- **Product**: Bistre is a public, MIT, local-first, zero-telemetry all-in-one (AIO) AI client for Android (`arm64-v8a`, 16 KB aligned), Windows, and Linux.
- **Architecture**: ONE pure-Rust core (`crates/bistre-*`) + ONE thin Flutter UI built on `package:flutter/widgets.dart` only (`apps/bistre_app`). Protocol, storage, and harness logic live only in Rust. Never duplicate it in Dart or platform code (no split-brain).
- **UX bar**: Parchment `v2.6.0` (Kotlin/Compose). Match or exceed it screen by screen. Parchment v3+ (the abandoned Rust/GPUI port) informs only core, protocol, and CI lessons (`docs/RESEARCH-AND-EDGE-CASES.md` §4).
- **Status**: specs describe the target; `docs/SLICE-0-HANDOFF.md` records what is real and open. Read both.

## 2. Working Rules
- **Subtraction first**: choose the smallest direct change. Add no layers, toggles, or libraries nobody asked for. Before adding complexity, check whether deleting some solves it.
- **Parse at the boundary**: parse untrusted input once into types that cannot hold invalid states. Bound every loop, recursion, queue, buffer, retry, cache, and I/O.
- **Fail closed**: safety checks (spending limit, OTA signature, tool approval, path policy) deny when their own inputs fail to load. Encode the guarantee in a type that only the check can construct.
- **Never silence errors**: this covers `let _ =` and empty `catch`, and also `.ok()`, `unwrap_or_default()`, `unwrap_or(..)`, and `if let Ok(..)` on a `Result` whose error matters. Propagate it, or log a `DiagnosticKey` with a reason.
- **Never weaken verification**: never drop features, skip work, weaken tests or assertions, shrink stress sizes, or loosen budgets. Never add test retries; find the root cause. Prove that each regression test fails without its fix.
- **Two strikes**: after two related failed attempts, find the root cause before a third edit.
- **No volatile facts in code**: never hardcode model IDs, capabilities, prices, or device brands in code, comments, or `README.md` (registry presets and tests excepted); benchmarks live in `docs/`.
- **Cache versions**: every derived cache or sidecar carries a format version; a mismatch rebuilds it.

## 3. Verify Live, Never From Memory
Verify crate/package versions, Flutter/Rust/Android APIs, LLM wire protocols, MCP specs, Action SHAs, and OS/store policies against official live docs or repo files before relying on them; mark the rest `[UNVERIFIED]`.

## 4. Documentation Is Part of the Change
- **Same change**: update every affected document in the same change as the code, architecture, schema, FFI, UI token, lint, CI, or dependency change it describes. Stale documentation breaks the build (`just guard`).
- **Owners**: architecture/crates/deps → ADR + Spec 00 + `README.md` + `AGENTS.md`; domain behaviour → its Spec 01–11 (+ research doc); tokens/motion/primitives/screen anatomy → `docs/design/DESIGN.md` + Spec 08; i18n keys and `DiagnosticKey` → `l10n/catalog/*.bistre-l10n.json` + `just i18n-gen` + Spec 09; commands/CI → `justfile`, `README.md`, `CONTRIBUTING.md`, `AGENTS.md`; security/vaults/OTA signing → `SECURITY.md` + Specs 06/07/10.
- **Handoff**: before stopping, add a dated section to `docs/SLICE-0-HANDOFF.md` with what changed and why, the commands run and their results, open items with blockers, and environment caveats. Repo docs are the only memory. Never keep project decisions in harness-private memory.
- **Hygiene**: no `TODO`/`FIXME`/`HACK`/`XXX`, dead code, generator boilerplate, BOM, or CRLF (except `.bat`/`.cmd`/`.iss`/`.rc`); `.ps1` stays ASCII. Non-generated `.rs`/`.dart` files `<= 1,500` lines, split by responsibility (Spec 00 §5). `AGENTS.md` `<= 14,000` characters.
- **Lint exceptions**: Rust uses `#[expect(..., reason = "...")]` only when unavoidable and never bypasses `unsafe_code`/`unwrap_used`/`expect_used`/`panic`/`todo`/`unimplemented`. Dart never suppresses `bistre_*` rules and documents every ignore.

## 5. Build & Storage Restraint (7.7 GB Laptop)
- **Build cadence**: batch edits, iterate with `cargo check -p <crate>`, never chain or overlap heavy builds; release/bundle builds at most once, at task end.
- **Disk**: `target/ <= 5.0 GiB`, `apps/bistre_app/build/ <= 1.0 GiB` (`just disk`); `just prune` is non-destructive; never `cargo clean` blindly.
- **Run lock**: heavy recipes hold `bistre_guard locked`; use `just status` / `just affected --run` (ADR-0016).
- **User data**: never touch `%LOCALAPPDATA%\Bistre` or an installed build in development; `kDebugMode` uses `<repo>/.bistre-dev/`; tests use temp dirs.
- **Git**: Conventional Commits in reviewable layers, never a mega-commit; merge PRs with `gh pr merge --rebase`.

## 6. Layer Boundaries (Mechanically Enforced)
- **Core crates** (`bistre-protocol`, `bistre-crypto`, `bistre-storage`, `bistre-core`):
  - Zero Flutter, `flutter_rust_bridge`, `openssl`/`native-tls`, GUI, or tray deps (`deny.toml` + CI `cargo tree`).
  - `rusqlite` only in `bistre-storage`; `minisign-verify` only in `bistre-crypto`.
  - Emit typed `DiagnosticKey` (`diag.*`), never English UI strings (`just i18n-check`).
  - Money is `MoneyMicros(i64)` (`1 USD = 1_000_000`), never `f32`/`f64`.
- **`bistre-ffi`**: FRB v2 DTO mapping, runtime bootstrap, and 16 ms delta coalescing only. No domain logic, SQL, HTTP, retries, or prompt assembly.
- **`apps/bistre_app`**:
  - Forbidden: Material/Cupertino, `flutter_localizations`, `google_fonts`, third-party state/HTTP/SQL packages, hardcoded UI strings, layout-property animations, raw `Color(...)` outside `bistre_theme.dart`, and physical left/right geometry (5 `bistre_lints` rules).
  - State uses only `ChangeNotifier`/`ValueNotifier` + `InheritedNotifier` + `ListenableBuilder`, split by domain. The root `WidgetsApp` listens only to appearance and locale.

## 7. Runtime, Security & UI Invariants
- **Rust**: `[lints] workspace = true` everywhere; `#![deny(unsafe_code)]` (audited `// SAFETY:` shims only in `bistre-crypto`/`bistre-daemon`/`bistre-updater`); zero `unwrap`/`expect`/`panic!`/`todo!`/`dbg!`/`process::exit`/`mem::forget`; bounded channels; no blocking I/O on async threads; every await in a run races its cancel signal.
- **Processes**: build every child with `no_window_command(...)`, spawn only via `spawn_contained`/`run_bounded` (Windows `CREATE_NO_WINDOW` + Job Object `KILL_ON_JOB_CLOSE`; Unix process group + `PR_SET_PDEATHSIG`; whole-tree kill on timeout); raw `Command::new` banned; Windows shell prefers `pwsh -NoProfile -NonInteractive -OutputFormat Text`; no `mmap`; RAII teardown; close the old MCP client before replacing it.
- **Storage**: one SQLite WAL writer + short-lived readers; `journal_size_limit = 8 MiB`; `reclaim_storage()` = `wal_checkpoint(TRUNCATE)` + `PRAGMA optimize`; additive Expand-Contract migrations (`N-1` readable); atomic temp → `sync_all` → rename; tool output `> 64 KiB` spills to a blob; never read-modify-write through truncation-bounded reads.
- **Spending**: `store: false` default; Wallet Shield overrides Self-Healing; reserve spend in the WAL before each paid POST (settle on commit, release on failure); media is WAL-before-POST (`INDETERMINATE_HALT`), never auto-retried; prices come from the registry as `MoneyMicros`, fetched at most once per 24 h and cached, never per run; usage dedupes by `request_id`.
- **Tools & MCP**: `cap-std` `Dir` + blake3 line-hash edits (run-scoped stale-read guard, CRLF kept, truncation footer). ONE `ToolApprovalBroker`: one-use, unserializable `ToolExecutionPermit`s bound to exact arguments, issued only by an approval (or Tier-0 policy in core), revoked by synchronous `invalidate()`. MCP negotiates `2026-07-28` → `2025-11-25`; stdout noise quarantined (64 KiB stderr ring); `3 starts / 10 min` restart budget, never resending the crashed call; one session renewal on HTTP `404`; bearer tokens only over HTTPS/loopback; `mcp_schema` deferred past 6 tools.
- **Web & imports**: every model-directed fetch uses `PublicWebTransport` (public-IP pinning, `.no_proxy()`, `<= 6` validated redirects, streamed body cap); untrusted imports pass `with_imported_permissions` (strips local/shell/web/MCP grants and UNC paths); executables never open; `open_web_link` is `http(s)` only; loopback is decided by parsed host, never string prefix.
- **Providers**: one shared provider `reqwest::Client`; credential-free URLs (query auth last); strip `\r`/`\n`/zero-width/BOM/control chars from keys and headers; multi-key round-robin with instant `401`/`403`/`429` failover; ordered 400 heal ladder (`MAX_HTTP_400_HEALS = 6`, each heal a `DiagnosticKey`); one-shot `413` compaction retry; honour `retry-after-ms`/`retry-after`/`RetryInfo`; never retry spend caps, billing, or daily quota; retry mid-stream only with zero output; `Retry now` wakes backoff instantly. `SseFramer`: BOM strip, single-line JSON, plain-JSON fallback, `300 s`/`90 s` idle timeouts, `64 MiB` cap, EOF without finish → `StreamInterrupted`.
- **History**: `tools` serialized first; UI-only banners stripped before replay; replayed tool-call IDs sanitized (`[A-Za-z0-9_-]{<=64}`); opaque reasoning signatures never replayed to another provider or format; role alternation validated after compaction; 16-step quantized tool compaction; 8,000-char cross-provider reasoning handoff.
- **OTA**: HTTPS only; SemVer 2.0 prerelease ordering; streamed SHA-256 (`<= 256 MiB`) + `minisign-verify` before staging, and a missing release key disables OTA instead of skipping the check; Track B never interrupts active runs; one version source (`Cargo.toml` = `apps/bistre_app/pubspec.yaml` = `Runner.rc`; MCP `clientInfo` uses `CORE_VERSION`).
- **Flutter UI**:
  - Read `docs/design/DESIGN.md` and use `.agents/skills/fullstack-architect/SKILL.md` before any UI change.
  - Exactly 10 Ink Primitives in `apps/bistre_app/lib/design/ink_primitives.dart`.
  - Plain everyday copy in every locale; never `Inscribe`, `Folio`, `Passage`, `Author`, `Parchment`, `Candlelight`, `Guided Craft`, `Unchained`, `Wax Seal`, or `Quill` in UI strings.
  - Typed `BistreUiIcon` only; icons compile offline to `.vec`, and provenance lives only in `docs/design/ICON-SOURCES.md` + `THIRD_PARTY_NOTICES.md`.
  - Streaming deltas reach only a leaf `ValueNotifier`. Parse committed messages once and cache the result.
  - Motion: zero animation for actions done 100+ times a day and for keyboard actions. Otherwise animate `transform`/`opacity` only (140–220 ms). Honour `MediaQuery.maybeReduceMotionOf`.
  - RTL via `EdgeInsetsDirectional`. Every tap target is focusable and labelled, `>= 40 px` (`48 dp` touch).
  - Never mutate `TextEditingController.text` while composing.
  - Windows uses the Win11 DWM frame (`apps/bistre_app/windows/runner/`). Android is edge-to-edge, distributed as a direct GitHub APK only.
- **CI**: Actions pinned to 40-char SHAs, `persist-credentials: false`, least privilege, `timeout-minutes`, no `${{ }}` inside `run:`; `rust-cache` `save-if: main` + `cache-bin: false`.
- **Budgets** (Spec 11): cold start `<= 400 ms` desktop / `<= 650 ms` Android; idle RSS daemon `<= 30 MB`, GUI `<= 120 MB`; streaming p99 `<= 12 ms` (60 Hz) / `<= 7.5 ms` (120 Hz); zero idle polling; `.so` `LOAD >= 0x4000`; `libbistre_ffi.so <= 10 MB`; APK `<= 32 MB`; fonts `<= 2.0 MB`.

## 8. Commands
`just check-all` runs all gates and records the verification ledger: `fmt-check` (`cargo fmt` + `dart format`), `guard` (doc links/paths/index, anti-slop, Ink budget, EOL/BOM, file-size cap, error silencing, test retries, secrets, process/mmap bans, version parity, CI security), `lint-rust` (clippy `-D warnings` + `cargo deny`), `i18n-check` (catalogs, placeholders, banned words, glossary, `DiagnosticKey` parity, generated `apps/bistre_app/lib/l10n/l10n_keys.g.dart`), `lint-dart` (`flutter analyze` + `dart analyze tools/*`), `test-rust` (`cargo nextest`), `test-dart` (tool tests + `flutter test`). Also: `just ui-gallery` (PNGs incl. 200% text in `apps/bistre_app/build/ui_gallery/`; review after every UI change), `just perf`, `just status`, `just affected --run`, `just disk`, `just prune`, `just install-hooks`, `just codegen-frb` (after FFI API changes), `just verify-16kb <apk|so>`.

## 9. Adding a Locale
Copy `l10n/catalog/en.bistre-l10n.json` to `l10n/catalog/<bcp47>.bistre-l10n.json`, set `"locale"` and `"direction"` (`ltr`/`rtl`), translate every `entries.<key>.message` honouring `context`, `tone`, `max_chars`, and exact ICU syntax, then run `just i18n-gen` and `just i18n-check`.

## 10. Index
- **Skill** `.agents/skills/fullstack-architect/SKILL.md` · **Research** `docs/RESEARCH-AND-EDGE-CASES.md` · **Handoff** `docs/SLICE-0-HANDOFF.md` · **Design** `docs/design/DESIGN.md`, `docs/design/ICON-SOURCES.md`
- **Specs (`docs/specs/`)**: `00-architecture`, `01-canonical-history-and-storage`, `02-providers-wire-and-self-healing`, `03-aio-registry-and-slots`, `04-agent-harness-tools-and-mcp`, `05-modes-roleplay-and-media`, `06-trust-and-wallet-shield`, `07-remote-bridge-and-security`, `08-sepia-book-ui`, `09-i18n-and-ai-translation`, `10-silent-ota-and-distribution`, `11-performance-and-budgets`.
- **ADRs (`docs/adr/`)**: `ADR-0001` Pure Widgets · `ADR-0002` FRB v2 Native Assets · `ADR-0003` EngineClient & Daemon · `ADR-0004` SQLite WAL & Expand-Contract · `ADR-0005` Stateless LLM & Compaction · `ADR-0006` MCP Dual Negotiation · `ADR-0007` Runtime ICU i18n · `ADR-0008` Two-Track Signed OTA · `ADR-0009` Wallet Shield & Media Idempotency · `ADR-0010` Secret Vaults & Sandboxed Tools · `ADR-0011` Sepia Tokens & 10 Ink Primitives · `ADR-0012` Android FGS & BLE Audio · `ADR-0013` Sleep Immunity & Daemon · `ADR-0014` Rich Studio Canvas · `ADR-0015` Story Bible & Writing Studio · `ADR-0016` Build & Storage QC, Run Lock & Ledger · `ADR-0017` Single Dispatch, Public Egress & Import Policy · `ADR-0018` MCP Without SDK.
