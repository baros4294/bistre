# Slice 0 Handoff & Verification Receipt

Recorded **2026-11-21** after completing Commit-1 Repo Fortress, Spec Pack, Day-1 ADRs, 7-crate Rust workspace, Dart lint/i18n tooling, and Slice 0 Walking Skeleton. Use this receipt when resuming in any new AI coding harness.

## 1. Completed Scope (Verified on Disk)
- **Repo Fortress**: `git init -b main` (uncommitted working tree), `LICENSE` (MIT), `.gitignore`, `.gitattributes`, `.gitleaks.toml`, `rust-toolchain.toml` (`1.100.0`), `.cargo/config.toml` (`-Wl,-z,max-page-size=16384`), `Cargo.toml`, `clippy.toml`, `deny.toml`, `pubspec.yaml` (Dart 3.14 Pub Workspace), `analysis_options.yaml`, cross-platform `justfile`, Node 24 SHA-pinned `.github/workflows/ci.yml` + `release.yml`, `.github/dependabot.yml` with supply-chain cooldowns.
- **Docs & Skills**: `AGENTS.md` (with mandatory Doc-Sync & Anti-Slop contract), `.agents/skills/fullstack-architect/SKILL.md` (workspace progressive anti-slop skill), `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `apps/bistre_app/README.md`, `docs/RESEARCH-AND-EDGE-CASES.md`, `docs/design/DESIGN.md`, `docs/specs/00..11`, `docs/adr/ADR-0001..0012`.
- **Rust Workspace (`crates/`)**: `bistre-protocol`, `bistre-crypto` (including real Windows DPAPI `LocalSecretVault` with zeroization), `bistre-storage` (Schema v4: `providers` table + single neutral `Default` assistant on fresh install + full assistant CRUD + `v1->v2->v3->v4` additive Expand migrations), `bistre-core` (real pure-Rust `reqwest 0.13` + `rustls 0.23` `ring` + `rustls-platform-verifier 0.7.1` Big 3 + Custom OpenAI-compatible live `/models` discovery & streaming SSE adapters; zero mock AI replies), `bistre-ffi` (real FRB `2.13.0` bindings), `bistre-daemon`, `bistre-updater` — all inheriting `[lints] workspace = true` with zero `unwrap`/`expect`/`panic`/`allow_attributes` bypasses.
- **Dart Tooling & Assets**: `tools/bistre_lints` (5 rules on `analysis_server_plugin 0.3.26`), `tools/bistre_i18n` (catalogs + Rust `DiagnosticKey` parity + generated asset freshness), `tools/bistre_guard` (doc links, Spec/ADR index sync, anti-slop markers, 10 Ink Primitives budget, LF endings, manifest hygiene, version sync, CI security), `l10n/catalog/{en,vi,ar}.bistre-l10n.json` (200 plain everyday UI copy keys), static OFL fonts (`Inter`, `JetBrainsMono`, `NotoSansMath` = `3.1 MB`), `bistre_icon.vec`, Windows `app_icon.ico`, Android `mipmap-*/ic_launcher.png`, Linux PNG/SVG icons.
- **Flutter Shell (`apps/bistre_app`)**: Pure `package:flutter/widgets.dart`, `hook/build.dart` (FRB Native Assets with automatic Android NDK discovery), runtime ICU evaluator + hot-loadable `BistreLocalizations` (200 trilingual `en`/`vi`/`ar` plain-language keys), Sepia Book themes (including `onAccentWax`, `hoverTint`, `scrim`, `cardShadow`, `floatingShadow`, & fine-grained `MediaQuery.maybeReduceMotionOf`), exact 10 Ink Primitives + engraved vector glyphs & bespoke Big-3 provider marks (`bistre_glyphs.dart`) + GPU-composited motion widgets (`bistre_motion_widgets.dart`), clean border-free **`Assistant | Chat | Pinned`** 3-tab archival sidebar, minimal header with 1-click `FolioOverlay` Provider/Model Quick-Switcher Popover, global keyboard shortcuts & Raycast-style `Ctrl+K` Command Menu with engraved keycaps, 7-tab Settings workspace starting on 2-pane Master-Detail `Providers & Keys` (Big 3 + Custom + live `/models` discovery + Server response cache toggle), 2-pane `Assistants` CRUD editor, live micro-USD Daily Spend progress meter in `Safety & Budget`, tactile `_SegmentedTrack` controls, LTR-isolated Sepia syntax-tinted code cards, floating composer with interactive Assistant picker & border-free `Connect an AI provider` onboarding, 13-screen `UIGalleryTest` (`just ui-gallery`), Android API 36 / NDK r30 / 16KB direct GitHub APK (zero Play/F-Droid flavors).

## 2. Measured Slice 0 Verification Results
| Check | Result |
|---|---|
| `cargo fmt --all -- --check` & `cargo clippy --locked --workspace --all-targets -- -D warnings` | Passed (0 warnings) |
| `cargo nextest run --locked --workspace` | 17/17 passed in `0.45s` (including Schema v1→v2→v3→v4 migration, single `Default` assistant + edit/delete CRUD, Windows DPAPI vault encryption persistence, live loopback HTTP/SSE streaming for Big 3 + Custom dialects, pinning, settings & DAG branching) |
| `cargo deny --locked check` & `cargo tree -p bistre-core` | `advisories ok, bans ok, licenses ok, sources ok`; zero FFI/OpenSSL/`aws-lc-sys` leakage |
| `target/release/bistre-daemon.exe` | `2.6 MB`, `--health-check` WAL active, idle RSS **`5.82 MB`** (budget `<= 30 MB`) |
| `target/release/bistre-updater.exe` | `206 KB`, `--verify-manifest` returned `VERIFIED` |
| `just guard` (`tools/bistre_guard`) | Passed (doc links, Spec/ADR index sync, anti-slop, 10 Ink Primitives, LF endings, direct-GitHub Android manifest hygiene, version sync, CI security) |
| `dart run tools/bistre_i18n/bin/bistre_i18n.dart check` & `dart test` | Passed (200 trilingual plain-language keys, Rust `DiagnosticKey` parity & generated asset freshness); 9/9 tooling tests passed |
| `flutter analyze apps/bistre_app` | `No issues found!` with all 5 `bistre_lints` rules active |
| `cd apps/bistre_app && flutter test` | 8/8 passed including contrast (`onAccentWax`), `reduceMotion` + user override, RTL cutout padding, `Add API Key` onboarding + 2-pane Big 3 provider connection + `Assistant | Chat | Pinned` sidebar tabs + streaming + DAG branching + Settings + `Ctrl+K` Command Menu + live RTL switching, **live Dart→Rust FRB v2 Native Assets (`bistre_ffi.dll`) Schema v4 / single Default assistant + CRUD / Big 3 + Custom / DPAPI Vault / live HTTP/SSE / FTS5 / minisign round-trip**, and **13-screen `UIGalleryTest`** (`apps/bistre_app/build/ui_gallery/*.png`) |
| Android `arm64-v8a` Direct GitHub Release APK | `19.5 MB`; `libbistre_ffi.so` = **`2.7 MB`** (`<= 4 MB`); `llvm-readelf -lW` confirmed `0x4000` (`libbistre_ffi.so`, `libdartjni.so`) & `0x10000` (`libapp.so`, `libflutter.so`); `zipalign -c -P 16 4` passed; direct-GitHub APK declares `REQUEST_INSTALL_PACKAGES` (Play/F-Droid flavors removed) |

## 3. Environment Notes for Next Session
- Local workstation has `rustc 1.100.0`, `Flutter 3.50.1` (`Dart 3.14.0`), `ANDROID_HOME` (SDK 36/37), `ANDROID_NDK_HOME` r30, Java 25, plus installed CLI tools: `flutter_rust_bridge_codegen 2.13.0`, `cargo-deny 0.22.0`, `cargo-nextest 0.9.152`, `just 1.59.0`, `cargo-expand`.
- Local workstation uses portable `msvc-kit` without Visual Studio IDE (`flutter build windows --release` requires Visual Studio C++ workload locally or runs in GitHub Actions `windows-2025`); `apps/bistre_app/hook/build.dart` already handles portable `msvc-kit` `LIB`/`INCLUDE` reconstruction for Native Assets.
- Working tree is ready for Commit 1 (`git add` / commit) and **Slice 1** implementation per `docs/specs/02-providers-wire-and-self-healing.md` (provider dialects, `reqwest 0.13` + `rustls-platform-verifier`), `docs/specs/03-aio-registry-and-slots.md` (AIO registry synthesizer), and `docs/specs/06-trust-and-wallet-shield.md` (OS `SecretVault` backends + Wallet Shield).

## 4. v2 Guardrails Pass (2026-11-23)
- **Scope**: storage/QC run lock + verification ledger (`ADR-0016`), static anti-pattern gates in `just guard`, Rust protocol/SSRF/process/OTA hardening (`ADR-0017`), Sepia craft inheritance (Spec 08 §3), `just perf` harness (Spec 11 §5), OFL font subsetting (`1.58 MB`), and the `<= 1,500`-line split with the grandfather allowlist removed (Spec 00 §5).
- **`just check-all`**: passed — guard, `cargo clippy -D warnings` + `cargo deny` (`advisories ok, bans ok, licenses ok, sources ok`), i18n parity, `flutter analyze` / `dart analyze` (no issues), `cargo nextest` 79/79, tool tests, `flutter test` 19/19.
- **Open items at the end of the guardrails pass**: streaming probe p95 `~115 ms`; Win32 Job Objects / `PR_SET_PDEATHSIG`; wide-desktop Split diff toggle; unavailable-cost popup; `actionlint` / `zizmor` not run locally. Their resolution is recorded in §5.

## 5. Open-Item Closure Pass (2026-11-23)
- **Child containment**: per-child `KillOnCloseJob` (Windows) and `PR_SET_PDEATHSIG` (Linux/Android) in `bistre_crypto::containment`; `run_bounded` now kills the tree while the root is alive (the old order leaked grandchildren). Regression tests fail without each fix.
- **Error silencing**: all 140 Rust `let _ =` sites and 10 empty Dart catches replaced (errors propagate or are logged with their key); `just guard` now rejects both. Real bugs fixed on the way: lost settings saves, vault key deletes, lore imports, wallet spend records, and unpersisted replies were previously silent; the Unix IPC socket now fails closed if `0600` cannot be set; migration backups are mandatory.
- **Streaming**: chunked code fences + open-fence parse memo: probe p95 `114 ms -> ~10.5 ms` run alone (debug test VM). The 120 Hz `7.5 ms` budget still needs a profile build on a device (no Visual Studio workload or Android device on this machine).
- **UI**: wide-layout Split diff toggle, quiet unavailable-cost popup (new `info` glyph), and l10n keys for previously hardcoded Termux/MCP/Mermaid labels and Writing Studio requests (en/vi/ar).
- **CI**: `zizmor --persona auditor` and `actionlint` pass locally; jobs named, permissions commented, toolchain action replaced by `rustup`.
- **`just check-all`**: passed (guard, clippy `-D warnings` + `cargo deny`, i18n, analyzers, `cargo nextest` 82/82, Dart + Flutter tests).
- **Still open at the end of §5**: Android / Linux vault encryption and the device streaming measurement; §6 resolves the vault.

## 6. Vault Encryption & Streaming Follow-up (2026-11-23)
- **What changed**: Linux and Android API keys are now encrypted at rest. `bistre-crypto` seals every vault entry with XChaCha20-Poly1305 under a 32-byte `VaultKey` (entry name as associated data, sealed key-check entry, atomic `0600` + `sync_all` writes) and encrypts plaintext entries from older builds on first open (`crates/bistre-crypto/src/sealed.rs`, `LocalSecretVault`). The key comes from the Android Keystore (`VaultKeyStore.kt` wraps a random data key with a non-exportable AES-256-GCM key, StrongBox when present; Dart passes it to `init_runtime(data_dir, vault_key)` through `dev.bistre.app/vault_key`), from the Linux Secret Service (`bistre_core::vault_key`, `oo7 0.7.1`), or from Argon2id over `BISTRE_VAULT_PASSPHRASE`. Windows keeps DPAPI. With no key source the vault refuses new writes rather than storing plaintext. A changed key sets the old vault aside (`*.key-mismatch-<ms>`) instead of failing startup. New dependencies: `chacha20poly1305 0.11.0`, `argon2 0.6.0`, `getrandom 0.4.3`, `oo7 0.7.1` (Linux only, no OpenSSL).
- **Streaming**: the feed's `LayoutBuilder` is now a relayout boundary (`StackFit.expand`; regression-tested). Debug-VM p95 stays about `10.5–11.3 ms` run alone; see Spec 11 §5 for the profile.
- **Process rule**: `AGENTS.md` §4 and `CONTRIBUTING.md` now require a dated handoff section like this one after every finished task.
- **Verification**: `just check-all` passed (guard, clippy `-D warnings`, `cargo deny`, i18n, analyzers, `cargo nextest` 88/88, Dart + Flutter tests). `bistre-crypto` clippy is clean for `x86_64-unknown-linux-gnu` and `aarch64-linux-android`; the Linux resolver type-checks with pedantic clippy against `oo7` for Linux in a scratch crate (this Windows machine cannot cross-compile `ring`); the Kotlin host compiles (`gradlew :app:compileDebugKotlin`). Vault tests fail when sealing leaks plaintext.
- **Not verified on hardware (environment limits)**: no Android device (Keystore / StrongBox path untested at runtime), no Linux desktop with a Secret Service, and no Visual Studio C++ workload, so the `7.5 ms` 120 Hz streaming budget can only be confirmed by a profile build on a device. Next agent: run the app on an Android device and a Linux desktop (with and without `gnome-keyring`), check that `bistre_vault.local.json` contains only `x1:` entries, and run `flutter drive --profile` frame timings.


## 7. Hardening Audit & Plan (2026-11-23, docs only)
- **What changed**: no code. Recorded the UX benchmark (Parchment `v2.6.0`; v3+ only for core/protocol/CI lessons) in `AGENTS.md` §1 and `docs/design/DESIGN.md` §1.1, the open UX parity table in Spec 08 §4, and the Parchment commit audit in `docs/RESEARCH-AND-EDGE-CASES.md` §4.
- **Why**: a full audit (Rust crates, Flutter app, CI, all 220 Parchment commits) found concrete defects that the earlier sections of this receipt do not mention. The plan below fixes them. It is awaiting approval; nothing in it is implemented yet.
- **Confirmed defects (fix first)**:
  - OTA can stage unsigned payloads: `OFFICIAL_RELEASE_PUBKEY_B64 = ""` skips the minisign check (`crates/bistre-core/src/ota.rs:28`, `:94-121`); `stage_update_artifact` ignores `signature_verified`; the whole `UpdateCheckResult` round-trips through Dart (`crates/bistre-ffi/src/api/mod.rs:833`); no release job signs.
  - Wallet Shield bypass: prefix-matched loopback (`providers.rs:56`, so `http://localhost.evil.com` is "free"); the in-run re-check fails open (`engine_runs.rs:423-429`); concurrent runs only see committed spend.
  - Tool approval is tautological: `issue` then `claim` on the next line (`engine_impl.rs:755-756`).
  - Mid-stream retry of paid output: idle/IO errors after deltas return `ProviderStreamInterrupted`, which `is_auto_retryable` retries (`providers.rs:409-415`, `engine_runs.rs:25`); `error_policy::may_retry_stream` is test-only.
  - Silent errors in the run path: `list_nodes(..).unwrap_or_default()` sends an empty history to a paid provider (`engine_runs.rs:71`, `:323`); core has 83 `.ok()`, 39 `unwrap_or_default()`, 11 poisoned-lock ignores, none caught by `just guard`.
  - Cancel only checked between chunks (up to the 300 s first-token timeout); `init_runtime` swaps `ENGINE` without shutting the old one down; the daemon polls every 2 s.
  - Flutter: the root `WidgetsApp` listens to the whole `FolioController` (`apps/bistre_app/lib/main.dart:227`), so toasts, search keystrokes, and draft saves rebuild everything; committed messages re-parse markdown every build; `FolioFadeSlide` replays on scroll-back; thread switch and search have no generation guard; `recordToolActivity` has no caller.
  - Docs overstate the code: MCP is HTTP-only, updater rollback and cron are stubs, native model tool calls are missing.
- **Plan milestones**:
  - M0: commit as layered Conventional Commits, create the GitHub repo, and get `ci-gate` green.
  - M1: fail-closed types: `VerifiedManifest`, `LoopbackUrl`, WAL spend reservations, a real approval round trip, no retry after partial output, error propagation plus clippy `disallowed-methods` for `Result::{ok, unwrap_or_default, unwrap_or}`, and `select!` cancel.
  - M2: engine lifecycle, a reader pool, cadence-based persistence, core-side delta coalescing with `EventsLagged`, typed FFI errors and DTOs, one HTTP-client module, a deadline-driven daemon, an implementation-status table in Spec 00, and the Parchment v3 carry-over (reasoning handoff, batch-of-8 compaction, signature replay tests).
  - M3: split `FolioController` into domain notifiers, add generation tokens, staged bootstrap, paged history, a markdown block cache, and a virtualized sidebar.
  - M4: v2.6.0 parity audit, then close Spec 08 §4.
  - M5: extend `bistre_lints` (2 new rules), add an i18n banned-word and glossary check, and add guard checks.
  - M6: `TestResult` + `?` tests, regression tests for every defect, `proptest`, and Linux goldens.
  - CI: a `workflow_call` reuse of `ci.yml` by `release.yml`, a shared setup composite action, a release launch smoke test, a `perf-linux` profile job, Android-target clippy, doctests, a minisign `sign-and-publish` job, and Dependabot merging with `--rebase`.
- **Blocking questions (answered by the owner 2026-11-23; execution not yet started)**:
  - Q1: yes. Create the public MIT `baros4294/bistre` repo and push the M0 baseline commits.
  - Q2: (a). Registry and pricing fetch at most once per 24 h, cached with a format version, behind a Settings toggle (default on). Runs never fetch.
  - Q3: drop `rmcp` now and use a hand-rolled Streamable HTTP MCP client; re-adopt it with the stdio-MCP slice. ADR-0006 and AGENTS §7 must be updated in the same change.
  - Q4: yes. OTA stays fail-closed (`OtaSigningKeyMissing`) until the owner provisions the minisign keypair and the `release` environment secret.
- **Verification**: `just guard` passed after these doc edits (doc links, anti-slop, EOL/BOM, index sync); `AGENTS.md` is 13,746 / 14,000 characters. No Rust or Flutter code changed, so no other recipe was run.
- **Environment caveats**: zero commits and no git remote, so CI has never run; the `7.5 ms` 120 Hz budget still needs a profile build on a device or the planned Linux CI job.

## 8. Contract & Design Docs Tightening (2026-11-23, docs only)
- **What changed**:
  - `AGENTS.md` was restructured into short, scannable rules, down to 13,816 / 14,000 characters. No rule was dropped. New rules:
    - Fail closed.
    - `.ok()`, `unwrap_or_default()`, and `if let Ok(..)` count as silencing.
    - No test retries.
    - Cache format versions.
    - Spend reserved before each paid POST.
    - Prices fetched at most once per 24 h (Q2).
    - Opaque reasoning signatures are never replayed across providers.
    - Loopback decided by parsed host.
    - Missing OTA key disables OTA.
    - Root `WidgetsApp` listens only to appearance and locale.
    - Focusable, labelled `>= 40 px` targets.
    - Repo docs are the only memory.
  - The MCP line no longer names `rmcp`, because Q3 drops it.
  - `.agents/skills/fullstack-architect/SKILL.md` is rewritten for Bistre: ground, backend, a 6-step design process with `just ui-gallery` critique against Parchment `v2.6.0`, visual/copy/motion/accessibility/frame-budget rules, the delivery loop, and the audit format.
  - `docs/design/DESIGN.md`:
    - Message arrival, sending, thread switching, and scroll-back never animate (removes the `FolioFadeSlide` passage entrance from the "occasional" list).
    - Reduced motion also stops running animations; controls must be focusable; modals trap focus; toasts are live regions.
    - The feed is described correctly as a `CustomScrollView`; the icon count is corrected to 57.
    - New §10 Screen Anatomy (header, message, code card, composer, empty chat, sidebar).
  - `docs/specs/08-sepia-book-ui.md` §2: the run-on workspace bullet is replaced with a per-area list. Wrong file paths (session tree, runs dock, inspector) and unverifiable counts (gallery shot and tab totals, header pixel height) are removed.
- **Why**: the owner asked for concise, precise docs before implementation, with UI work driven by the skill and the v2.6.0 bar.
- **Verification**: `just guard` passed.
- **Open items**:
  - The new `AGENTS.md` rules describe the target. The code still violates fail-closed spending, approval, OTA, error silencing, and the root rebuild (§7 defects), and no guard enforces test retries or cache versions yet.
  - ADR-0006 still adopts `rmcp` and rejects a hand-rolled client. It needs a superseding ADR in the change that drops `rmcp` (Q3). `README.md` still says `rmcp 3.11`.
  - Specs 00–07 and 09–11 have not had this precision pass; that happens in the docs-honesty step of the plan.
  - Chat mode switch placement is left to the Spec 08 §4 parity audit.

## 9. M0 + M1: Baseline and Safety Fixes (2026-11-23)
- **M0**: the tree is committed as ten layered Conventional Commits and pushed to the new public repo `baros4294/bistre` (commits use the GitHub noreply address; the repo-local `user.email` was set so pushes pass email privacy). First CI runs exposed two CI defects, both fixed: the pinned `install-action` cannot install `actionlint` (now `.github/scripts/install-actionlint.sh`, version and SHA-256 pinned), and gitleaks flagged two fake vault fixtures (renamed to `sk-test-*`; the original strings are allowlisted exactly for the history scan). Linux `flutter test` also exposed a notify-after-dispose crash and an FFI test that could not find the hook-built `.so`; both are fixed.
- **M1 (all §7 safety defects)**:
  - OTA fails closed with no release key (`diag.ota.signing_key_missing`); the `.minisig` is mandatory; `stage_update` uses only the core-held `VerifiedManifest`.
  - Loopback is decided by parsed host (`crates/bistre-core/src/net.rs`) for Wallet Shield, pricing, and MCP.
  - Wallet Shield reserves spend in one writer transaction before every paid request (`crates/bistre-core/src/wallet.rs`); storage errors deny with `diag.wallet.check_unavailable`; startup sweeps orphaned reservations.
  - Tools other than Tier 0 need `approve_tool_call` → one-use permit (60 s, 64 max, exact arguments); Tier 3 uses `diag.tool.tier_blocked`. New FFI `approve_tool_call` and `permit_id` on `execute_workspace_tool_json`; Dart gateway `approveToolCall`.
  - A stream that breaks after output is kept as an interrupted reply and never retried.
  - Runs stop with a diagnostic when history, story context, steering, or the final run state cannot be read or written; corrupt settings, story JSON columns, and `hooks.json` surface errors.
  - `lock_or_recover` replaces raw `Mutex::lock`; `clippy.toml` bans `Result::unwrap_or_default`, `Mutex::lock`, `reqwest` builders outside `http_clients.rs`, `thread::sleep`, and unbounded channels; `just guard` rejects dropped storage/vault results outside tests.
  - Stop races `dispatch()` and every chunk wait (50 ms bound).
- **Verification**: `cargo clippy --workspace --all-targets -D warnings` clean; `cargo nextest` 99/99; `dart test tools/bistre_guard` 23/23; `flutter analyze` clean; FFI round-trip and a11y gallery Flutter tests pass on Windows; `just guard` and `just i18n-check` pass. Each new regression test asserts the fixed behaviour (signing-key, forged stage, parsed loopback, concurrent reservation, unapproved edit, broken stream, Stop latency).
- **Correction to §7/§8**: `rustls-platform-verifier 0.7.1` *is* in use (through `reqwest 0.13`, `cargo tree -i rustls-platform-verifier`); the research doc's claim is accurate.
- **Environment**: in Git Bash, `/usr/bin/link` shadows MSVC `link.exe`; run Rust builds from PowerShell (or use `just install-hooks`, which fixes `PATH` for hooks).

## 10. M2: Core Lifecycle, Efficiency, Pricing, MCP (2026-11-23)
- **What changed** (PR `baros4294/bistre#5`, branch `m2-core-lifecycle`):
  - `init_runtime` shuts the previous engine down before opening a new one; engine shutdown cancels runs and drains them (5 s) before closing storage.
  - The core coalesces deltas per 16 ms frame; FFI turns a bus lag into `events_lagged` (the app reloads) instead of a `StorageBusy` error; Dart ignores unknown event kinds.
  - Streaming checkpoints append only new text (250 ms / 4 KiB cadence).
  - `ffi_err` keeps detail codes (`diag.<key>:<detail>`); harness endpoints live in `crates/bistre-ffi/src/api/harness.rs`.
  - Daemon: deadline-driven housekeeping instead of a 2 s poll, 16 IPC connections max, accept backoff, malformed RPC params rejected, two Tokio workers.
  - Pricing (Q2a): refresh at most daily at engine start (Settings toggle, default on) or on **Update prices now**; cached in `<data_dir>/pricing_cache.json` with a format version; runs never fetch.
  - MCP (Q3): `rmcp` removed (`ADR-0018`); unused stdio helpers removed until the stdio slice.
  - Spec 00 §6 **Implementation Status** table (guarded); run step limit unified at 24; text-only replay pinned by a test.
- **Verification**: workspace clippy `-D warnings` clean; `cargo nextest` all green (100 tests); `cargo deny` ok; `flutter analyze` clean; `flutter test` 29/29; `just guard`, `just i18n-check`, `dart test tools/bistre_guard` pass; daemon `--health-check` smoke passes.
- **Still open from the plan** (not done, by design of scope or time): typed DTOs for the remaining `*_json` FFI endpoints; reader-connection pool + `spawn_blocking` for storage calls (Spec 00 §6 notes readers are per query); cross-process database lock (the daemon and app may share a data dir by design, ADR-0003; needs a decision first); 16-step quantized compaction and the 8,000-char reasoning handoff; English server labels in `local server discovery` and seeded names (`Default Workspace`).

## 11. M3–M6: Flutter, v2.6.0 Parity, Lints, CI (2026-11-23)
- **Branches / PRs**: M2 merged (`baros4294/bistre#5`). M3 is `baros4294/bistre#6` (`m3-flutter`, base `main`); M4–M6 is `baros4294/bistre#7` (`m4-parity`, stacked on `m3-flutter`; retarget it to `main` after #6 merges, then close and reopen it so CI runs).
- **M3 (Flutter architecture)**: the root `WidgetsApp` listens only to `FolioController.appearance` + locale (theme memoized); markdown parse LRU; no message entrance replays; generation/sequence guards for thread switch, search (150 ms debounce), and settings (200 ms debounced saves); events subscribed first with bounded re-subscription; boot states with a Try again page; Undo-window deletes committed on pause/close; lazy sidebar; composer clears only the sent text; boot logic in `apps/bistre_app/lib/features/shell/folio_controller_boot.dart`.
- **M4 (parity with renders of Parchment v2.6.0, Spec 08 §4)**: header, header status, pickers, empty chat, messages (hover/focus actions), composer (placeholder, mode control, quiet Send, labelled `used/limit (pct%)` ring with limits from the public model lists), scroll, and motion (150/110/180 ms) are Closed. Thinking, code card, copy, and targets are Partial (see their rows). Open: chat tabs, floating error notice, sidebar grouping by assistant with `+` beside search, settings search.
- **M5 (lints and guards)**: `bistre_lints` rejects `SizeTransition`, `AnimatedCrossFade`, `AnimatedDefaultTextStyle`, `AnimatedFractionallySizedBox`, `Positioned(left/right)`, and `TextAlign.left/right`; `bistre_i18n` rejects banned UI words (all locales) and glossary terms (English); `bistre_guard` rejects test retries.
- **M6 (CI and tests)**: `ci.yml` is callable and `release.yml` reuses it; Linux CI launches the release build and enforces Spec 11 budgets (`perf --strict` under xvfb); Android-target clippy; doctests; `cargo deny` on Linux only; release APK budgets; `sign-and-publish` refuses unsigned releases; Dependabot merges with `--rebase`. New tests: SSE chunk-boundary property test (`proptest`), registry context limits, root-appearance, thread race, delete flush, boot retry, 40 px tap target.
- **Verification (local, Windows)**: workspace clippy `-D warnings` clean; `cargo nextest` 102/102; `cargo deny` ok; `flutter analyze` clean; `flutter test` 34/34; `dart test` guard 24, i18n 3, lints 6; `just guard`, `just i18n-check` pass. M2 CI green on Linux, Windows, Android.
- **Not done yet (open, with reasons)**:
  - Full `FolioController` split into domain notifiers, paged history (`list_nodes_page`), context-usage computed in core, and the tool timeline wired to engine events (no `ToolActivity` engine event exists; tools are not model-invoked yet).
  - Typed DTOs for the remaining `*_json` FFI endpoints; reader pool + `spawn_blocking`; 16-step quantized compaction and the 8,000-char reasoning handoff.
  - Tests: `TestResult` + `?` across Rust tests (many still use `.ok()` + `assert!`); Linux golden comparison for the gallery; a CI `perf-linux` profile-build frame timing (the launch/perf gate uses the existing runner).
  - Shared CI setup composite action (provisioning is still duplicated between `ci.yml` and `release.yml`).
- **Owner actions**: provision the minisign key (`MINISIGN_SECRET_KEY`, `MINISIGN_PASSWORD` in a `release` environment with required reviewers) and embed the public key in `OFFICIAL_RELEASE_PUBKEY_B64`; OTA and tag releases stay disabled until then.

## 12. M4 Parity Closure (2026-11-23)
- **What changed**: chat tabs under the header; v2.6.0 error notice (status dot, one plain sentence, one fix, live region); code card wrap/fold/save/copy icon buttons; settings search (matches page names and every label on each page, Enter opens the first match); every `' · '` meta join goes through `BistreLocalizationController.joinMeta` (separator `app.meta_separator`, each fragment in a first-strong isolate so mixed-direction text keeps its order).
- **Spec 08 §4 parity**: every row Closed except Thinking, which is Blocked: v2.6.0 shows a tool count, but runs execute no model-directed tools yet (native tool calling is its own slice), so a count would always be 0.
- **CI fix**: zizmor 1.32 flags `uses: ./.github/workflows/ci.yml` (self-repository audit) and suggests `$/`, but actionlint 1.7.12 rejects `$/` (rhysd/actionlint#711, #780). `release.yml` keeps `./` with an inline `zizmor: ignore[self-repository]` that states why; switch to `$/` once actionlint supports it (the guard's pin and timeout checks would then need to accept `$/`).
- **Verification (local, Windows)**: `flutter analyze` clean; `flutter test` 36/36; `just guard`, `just i18n-check`, `just fmt-check` pass.
- **Open items**: unchanged from §11 apart from the parity rows above.
- **Linux launch gate: idle RSS (owner decision 2026-11-23: report-only on xvfb, `--rss-report-only`, Spec 11 §5)**: the new `perf --strict` gate failed `desktop_idle_rss_after_10s` (Spec 11: budget 120 MB, hard fail 160 MB). The probe now prints RSS at first frame, frames while idle, a `/proc/<pid>/smaps` breakdown, threads, and the data dir.
  - Measured on `ubuntu-24.04` under xvfb (llvmpipe software GL): 194-203 MB at the first (boot) frame; 362-498 MB after 10 s before the fix; 378 MB after it. Only 6 frames render while idle.
  - Fixed: the boot price sync parsed ~13.6 MB of lists into `serde_json::Value` on Tokio workers. `registry.rs` now uses typed views; counts match the live lists exactly. A full sync peaks at ~31 MB working set (Windows daemon). Growth after the boot frame fell from ~300 MB to ~195 MB.
  - Remaining: `RssFile` ~118 MB (including libLLVM 57 MB and libgallium 13 MB, which exist only because of software GL), `[heap]` 72 MB, `[anon]` 161 MB, Dart heap 13.5 MB. The rest grows when the real UI first renders, consistent with llvmpipe JIT-compiling shaders. This is not proven, because no GPU-backed or Windows release measurement exists yet (local `flutter build windows` lacks a Visual Studio toolchain).
  - The 120 Hz streaming p95 (7.5 ms) is also reported `OVER` (7.6-12.5 ms on the debug test VM; not a hard fail).
  - Open: measure idle RSS on a GPU-backed or Windows release build (needs a local Visual Studio toolchain or a Windows CI launch step), then restore the hard fail.

## 13. M7: Rebuild Isolation (2026-11-23)
- **What changed**: frequent state left `FolioController`'s shell-wide notification. `ToastNotifier` and `SearchNotifier` live in `apps/bistre_app/lib/app/shell_notifiers.dart`; `draftSavedState` and `sidebarFilterQuery` are `ValueNotifier`s. Only the toast overlay, the search bar plus feed, the composer's Draft saved label, and the sidebar list listen to them. The engine's `DraftSavedEvent` echo no longer notifies, because it changes no state. The controller keeps delegating getters, so call sites did not change.
- **Why this scope**: after this, the shell rebuilds only for user actions and run start/finish. Splitting the catalog, runs, and story state into separate controllers would not remove any frequent rebuild, so the §11 "full split" item is closed as unnecessary.
- **Regression test** (`anti_pattern_regression_test.dart`, "rebuild only their own widgets"): a toast plus three search keystrokes, a draft save, and its engine echo rebuild the sidebar 0 times (3 / 1 / 1 before); two sidebar-filter keystrokes rebuild the feed 0 times (2 before). Each assertion was shown to fail without its fix.
- **Verification (local, Windows)**: `flutter analyze` clean; `flutter test` 37/37; `just guard` passes.
## 14. Rust Tests Report Their Errors (2026-11-23)
- **What changed**: test setup written as `let x = e.ok(); assert!(x.is_some()); let Some(x) = x else { return };` (and the `if let Some(..)` variant) now reads `let x = e?;` in tests that return `TestResult`. A failure prints the `DiagnosticKey` or I/O error instead of `assertion failed: x.is_some()`. `.ok().unwrap_or_default()` in tests, which turned an error into an empty list, also became `?`.
- **Remaining**: 127 `.ok()` sites in test code feed `assert_eq!(x.map(..), Some(..))`. They still fail loudly, but without the error text; convert them by hand as those tests are touched.
- **Verification (local, Windows)**: workspace clippy `-D warnings` clean; `cargo nextest` 103/103; `just guard` passes.
## 15. CI Scripts, Storage Readers, Off-Worker Storage (2026-11-23)
- **CI provisioning** (`baros4294/bistre#10`): `.github/scripts/install-rust.sh` and `provision-android-sdk.sh` replace 6 and 2 copies in `ci.yml`/`release.yml`. The two Android copies had already drifted: the release one lacked the NDK `test -d` check. These are scripts, not a composite action, because zizmor flags local `uses: ./...` actions and actionlint 1.7.12 cannot parse the `$/` form. The §11 "shared CI setup" item is closed.
- **Reader pool: measured, not built**. Opening a read-only connection costs ~56 µs, against ~1.1 ms for `list_threads` over 300 chats (release build). A pool saves ~5% of a read, while a drop guard would need `unsafe` or a panic path, or a closure API across 37 call sites. The storage module doc no longer claims a pool; the numbers are in Spec 11 §2.
- **`spawn_blocking`**: `off_worker` moves export, backup, full-text search, and `list_nodes` (from FFI) onto Tokio's blocking pool. The regression test (`off_worker::tests`) deadlocks into a 5 s timeout when the call runs inline; this was confirmed. Run-internal history loads (`engine_runs::load_turn_context`) are still synchronous.
- **Verification (local, Windows)**: clippy `-p bistre-core -D warnings` clean; `cargo nextest -p bistre-core` 78/78.
- **Open (unchanged from §11 unless noted)**: paged history (context usage moved to core in §16); typed DTOs for `*_json` endpoints; 16-step quantized compaction and the 8,000-char reasoning handoff; Linux gallery goldens; the tool timeline (blocked on native tool calling); idle RSS measured on a GPU or Windows release build; the 120 Hz streaming p95; 127 `.ok()` test sites.

## 16. Context Usage in Core, Silent-Pass Tests (2026-11-24)
- **Context usage in core**: the composer gauge used to estimate tokens in Dart from every visible message, so it ignored compaction and the context pin and overstated usage after a compaction. `EngineClient::context_usage(thread, leaf)` (FFI `context_usage`) now reuses the run's own projection (`engine_runs::project_turn_history`: ancestry, pin, compaction summary, role alternation) and `compaction::estimate_branch_tokens`. Dart removed `estimateTokens`, FNV hashing, the isolate count, and a silent `onError`. Tests: `compaction::tests::context_usage_follows_what_the_next_request_sends` (the estimate drops below half after compaction and returns exactly after undo), the FFI round-trip, and a controller test.
- **Silent-pass tests**: 34 sites in 15 Rust tests read `let x = e.ok(); let Some(x) = x else { return };` with no assertion, so a failing setup passed the test. They now use `?`, and all 104 still pass.
- **Blocked, not open**: the 16-step quantized tool compaction and the 8,000-char reasoning handoff wait on native tool calling and reasoning replay (Spec 02 §42 already marks them as contract), like the tool timeline and the Thinking tool count.
- **Verification (local, Windows)**: workspace clippy `-D warnings` clean; `bistre-crypto` clippy for `x86_64-unknown-linux-gnu` clean; `cargo nextest` 105/105; `flutter analyze` clean; `flutter test` 38/38 including the live FFI round-trip.

## 17. Typed FFI DTOs, Batches 1-2 (2026-11-24)
- **Done (5 of 30 `*_json` endpoints)**: `list_cron_jobs`/`upsert_cron_job` (`FfiCronJob`), `list_checkpoints` (`FfiCheckpoint`), `list_memory_entries`/`upsert_memory_entry` (`FfiMemoryEntry`). Each DTO lives next to its endpoint in `crates/bistre-ffi/src/api/harness.rs`, with `From` conversions; the Dart gateway maps it in `apps/bistre_app/lib/bridge/bistre_engine_mapping.dart` or inline, and the JSON `fromJson` factories are deleted.
- **Bug found by typing**: Dart read checkpoint `pre_hash_blake3`/`post_hash_blake3`, while core serializes `before_blake3`/`after_blake3`, so the runs dock always showed empty hashes. The checkpoint list also shipped each file's pre-image bytes as a JSON number array; `FfiCheckpoint` leaves them in core.
- **Guard rule** (`baros4294/bistre#13`): `[silent-skip]` rejects `let x = e.ok(); let Some(x) = x else { return };` in Rust.
- **Remaining 25: convert on touch (owner decision 2026-11-24)**. The other endpoints are the six harness ones (`execute_workspace_tool_json`, `discover_local_servers_json`, `discover_mcp_server_json`, `call_mcp_tool_json`, `discover_workspace_skills_json`, `prepare_subagent_sandbox_json`) and all 19 in `api/story.rs`. A key-by-key audit of every Dart `fromJson`/`toJson` against its Rust record found them all in sync, and the live FFI round-trip already exercises the story upserts at runtime. Converting all 25 now (~1,500 lines) would buy compile-time drift protection but fix no bug, so whoever changes one of these endpoints converts it in the same change: a DTO with `From`, Dart mapping, deleted `fromJson`/`toJson`, and a live round-trip check.
- **Verification (local, Windows)**: `cargo clippy -p bistre-ffi -D warnings` clean; `flutter analyze` clean; `flutter test` 38/38 including the live FFI round-trip (cron and memory).

## 18. Plan Status After M7-M16 (2026-11-24)
- **Merged since §12**: rebuild isolation (#8); Rust tests report their errors (#9) and no longer pass silently (#12), plus the `[silent-skip]` guard (#13); shared CI provisioning scripts (#10); long storage calls off the async workers (#11); the context gauge uses core's estimate (#12); typed DTOs for cron, checkpoints, and memory, which fixed empty checkpoint hashes (#14); Gradle cache and 429-aware download retries for Android CI (#15).
- **Measured, not built** (Spec 11 §2): the reader pool (~56 µs per connection open against ~1.1 ms per read) and chat-history paging (~8 ms for 2,000 messages). Rebuild either one only after a re-measure crosses its stated trigger.
- **Owner decisions**: idle RSS is reported only on the xvfb runner (§12); the remaining 25 `*_json` endpoints convert to typed DTOs on touch (§17).
- **Blocked on native tool calling / reasoning replay** (a separate slice): the Thinking tool count, the tool timeline, 16-step quantized tool compaction, and the 8,000-char reasoning handoff (Spec 02 §42).
- **Still open**:
  - Idle RSS on a GPU or Windows release build: local `flutter build windows` lacks a Visual Studio toolchain.
  - The 120 Hz streaming p95 (7.5 ms): the debug test VM measures 7.6-12.5 ms across CI runs, which is runner noise more than signal, so it needs a profile-mode measurement.
  - 127 `.ok()` test sites in `assert_eq!(x.map(..), Some(..))` form: they fail loudly; convert as touched.
- **Owner action**: provision the minisign release key (§11); OTA and tag releases stay disabled until then.

## 19. Linux Gallery Goldens and Message Direction (2026-11-24)
- **Goldens** (`baros4294/bistre#17`): with `BISTRE_GOLDENS=compare` (the Linux `flutter-desktop` job only), each of the 35 gallery captures must equal `apps/bistre_app/test/goldens/linux/<name>.png` byte for byte. Mismatches are reported together at test teardown, and CI uploads every capture as the `ui-gallery-linux` artifact. An intended visual change replaces its baseline in the same PR after review (CONTRIBUTING, CI at a glance). Two CI runs reproduced the baselines exactly.
- **Found while reviewing the first captures**: (1) the runner had no Arabic font, so the RTL screens recorded missing-glyph boxes. CI now installs `fonts-noto-core`, and compare mode fails when no Arabic fallback loads. (2) English replies inside the Arabic UI were laid out right to left (`?reads`). Messages now take the direction of their first strong character (`features/chat/content_direction.dart`, DESIGN §7); regression test included.
- **Still open**: idle RSS on a GPU or Windows release build; the 120 Hz streaming p95 in profile mode; the minisign release key (owner action).

## 20. Rust Tests Without .ok() (2026-11-24)
- Every remaining `.ok()` in Rust test code (93 sites) and the three `let Ok(x) = x else { return }` sites now propagate with `?`. Test code has zero `.ok()` left, and the `[silent-skip]` guard rejects both early-return forms. 105/105 Rust tests pass; clippy is clean on Windows and for `x86_64-unknown-linux-gnu` (crypto, protocol).

## 21. Measurements Outside xvfb, Profile Frames, Remaining Gaps (2026-11-24)
- **M0 baseline**: confirmed on `main`. The history starts with the layered baseline commits (`chore: repo fortress`, `docs`, one `feat(<crate>)` per crate, then tools).
- **Windows release launch in CI** (`baros4294/bistre#19`): the Windows job runs `perf --strict --rss-report-only` on its release build and uploads it as `windows-release-bundle`.
- **Idle RSS on a GPU machine**: the CI bundle run on a Windows laptop (Impeller, OpenGL ES) measured 88 MB at the boot frame and ~240-255 MB within 3 s of the full render, then flat (no leak). The price sync is ~13 MB of it. Windows CI (WARP) measured 55 -> 172 MB and Linux xvfb 378 MB. Every environment is over the `120 MB` budget. Attribution needs a profile build with DevTools, which needs Visual Studio Build Tools on the developer machine.
- **Profile-mode streaming** (`baros4294/bistre#21`): `flutter drive --profile` on Linux CI measured UI-thread build p99 10.18 ms. That meets the 60 Hz budget (12 ms) and the 16 ms hard fail (enforced), but not the 120 Hz budget (7.5 ms). Parsing and code chunks are already memoized, so the next step is a timeline trace to find the per-frame cost (the open fence's Column relayout and scroll-follow are the suspects).
- **Idle frames**: ~26-29 per 10 s on the GPU machine, ~20 of them the composer's blinking caret.
- **Rust tests** (`baros4294/bistre#20`): zero `.ok()` in test code.
- **Needs the owner**: (1) the minisign release key; (2) whether to install Visual Studio Build Tools for RSS attribution, or how to restate the RSS budget; (3) whether to pursue 120 Hz now; (4) the native tool calling slice, which unblocks the tool count, tool timeline, quantized compaction, and reasoning handoff.

## 22. v2.6.0 Parity Reopened; Owner Decisions (2026-11-24)
- **Parity is not done.** Spec 08 §4 compared screenshots, not behaviour. A code audit of v2.6.0 (`composeApp/src/commonMain/kotlin/io/parchment/ai/ui`, composable inventory plus greps) found these gaps in Bistre:
  - **Composer**: the clickable context-ring breakdown (7 categories, stacked bar, compact/summarize/pricing actions), a real o200k tokenizer, the thinking/effort step slider (Off to Max plus custom), the tools drawer, and media controls.
  - **Motion and scrolling**: press/hover spring feedback on every clickable, disclosure height animation, smooth wheel scrolling, the streaming text pacer, and colour/value transitions.
  - **Settings**: full-width content, nine theme presets, profile name and picture, a per-chat spend limit, and per-setting search results.
  - **Messages**: the usage pill, web sources drawer, raw wire drawer, attachment viewer, generated media, drag-and-drop, pinned replies, chat notes, SVG preview, context menu, and tooltips.
  - **Navigation**: the mobile tab switcher, and a searchable model picker with privacy badges.
  - **Agent and MCP**: the permission editor, user question panel, and MCP registry browser.
  - **Platform**: a GPU resource cache cap (v2.6.0 caps Skia GPU resources at 48 MiB because Intel UMA grew past 250 MB).
  A commit-by-commit UI audit is still owed.
- **Owner decisions**:
  1. Animate disclosure heights like v2.6.0 (lift the layout-animation ban for disclosures).
  2. Spring press-scale and hover-lift on every clickable.
  3. Smooth wheel scrolling on desktop.
  4. A streaming text pacer (~92 chars/s with elastic catch-up).
  5. Settings content fills the window width (the 740 px reading measure is for chat prose only).
  6. Desktop idle memory is budgeted as app-owned memory (PR #25).
  7. When a v2.6.0 behaviour conflicts with a Bistre rule, ask the owner; do not assume the rule wins.
  Decisions 1-5 still need AGENTS.md §6-§7, DESIGN.md §6, and the `bistre_lints` layout-animation rule updated alongside their implementation.
- **Performance**: 8-line code chunks cut per-frame text layout from 4.03 to 0.85 ms (PR #24). Idle memory is attributed to the graphics stack, and the app's own share is about 25 MB (Spec 11 §5).

