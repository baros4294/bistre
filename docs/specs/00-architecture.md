# Spec 00 — System Architecture & Execution Topology

## 1. Layer Boundaries
Bistre enforces strict one-way hexagonal dependencies (`ADR-0001`, `ADR-0003`):
- **Thin Flutter UI (`apps/bistre_app`)**: Rendering, runtime ICU localization, accessibility, keyboard focus, and minimal platform shims (`WindowCompat.setDecorFitsSystemWindows`, run-scoped FGS, and the `dev.bistre.app/vault_key` Android Keystore channel that only carries the opaque vault data key into `init_runtime`, ADR-0010). Zero HTTP, SQL, LLM prompt logic, or UI kit dependencies.
- **Thin FFI Bridge (`crates/bistre-ffi`)**: FRB `2.13.0` DTO translation, runtime initialization (re-initialising shuts the previous engine down first, so there is never a second SQLite writer), and `16ms` coalescing `StreamSink` event forwarding. Zero business logic. Engine shutdown cancels runs and waits up to `5 s` for them (a `JoinSet`) before closing storage.
- **Pure Rust Domain Core (`crates/bistre-core`)**: Owns `EngineClient`, canonical DAG orchestration, providers, self-healing, AIO registry, in-process tools, MCP, lorebooks, trust/wallet shields, and OTA verification planning. Zero Flutter/FFI/GUI knowledge.
- **Core Network & Policy Modules (`ADR-0017`)**: `providers::dispatch` (single provider path with key rotation, heal ladder, typed retry hints), `sse` (`SseFramer`), `ssrf` (`PublicWebTransport`), `registry` (live pricing), `credentials`, `error_policy`, `approval` (one-use tool permits), `import_policy`, and `process_util` (the only child-process constructor).
- **Storage & Crypto (`crates/bistre-storage`, `crates/bistre-crypto`)**: SQLite WAL single-writer actor + FTS5; `minisign-verify` offline verification + `SecretVault` trait.
- **Desktop Services (`crates/bistre-daemon`, `crates/bistre-updater`)**: Resident local background daemon (tray, UDS/Named Pipe IPC, Remote Bridge mTLS server) and side-by-side crash-loop rollback updater.

## 2. One Brain, Any Body (`EngineClient` Trait)
`crates/bistre-core/src/engine_client.rs` defines the async `EngineClient` trait with three interchangeable backends behind one FRB contract:
1. **`InProcessEngine`**: Embedded directly inside the process (Android production + Slice 0 desktop).
2. **`LocalIpcEngine`**: Connects thin Flutter GUI over Unix Domain Socket (`$XDG_RUNTIME_DIR/bistre/daemon.sock`) or Windows Named Pipe (`\\.\pipe\bistre-<user>`) to active-scoped `bistre-daemon` (`ADR-0013`). Closing the Flutter window terminates the GUI process completely (0 MB Impeller/Dart RAM) while `bistre-daemon` stays alive strictly while an agent run or scheduled cron task is active (≤30 MB RSS), exiting cleanly once idle.
3. **`RemoteBridgeEngine`**: Connects mobile/desktop UI over TLS 1.3 mTLS WebSocket to a QR-paired remote `bistre-daemon` over LAN/Tailscale.

## 3. Process, Thread & Shutdown Ownership
- Every background task runs on a bounded Tokio runtime or dedicated named OS thread (`bistre-sqlite-writer`).
- Channels are strictly bounded (`cap=256`); contiguous token deltas merge under backpressure so memory never grows unboundedly.
- Graceful shutdown drains active runs (or checkpoints cancellation state), flushes unsent drafts, runs `reclaim_storage()` (`PRAGMA wal_checkpoint(TRUNCATE)` + `PRAGMA optimize`), and releases OS kernel locks (`flock` / Win32 named mutex).

## 4. Phased Rollout Waves (Day-1 Abstractions)
All AIO, performance, i18n, and two-track OTA abstractions are locked from Day 1 while features ship vertically in three waves:
- **Wave 1 (Slices 0 → v0.1.0, self-updatable from Day 1)**: Walking Skeleton (`bistre_app`, `bistre-core`, `bistre-storage`, `bistre-crypto`, `bistre-daemon`, `bistre-updater`), Big 3 + OpenAI-compatible wire dialects, 5-class self-healing, synthesized AIO registry + task slots, in-process Rust tools + MCP (`2026-07-28` + legacy fallback), worktree sub-agents, Lorebooks & `SKILL.md` loader, Dual Trust + Wallet Shield, and QR-paired mTLS Remote Bridge.
- **Wave 2 (Voice & Image AIO)**: Speech-to-Text (`stt_transcribe`), streaming Text-to-Speech (`tts_speech`), and schema-driven OpenAPI async image generation/editing (`image_generate_edit`) with WAL-before-POST idempotency.
- **Wave 3 (Video & Fireside Full-Duplex)**: Async video generation/editing/dubbing (`video_generate_edit`) and Fireside full-duplex voice (`voice_full_duplex`, Android BLE Audio + Oboe + AEC3 + Silero VAD).

## 5. Source Module Layout (`<= 1,500` Lines per File)
`just guard` rejects any non-generated `.rs` / `.dart` file above 1,500 lines with no allowlist; generated FRB output (`frb_generated.*`, `apps/bistre_app/lib/bridge/api.dart`, `apps/bistre_app/lib/bridge/api/`) and `*.g.dart` are exempt. Large modules split by responsibility:
- **`bistre-core`**: `lib.rs` (`InProcessEngine` state + bootstrap), `engine_client.rs` (`EngineClient` trait), `engine_runs.rs` (`StreamServices`, durable stream loop, write-mode prompt, clock helpers), `engine_impl.rs` (`impl EngineClient for InProcessEngine`), `tests.rs`.
- **`bistre-storage`**: `lib.rs` (`StorageHandle`, threads/nodes/drafts/search/export/backup), `catalog_repo.rs` (providers + assistants), `schema.rs` (connection pragmas, Expand migrations, seeding, checkpoint/reclaim), `tests.rs`.
- **`bistre-ffi`**: `api/mod.rs` (FRB entrypoints + DTOs: runtime, providers, assistants, threads, settings, runs, events), `api/harness.rs` (tool approval and execution, checkpoints, compaction, MCP, memory, skills, cron), `api/story.rs` (character cards, personas, story bible), `dto_mapping.rs` (domain → DTO mapping, 16 ms delta coalescing helpers, and `ffi_err`, which returns `diag.<key>` or `diag.<key>:<detail_code>` so the detail code is never dropped).
- **Flutter app**: `bridge/bistre_engine.dart` (`BistreEngineGateway` + FRB implementation; DTO-to-model mapping in its part `bistre_engine_mapping.dart`) re-exports `bridge/engine_models.dart` and `bridge/engine_story_models.dart`; `FolioController` (`features/shell/folio_controller.dart`) keeps all state and core flows, with actions in `part` extensions (`folio_controller_catalog.dart`, `folio_controller_threads.dart`, `folio_controller_studio.dart`) that notify through the private `_notify()`. State that changes often has its own notifier so only its widget rebuilds: `appearance` (root `WidgetsApp`), `liveTurn` (streaming reply), `toast` and `search` (`app/shell_notifiers.dart`), `draftSavedState`, and `sidebarFilterQuery`; the shell listens to the controller only for user actions and run start/finish. Widget tests share `test/support/fake_engine_gateway.dart`.
- Split-out Rust unit tests live in `src/tests.rs` declared by `#[cfg(test)] mod tests;` and are exempt from the hardcoded-model gate like inline test modules.

## 6. Implementation Status
The specs describe the target. This table records what the code does today; update the row in the same change that moves a feature (`just guard` requires this section). **Implemented**: wired end to end and tested. **Partial**: works with the gap named. **Built, not wired**: tested Rust code with no production caller yet. **Planned**: spec only.

| Feature | Status | Where / gap |
|---|---|---|
| SQLite WAL single writer, Expand-Contract migrations, FTS5 | Implemented | `crates/bistre-storage`; readers open a fresh read-only connection per query (no pool yet) |
| Provider streaming, `SseFramer`, 400 heal ladder, multi-key failover, retry hints, one-shot 413 compaction | Implemented | `providers.rs`, `sse.rs`, `error_policy.rs`, `engine_runs.rs` |
| No retry after partial output; Stop within 50 ms | Implemented | `providers.rs` |
| Wallet Shield with spend reservations (fail closed), parsed loopback | Implemented | `wallet.rs`, `net.rs` |
| Tool approval: one-use permits from `approve_tool_call` | Implemented (core + FFI) | no approval card calls it yet; the UI does not run workspace tools |
| Workspace tools (`cap-std`, blake3 line hashes, stale-read guard, Rewind) | Partial | `grep`/`glob` walk without a time bound; no `> 64 KiB` blob spill (256 KiB truncation) |
| Native model tool calls (`builtin_tool_schemas`, `heal_and_dedup_tool_calls`) | Built, not wired | requests send no tools; tools run only through FFI |
| MCP over Streamable HTTP, `2026-07-28` → `2025-11-25` | Partial | no stdio transport, restart budget, bearer tokens, or deferred `mcp_schema`; new session per call (`ADR-0018`) |
| `PublicWebTransport` (public-IP pinning, validated redirects) | Implemented | `ssrf.rs` |
| OTA: streamed SHA-256, mandatory minisign, `VerifiedManifest` | Implemented | disabled until a release key is embedded (`OFFICIAL_RELEASE_PUBKEY_B64`) |
| Updater crash-loop rollback | Built, not wired | `bistre-updater` only runs `--verify-manifest`; `plan_next_boot` is test-only |
| Pricing registry: daily cached refresh, Settings toggle | Implemented | `registry.rs` |
| Usage dedupe by `request_id` | Planned | |
| Compaction: reversible, role alternation | Partial | no 16-step quantized tool compaction, no 8,000-char cross-provider reasoning handoff; `should_auto_compact` is test-only |
| Daemon: health, IPC RPC, event-driven housekeeping | Partial | cron jobs are found due and logged, not executed; app-side IPC client (`ipc_client::send_daemon_rpc`) has no caller |
| Sub-agent worktree sandboxes | Built, not wired | `prepare_subagent_sandbox` has no UI caller; `cleanup_worktree_sandbox` is test-only |
| Writing Studio agents (prewriter, librarian, laser edit), card PNG export | Built, not wired | `story/writer_agents.rs`, `card_io::export_card_png` |
| Remote Bridge / mTLS / tray | Planned | Spec 07 |
