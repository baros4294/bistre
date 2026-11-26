# Bistre execution ledger

Plan: `C:\Users\Baros\Downloads\bistre-handoff-2026-11-25.md` (Part 1; IDs R/U/C/P/G/X/A-S/A-W/A-SE).
States: `[ ]` open, `[r]` red test recorded, `[g]` green, `[v]` verified (gates + docs), `[b]` blocked (reason), `[u]` UNVERIFIED (no device/host).
Rules: re-read this file at session start and after every compaction. It holds IDs, states and evidence only.
A slice moves to `[v]` only after the final gate passes; never edit evidence lines after `[v]`.

## Current

Wave: W8   Slice: W8.1   Next action: wire dead settings (Appendix Phase 3 table), localization leaks, accessibility.

## Decisions (owner, 2026-11-25)

- D1 (b): "Approve for this chat" covers the exact command for the whole chat; tool-wide grants only for Tier-0 reads.
- D2 (a): approval waits indefinitely, releases keep-awake, shows a badge; no auto-deny.
- D3 (a): Esc stops a run only from a focused, empty, non-composing composer with no overlay; plus Stop button and a dedicated shortcut.
- D4: Windows ships unsigned (SmartScreen documented; C23 code signing dropped). Android release keystore created by the owner; `release` env secrets `ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Pinned cert SHA-256 `AF:EC:66:EA:61:57:A7:62:F4:F9:DE:7D:BB:78:B4:66:A9:AD:3B:A4:C7:0E:7C:95:C5:C8:70:F9:57:2E:04:BC`. v0.1.2 APK was debug-signed (release run 45501385089: `ANDROID_KEYSTORE_B64` empty); no migration notes needed.
- D5 (a): Spec 11 / AGENTS section 7 budgets become hard failures.
- D6: add an FTS5 trigram index.
- D7: Impeller is the default renderer on Windows and Linux; `BISTRE_IMPELLER=off` falls back to Skia on both. If Impeller breaks a budget, keep Impeller and report it.
- D8: build Linux packages in an older container (glibc 2.31).
- D9: local-only crash report with secrets removed, "Copy report" on next launch.
- Execution: keep going through all waves; `just check-all` and `just ui-gallery` run once at the end (weak laptop). Per slice: `cargo check -p`, targeted tests, `just codegen-frb` after FFI changes.
- Git: uncommitted until everything is done; then Conventional Commit layers (this file included), push a non-main branch, run release dry run + packaging smoke there, open a PR. No tag, release or merge.
- No Linux host or Android device: those live checks are `[u]`.

## Evidence notes

- Stutter (owner video `VID20261125171955.mp4`, 2026-11-25): Windows, sidebar open/close and scrolling. Frame scan of the walkthrough found no torn frames (best seam ratio 0.87 over 704 motion frames), so it is frame pacing, not tearing. During the sidebar animation the chat column reflows every frame and the header title jumps (A-W 3a/3b).

## W0 Baseline and harness
- [g] W0.1 Rust SSE fixture loader + MockServer (crates/bistre-core/src/test_support.rs, fixtures/sse/*)
  - green: test_support::fixture_tests::{every_dialect_text_fixture_streams_hello_world, gemini_generate_content_fixture_streams_after_interactions_404}; providers tests migrated onto the harness
  - open: fixtures hand-written from docs, re-verify live in W4.9; Scripted::with_header used first in W1.3 (dead-code warning until then)
- [g] W0.2 C11 providers stop test + registry wait on paused tokio clock (tokio test-util dev-dep); storage FTS timing -> EXPLAIN QUERY PLAN index assert (SEARCH_*_SQL consts)
  - open: FTS query latency probe belongs in just perf (W6.3)
- [g] W0.3a C10 FolioController clock injection; sidebar uses ctrl.now(); gallery uses galleryClock()
  - red:   shell_harness_test 'sidebar day groups follow the injected clock' FAILS with DateTime.now() in folio_sidebar.dart (2026-11-25)
  - green: same test passes with ctrl.now()
- [b] W0.3b C10 vendored Noto Sans Arabic subset (needs owner OK to download the font)
- [g] W0.4 test/support/shell_harness.dart + FakeEngineGateway calls/gate/release/emit/seedThread
  - green: shell_harness_test 'the shell pumps at phone, desktop, 200% text and RTL'
- [g] W0.5 C12 test-rust adds cargo test --doc + bistre_guard smoke (tools/bistre_guard/lib/binary_smoke.dart); boundary = cargo deny wrappers (already in lint-rust)
  - green: tools/bistre_guard/test/binary_smoke_test.dart; bistre_guard smoke OK
  - docs:  ADR-0016 item 7, CONTRIBUTING item 7

## W1 Money, permissions, safety
- [g] W1.1 R2 P9 P10 P11 D1 D2 approvals
  - red:   cargo nextest -E 'test(approval_flow_tests)' on old logic (2026-11-25): approving_one_chat... FAIL (chat A's waiter replaced by B, A auto-denied), approve_for_chat... FAIL (no re-ask), a_denied_call... FAIL (re-asked, 15 s Elapsed), stop_ends... FAIL (2nd request sent); Dart approval_flow_test FAIL (no Stop button)
  - green: same 4 + an_approval_waits_without_a_time_limit_and_ends_on_cancel + waiting_for_the_user_releases_keep_awake; end_to_end_agentic...; test/approval_flow_test.dart (phone + desktop)
  - files: bistre-protocol events.rs (Stop), agent_tools.rs (ApprovalKey, ApprovalMemory, wait_for_decision on wake Notify, no timeout), power.rs (pause_for_user), engine_*.rs, lib.rs, ffi harness.rs + codegen, Dart gateway/controller/timeline/cards/feed
  - docs:  Spec 04 Live approvals, Spec 06 approval card, SECURITY.md, l10n tool.stop (+ contexts of tool.approve_chat/tool.deny)
- [ ] W1.2 R4 R3 R5 R22 A-S1 A-S4 A-S6 wallet
- [g] W1.3 R6 A-S8 A-S10 R19 egress (+ R44 live URL base path/model encoding, TTS missing key fails closed)
  - red:   providers a_cross_host_redirect_never_forwards... FAIL (old client followed the 307 and returned the other host's reply: R6 confirmed, no longer [U]); egress an_invalid_stored_header... FAIL (sent anyway); egress a_pinned_provider_that_is_off... FAIL (fell back) (2026-11-25)
  - green: those + ota_redirects_only_to_https_or_loopback, custom_headers::tests (3), headers_are_validated_on_save_and_cleared_when_the_origin_changes, voice live_targets_encode_secrets...
  - files: http_clients.rs (provider no redirects, ota_client), lib.rs (ota_http, pinned resolution), custom_headers.rs (new), provider_prefs.rs (load fails closed, save validates, origin binding), providers.rs (typed headers), engine_runs.rs (overrides before reservation), engine_impl.rs (save_provider_overrides, origin clear), voice.rs (live_ws_target), protocol keys, ffi harness, Dart composer/studio/gateway
  - docs:  Spec 02 (4 bullets), SECURITY.md credentials + egress, l10n diag.provider.{headers_invalid,headers_cleared,body_invalid,pinned_unavailable}
- [g] W1.4 A-S2 A-S3 A-S5 A-S7 permissions and imports
  - red:   approval_flow an_unreadable_permission_map... FAIL and malformed_tool_arguments... FAIL (15 s, prompted); storage v1_expand_migration... FAIL on TrustPreset::parse('guided-craft') (2026-11-25); storage_files settings_import_never_loosens... FAIL (left None); approval_flow pre_tool_hooks... FAIL with the hook gate disabled
  - green: those + hooks::tests::hooks_run_only_for_the_approved_file; Dart settings_import_test, workspace_hooks_test (phone + desktop)
  - files: protocol (TrustPreset::parse -> Strict; keys HooksApprovalRequired, ImportLoosensSafety), agent_tools.rs (policy_unreadable, parse_tool_arguments, pre/post hook gate), hooks.rs (digest-bound HookRun), storage_files.rs (import policy), engine_* (hooks status/approve, import allow_loosening + invalidate), ffi harness/media + codegen, Dart (agent settings hooks section, composer Review hooks, import toast)
  - also: agent settings phone overflows fixed (MCP transport row, web search header) found by the new phone test
  - docs:  Spec 04 hooks + fail-closed policy, Spec 06 presets/imports, SECURITY.md, l10n (diag.hooks.approval_required, diag.import.loosens_safety, settings.import_anyway, chat.fix.review_hooks, settings.agent.hooks_*)
- [g] W1.5 R27 R28 A-S9 A-S11 OTA trust, MCP call-once, shutdown
  - red:   ota digest_and_url_policy FAIL (localhost.evil.com accepted) and staging_refuses_a_version_that_is_not_newer FAIL; mcp a_failed_tool_call_is_never_resent... FAIL (tools/call sent twice); egress shutdown_wakes_a_run_waiting_in_backoff FAIL (run left Running after 5 s abort) (2026-11-25)
  - green: those; Dart app_exit_test (exposed + fixed: controller resubscribed to events after its own shutdown)
  - files: ota.rs (require_secure_url parsed, stage strictly newer), mcp.rs (negotiate first, close via DELETE, transport delete), engine_impl.rs (shutdown wakes runs), Dart main.dart (didRequestAppExit, detached), folio_controller.dart (shutdownEngine), folio_controller_boot.dart
  - docs:  Spec 10, Spec 04 MCP, Spec 00 shutdown
  - note:  on a Windows host, widget tests that await desktop platform channels must use tester.runAsync (fake clock never completes them)
- [g] W1.6 R29 daemon IPC pipe ACL
  - finding: default named-pipe DACL lets others read only, but the endpoint name is predictable so another user could squat it first; the client wrote requests without checking the server
  - green: bistre-crypto pipe_identity::tests::the_owner_only_descriptor_names_the_current_user; bistre-core ipc_client::pipe_tests::a_same_user_daemon_pipe_passes_the_identity_check
  - [u] the refusal path (pipe served by a second Windows account) needs a second account: live check only
  - files: bistre-crypto pipe_identity.rs (new audited shim), Cargo.toml windows-sys +Win32_Security_Authorization +Win32_System_Pipes, bistre-daemon (owner-only pipes, reject_remote_clients, +bistre-crypto dep), ipc_client.rs (server identity check; Unix peer uid)
  - docs:  Spec 00 LocalIpcEngine, ADR-0003, SECURITY.md
- [g] W1.7 C1 C2 release signing (+ D4 unsigned Windows documented)
  - files: release.yml (build-android without secrets; sign-android with pinned cert, one-signer check, attest), ci.yml (explicit BISTRE_ALLOW_DEBUG_SIGNING), build.gradle.kts (CI refuses silent debug fallback), provision-android-sdk.sh --build-tools-only
  - [u] verified only in the final CI release dry run (apksigner re-sign replaces debug signature)
  - docs:  Spec 10, SECURITY.md, README platform table
- note W1: guard file-size split -> agent_approvals.rs (from agent_tools.rs), engine_extras inner fns (from engine_impl.rs), bistre_engine_mapping.dart mappers

## W2 Data integrity and concurrency
- [g] W2.1 U1 U2 thread switching + append_node parent check
  - red:   thread_switch_test 'Enter while the next chat is loading...' FAIL (sent into thread-1 under A's parent); 'a send that finishes after switching...' FAIL (A's node in B's nodes); mode-change test FAIL with guard off; storage a_parent_from_another_thread_is_refused FAIL (2026-11-25)
  - green: same; all 4 thread_switch tests (phone + desktop for U1)
  - files: folio_controller.dart (_switchingToThreadId, isSwitchingThread, _isStillOn, staged _loadAndCommitThread), folio_controller_threads/catalog/studio (guarded writes), bistre-storage append_node, protocol key
  - docs:  Spec 01, l10n diag.storage.parent_thread_mismatch
- [g] W2.2 R30 U5 U7 R31 (+ R38 index) concurrent runs and deletes
  - red:   egress regenerate_mid_stream... FAIL (second run started before first finished); thread_delete_test U5 FAIL (no cancel), U7 FAIL (delete committed on inactive); storage deleting_a_chat_removes_its_event_log... FAIL (body logged); v10_migration... FAIL (2026-11-25)
  - green: same + deleting_a_25k_message_chat_removes_every_node (32 s -> 7 s, inserts dominate)
  - files: lib.rs (run_done watch, stop_previous_run, PREVIOUS_RUN_STOP_TIMEOUT), engine_impl.rs (await before runs), protocol EngineEvent::without_content, storage harness (redact on append), lib.rs delete_thread cascade, schema.rs v10, CURRENT_SCHEMA_VERSION 10, test_support (concurrent MockServer, then_hang), Dart catalog (_cancelRunOf), main.dart (lifecycle)
  - docs:  Spec 01 section 7
- [g] W2.3 G3 D6 storage (FTS recovery, trigram, reopen after I/O error); R38 index done in W2.2
  - red:   a_corrupt_search_index... FAIL (write Err sqlite_267); a_stale_search_index_is_rebuilt_at_the_next_open FAIL (stale flag kept); the_writer_reopens_its_connection... FAIL (next write sqlite_1); search_finds_cjk: word index misses "北京天" (probe: 0 hits) (2026-11-25)
  - green: storage 20/20, workspace 192+ pass; clippy -D warnings clean (also cleared W1/W2 lint debt: pipe_identity SAFETY placement, wallet arg count, assert-empty, test_support format pushes, split resolve_active_tool_catalog and spawn_live_stream)
  - files: storage lib.rs (write_node_change, scan fallback, layered search, rebuild at open, reopen_writer), schema.rs v11 + trigger SQL, protocol keys StorageIoError + StorageSearchIndexCorrupt, l10n en/vi/ar + i18n-gen
  - docs:  Spec 01 sections 3 and 8, Spec 00 section 6
- [g] W2.4 R20 R21 async hygiene
  - red:   a_backup_does_not_wait_for_the_writer FAIL (Timeout: VACUUM INTO queued behind a busy writer) (2026-11-25)
  - green: storage 21/21, core 155+; clippy -D warnings clean
  - files: storage lib.rs backup on its own read-only connection; core off_worker::blocking; agent_tools file tools via blocking pool, spill_off_worker + write_blob_atomically + spill_preview; Cargo.toml explicit await_holding_lock/refcell
  - note:  the run loop's per-step writes stay inline (sub-millisecond once backups leave the writer); R21 non-blocking is covered by the off_worker mechanism test, not a per-tool timing test; spill atomicity test passes before and after (no deterministic partial-read repro)
  - docs:  Spec 11
- [g] W2.5 R1 R8 R12 duplicate execution
  - red:   R1 ids ["call_42","call_42_2"]; R8 Err(sse_buffer_cap) after "hi" shown; R12 no DELETE /v1/files/file_1 (re-proven by reverting the fix: FAIL 5.1 s); framer 16 MiB long line 317 s (2026-11-25)
  - green: workspace 200/200; clippy -D warnings clean; framer 0.68 s
  - found: SseFramer rescanned its whole buffer per chunk (quadratic; a 64 MiB line took 162 s); MockServer reset connections on bodies over its 4 MiB record cap (now drains, records the first 4 MiB)
  - files: wire_stream.rs (raw_tool_call_ids), sse.rs (scanned cursor), providers.rs (cap -> interrupted; cleanup after the stream block), test_support.rs (drain)
  - docs:  Spec 02 sections 1 and 2
- [g] W2.6 U35 P27 U36 U30 drafts
  - red:   draft_persistence (send: draft 'hello' kept; slash: '/plan' kept; P27: null, re-proven by removing the lifecycle flush); Enter in / menu sent "/plan" to the model; inspector_prompt (field '' after switching back during a slow save); inline_edit_keepalive (edit gone once unfocused and scrolled out) (2026-11-25)
  - green: 66 widget tests across 13 files; flutter analyze clean
  - found: FakeEngineGateway deleted drafts on send, unlike the real engine (hid U35); Enter with the / menu open sent the command as a paid message
  - files: folio_composer.dart (text listener saves drafts, Enter picks menu entry, flush on dispose), folio_controller(.dart, _threads.dart) (_pendingDraft, flushPendingDraft replaces unused flushDraftNow, flush on dispose/shutdown), main.dart (flush on inactive/hidden/paused), chat_inspector_drawer.dart (unsaved edits per chat), folio_message_feed.dart (keepalive while editing)
  - docs:  Spec 08 state paragraph, DESIGN composer

## W3 Walkthrough defects
- [g] W3.A A-W 1a 1b 2a-2d 3a 3b S3 U3 U6 U17 U18 U26 U27 U12 input, title, sidebar
  - red:   quill_input (1a no Paste in menu, 2a Enter dropped, U27 field unnamed); title_rename (2b click-away not saved, edit survives chat switch, 2c box 803 px); escape_stop (Esc with text / in search stopped the reply, no Ctrl+.); ime_composing (U18 Enter picked /plan mid-IME, palette ran an entry, U17 sent text never cleared); auto_follow (U12 drag pulled back to 0 px, re-proven by reverting); modal_focus (U26 Tab left the palette) (2026-11-25)
  - green: full flutter test 132/132; flutter analyze clean; i18n-check OK (shortcut.stop_reply en/vi/ar)
  - files: bistre_selection_controls.dart (TextSelectionHandleControls, shared menu, SelectableRegion menu), ink_primitives.dart QuillInput (one-line submit, onTapOutside, semanticsLabel, placeholder excluded), inline_title_editor.dart (new), folio_shell_screen.dart (editor, stop shortcut, ExcludeFocus), folio_controller(_navigation).dart (Esc chain, stop_reply spec), folio_composer.dart (Esc stop, IME guards and retries), command_palette.dart (IME guard), folio_message_feed.dart (welcome desk not selectable, auto-follow), bistre_motion_widgets.dart (modal focus scope)
  - open:  [u] 1b Ctrl+V passes in the test harness; needs a live Windows trace; U3 done in W2.6; kelivo #1542 not present (no onDrag keyboard dismiss in the app)
  - docs:  DESIGN section 7, Spec 08
- [g] W3.S stutter root cause (sidebar reflow, scroll frame timings, merged UI thread)
  - root cause: SidebarSlideReveal changed its width every frame (Align widthFactor), so the whole chat column (header, feed, composer) re-laid out on every animation frame; plus Opacity (saveLayer per frame), unmount when closed (full rebuild on open), and two toggles swapped mid-animation (title jump)
  - red:   sidebar_dock_test: chat widths across a toggle = one per frame (LTR + RTL), sidebar element rebuilt on reopen, settings button gone while open (2026-11-25)
  - green: sidebar_dock_test 4/4; full flutter test 113/113; flutter analyze clean
  - fix:   SidebarDock (CustomMultiChildLayout: main laid out once at its final width, then only positioned; sidebar offstage + TickerMode off + ExcludeFocus/Semantics when closed; 180 ms easeOutCubic animateTo from current value; Reduce motion instant); trailing SidebarSlideReveal mounted while closed, no Opacity; one header toggle, Settings always shown
  - found: AgentToolsSettingsView notified the controller during its first build (refreshWorkspaceHooks with no workspace) -> gallery assertion; now notifies only on change, refresh runs after the first frame
  - open:  [u] scroll stutter not yet measured (needs a Windows profile run); toggle glides with the content instead of a fixed screen slot (deviation from A-W 3b, owner to confirm); trailing docks still resize the chat while they slide
- [g] W3.B A-W 4a-4c Studio, notes removal, grounding
  - red:   studio_header (Studio missing at rest, phone + desktop); grounding_sources (no sources in Studio / Turn details); reply_sources engine test (no API: compile-red) (2026-11-25)
  - green: grounding::tests 5/5 + engine test; workspace 206 Rust; flutter analyze clean
  - verified live (official docs, 2026-11-25): Gemini groundingMetadata chunks (stream accumulates), Gemini Interactions url_citation, OpenAI Responses message annotations url_citation, Anthropic web_search_tool_result + web_search_result_location. [UNVERIFIED]: OpenAI annotation stream event, Anthropic citations_delta payload, Chat Completions nesting
  - files: core grounding.rs (new), engine_grounding.rs (new), engine_story.rs (new; moved inspect_story_prompt body for file-size headroom), wire_stream.rs, engine_runs.rs, engine_client.rs, engine_impl.rs; ffi harness.rs + codegen; Dart engine_models/bistre_engine/controller extras, runs_dock_panel.dart (Sources tab, GroundingSourceRow), chat_overlays.dart (typed sources, regex and ChatNotesModal removed), shell header (Studio always), palette/inspector/navigation (notes removed); l10n chat.notes.* removed, studio.tab.sources + studio.sources.empty added
  - open:  opening a source in the browser needs a new http(s)-only open_web_link on every platform (none exists today); rows offer Copy link; S3 hover hint covered by 3b + guard test hover_hint_test.dart
  - docs:  Spec 00 section 6, Spec 02, Spec 08, DESIGN
- [g] W3.C A-W 5a-5c 6 P7 P8 provider fields, combobox
  - red:   gemini_base_with_version_never_doubles_the_path (compile-red; by reading: preset base .../v1beta + {base}/v1beta/interactions = /v1beta/v1beta); provider_fields (new Gemini provider got .../v1beta; headers/body on the main panel); model_combobox (no list on focus, second filter box); provider_test_connection (no URL in the failure) (2026-11-25)
  - green: Rust 208/208; full flutter test 144/144; i18n-check OK; guard OK
  - files: protocol dialect.rs (new: ALL, default_endpoint_path, models_path, api_root), providers.rs, credentials.rs (resolve_endpoint, ResolvedEndpoint), attachments.rs + voice.rs (api_root), ffi mod.rs (provider_dialect_descriptors, resolve_provider_endpoint) + codegen; Dart provider_presets.dart (no URLs/examples), providers_settings_view.dart, provider_subpages.dart, model_picker_field.dart (combobox), chat_inspector_drawer.dart, controller extras, engine models/gateway/fakes; l10n: advanced page title, 4 format labels, requests_go_to, neutral header/body hints, connection_failed with {url}; settings.model_pick_action removed
  - docs:  Spec 00 section 6, Spec 02, Spec 08, DESIGN
- [g] W3.D A-W 7a-7e S2 OTA manifest v2
  - red:   ota old_or_incomplete_manifests_fail_with_their_own_reason + ota_manifest tests (compile-red: no v2 types; by reading, v1 code failed `ota_sha256_missing` on every real feed); ota_errors_test (compile-red: no lastOtaDiagnostic; composer showed OTA errors) (2026-11-25)
  - green: Rust 212+ (OTA 18/18 with new signed fixtures); flutter 146+; i18n-check OK; CLI smoke: build -> sign -> verify VERIFIED, tampered AppImage -> diag.ota.integrity_failed (asset_mismatch)
  - files: core ota_manifest.rs (new: OtaManifestV2, OtaTarget, Sha256Hex, build_release_manifest, verify_release_dir), ota.rs (v2 check, new fixtures signed with a throwaway key made by a scratch pure-Python Ed25519/minisign signer), examples/ota_manifest.rs (new); protocol keys OtaManifestUnsupported + OtaNoAssetForPlatform; release.yml (Rust toolchain, build + verify via the example, timeout 30); Dart controller (lastOtaDiagnostic/Detail, stage-failure toast with Open Updates, no composer injection), updates view (localized error + Technical details, feed hint), EngravedButton disabled icon tint (S2), x buttons Dismiss/Close/Remove; l10n 9 keys
  - open:  [u] release dry run exercises the new manifest step for real (needs the release environment secrets; at PR time)
  - docs:  Spec 10, SECURITY, DESIGN
- [g] W3.E A-SE R26 context breakdown
  - red:   tool_arguments_and_reasoning_are_counted (8 tokens for ~6k of tool args + thinking); context_breakdown_test + tool_rows_sum (compile-red: no ContextBreakdown) (2026-11-26)
  - green: Rust 215; flutter 148/148; i18n-check OK; guard OK
  - files: core context_breakdown.rs (new), compaction.rs (R26 meta tokens, AUTO_COMPACT_RESERVE_PERCENT), engine_runs.rs (shared load_turn_context, trigger counts tool schemas), agent_tools.rs (schema_tokens), engine_client/impl; ffi context_breakdown (context_usage removed) + codegen; Dart engine models, gateway/mapping, controller (contextBreakdown), context_breakdown_popover.dart (new), context_gauge_ring.dart; fakes share test/support/fake_context.dart; l10n 21 keys added, 7 old chat.context_* removed
  - open:  breakdown cache by (catalog, prompt, leaf, model) not built (counts run per open, off the async workers); phone bottom-sheet form not built (popover on every width); skills index and saved memory rows wait for Phase 3 to inject them; per-model limit override waits for Phase 3
  - docs:  DESIGN section 8, Spec 08, Spec 04
- [u] W3.R D7 Impeller default (Windows + Linux)
  - change: windows/runner/main.cpp default ImpellerSwitch::Enabled (off/false/0 -> Disabled, default -> engine default); linux/runner/my_application.cc fl_dart_project_set_enable_impeller(!BISTRE_IMPELLER=off) (API verified in the local Flutter 3.50.1 engine source, fl_dart_project.h:170)
  - risk:  Spec 11's last Iris Xe run had Skia far faster (raster p95 3.35 ms vs 346 ms; idle 200 vs 271 MB). Not re-measured: needs `just perf` on a Windows release build (end of task) and a Linux host [u]
  - docs:  Spec 08, Spec 11

## W4 Protocol fidelity and harness
- [g] W4.1 R10 P3 R42 P4 P5 terminal frames
  - red:   providers a_plain_json_error_body... (old: retryable eof_before_output), a_reply_cut_by_the_output_limit_reports_length + engine truncated/paused tests (compile-red: no FinishKind / keys), an_http_error_keeps_the_providers_reason (no reason in detail), reply_finish_test (no reason line, no Continue) (2026-11-26)
  - green: Rust 222/222; flutter suite green; i18n-check OK
  - files: core finish.rs (new), wire_stream.rs (finish + error_reason), providers.rs (error frames to retry/fail path, reason on HTTP errors), error_policy.rs (failure_error reason), engine_runs.rs (truncated/refused notices, pause_turn resume via load_turn_context_with), compaction.rs (enforce_role_alternation_with); protocol keys ProviderReplyTruncated/Refused; Dart controller lastDiagnosticReason, composer reason line + Continue; l10n 5 keys
  - open:  P5 NOT changed: the plan says a 413 should fail fast, but AGENTS section 7 requires a one-shot 413 compaction retry; needs the owner's decision (AGENTS: on conflicting sources, ask)
  - docs:  Spec 02
- [g] W4.2 R13 R14 G1 G2 replay
  - red:   compaction an_empty_assistant_turn_is_never_replayed (empty assistant sent); replay_policy reasoning_made_after_the_compaction / a_dangling_tool_call_gets_a_did_not_run_result, error_policy only_an_unsupported_reasoning_error_marks_the_model, gemini_signature_tests (compile-red: no helpers / variant); wire_history replayed_reasoning_items_carry_no_null_fields and providers openai_responses_put_the_system_prompt_first_and_replay_call_status (failed on old output) (2026-11-26)
  - green: Rust 233/233; clippy clean
  - files: core engine_runs.rs (R13 filter, dangling-call validator), replay_policy.rs (answer_dangling_tool_calls, without_null_fields, latest_compaction_ms, made_before_compaction, GeminiTextSignature), error_policy.rs (says_reasoning_unsupported), providers.rs (heal code, developer item), wire_history.rs (per-turn gating, status, null strip, Gemini text signature + first-call rule), wire_stream.rs (Gemini text signature, no borrowed call signature), compaction.rs, gemini_signature_tests.rs (new)
  - live:  OpenAI docs read via web fetch (prompt-caching guide, Responses reference, reasoning and function-calling guides); kelivo master test files read
  - open:  pi #12367 (missing status drops reasoning) [UNVERIFIED]; kelivo raw-part cases (unknown future parts, built-in toolCall parts) have no counterpart (Bistre stores typed parts)
  - docs:  Spec 02 section 3
- [g] W4.3 R7 chaining
  - red:   replay_policy chaining_needs_storing_and_sends_only_the_new_items, providers a_chained_openai_request_does_not_resend_the_system_prompt / a_chained_request_after_a_tool_call_sends_the_result (compile-red: no chain_plan / chain_first_new_index; old code passed the compaction flag as store_requested and resent the full history) (2026-11-26)
  - green: Rust 236/236; clippy clean
  - files: core replay_policy.rs (ChainPlan, chain_plan), engine_runs.rs (one store decision, chain plan), providers.rs (StreamRequestOptions store + chain_first_new_index, chain_skip, no developer item when chained), wire_history.rs + attachments.rs (chain_skip)
  - also:  the "store on the provider" setting never reached the request body (store came only from the server-state cache); the run's decision now drives both
  - docs:  Spec 02 section 3
- [g] W4.4 G4 R32 G5 retry
  - red:   error_policy retry_hint_priority_and_formats (zero ms hint won; 1 day clamped to 300 s), tests.rs backoff asserts (compile-red: no seed; hint past budget retried), provider_backoff every_run_sees_the_longest_wait (new module), bistre-crypto a_crashing_child_dies_instead_of_showing_a_fault_dialog (flags were 0x2000 only) (2026-11-26)
  - green: Rust 239/239; clippy clean; providers a_not_found_endpoint_is_never_retried pins existing behaviour
  - files: core error_policy.rs (G4, no upper clamp), agent.rs (give up past budget, per-run jitter, jitter_seed), engine_runs.rs (wall-clock retry streak, shared provider backoff), provider_backoff.rs (new), lib.rs; crypto containment.rs (DIE_ON_UNHANDLED_EXCEPTION)
  - live:  JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION checked in the installed windows-sys 0.61 source
  - open:  "errors classified by kind" already holds (FailureKind); the two-concurrent-runs engine test for the shared backoff lands with W5's concurrent-runs test [u until then]
  - docs:  Spec 02 section 6, AGENTS section 7, SECURITY, ADR-0010
- [g] W4.5 R15 R16 R17 R43 MCP
  - red:   mcp_stdio_tests (every call failed mcp_stdio_flush: the child was killed at spawn), mcp an_http_json_rpc_error_is_an_error_not_a_result (proved by reverting the HTTP check: FAIL) (2026-11-26)
  - green: Rust 245/245; clippy clean
  - files: core mcp_stdio.rs (session pool, bounded reads, server requests, close_stdio_session / close_all_stdio_sessions, child held), mcp_stdio_tests.rs (new), mcp.rs (json_rpc_result on HTTP), engine_impl.rs (close on server-list save and shutdown)
  - live:  MCP 2025-11-25 (ping, roots, basic, transports, lifecycle) and 2026-07-28 (basic, roots, stdio) read via web fetch
  - also:  latent bug fixed: stdio MCP servers were killed right after spawn (kill_on_drop + dropped Child)
  - open:  MCP 2026-07-28 removes ping and server-initiated requests; the replies above serve 2025-11-25 servers. A live third-party stdio server run [u]
  - docs:  Spec 04, ADR-0018
- [g] W4.6 R11 R23 R24 R25 attachments
  - red:   attachment_send_tests (compile-red: no byte sniffing / unsent_attachment_names / gemini_needs_files_api / primary_only; old code typed unknown files text/plain, dropped missing images and PDFs, uploaded Office files to Gemini, rotated keys away from the uploading key) (2026-11-26)
  - green: Rust 249/249; clippy clean; i18n-check OK
  - files: core mime_sniff.rs (new), attachments.rs (infer_mime_type takes the head, note, unsent names, gemini_needs_files_api), wire_history.rs (note in every dialect, Office first for Gemini), providers.rs (pinned key, AttachmentNotSent notices), credentials.rs (primary_only); protocol AttachmentNotSent; l10n 1 key
  - docs:  Spec 00
- [g] W4.7 R18 steps + broker read-only mode
  - red:   egress a_run_stopped_by_the_step_limit_says_so (compile-red: no key; old loop broke silently), approval_flow plan_mode_refuses_every_write_even_when_the_model_calls_one (FAIL: the edit ran with Allow) (2026-11-26)
  - green: Rust 251/251; clippy clean; i18n-check OK
  - files: core engine_runs.rs (step-limit notices), agent_tools.rs (read_only gate), egress_tests.rs (anthropic helpers), approval_flow_tests.rs; protocol RunStepLimitReached; l10n 1 key
  - note:  enforced at the single execution gate before any approval or permit (the broker is process-wide, not per chat)
  - docs:  Spec 04 section 2
- [g] W4.8 volatile facts to registry/descriptors
  - red:   registry output_limits_come_from_the_registry, engine_story the_story_budget_follows_the_models_context_window (compile-red: no field / no builder) (2026-11-26)
  - green: Rust 253/253; clippy clean
  - files: core registry.rs (max_output_tokens, cache format 5), lib.rs (anthropic_output_limit), engine_story.rs (story_prompt_report, STORY_FALLBACK_CONTEXT_TOKENS), engine_runs.rs + context_breakdown.rs (context window into the turn context; thread_model_id), providers.rs + attachments.rs (dialect constants); protocol dialect.rs (Anthropic constants, pub mod)
  - live:  LiteLLM, models.dev, OpenRouter, Vercel catalogs read 2026-11-26 (OpenRouter's response lacked top_provider and Vercel's max_tokens is ambiguous: both left out)
  - open:  per-model effort vocabulary (thinkingLevelMap) has no published source; the heal ladder stays the fallback. No host-substring quirks were found.
  - docs:  Spec 02
- [g] W4.9 prompt-surface golden
  - red:   prompt_surface_prefix_is_pinned_and_stable_per_dialect (failed: no golden; stability asserts held), anthropic_cache_breakpoints_are_placed_on_the_wire_body pins existing placement (2026-11-26)
  - green: Rust 255/255; clippy clean
  - files: core prompt_surface_tests.rs (new), fixtures/prompt_surface/*.json (4 goldens, reviewed)
  - docs:  Spec 02 section 3

## W5 Run state and live UI
- [g] W5.1 U11 P12 per-thread run state
  - red:   test/run_state_test.dart (compile-red: no ThreadRunState / threadRunState / sidebar keys / seedAgentRun) (2026-11-26)
  - green: flutter 155/155 then run_state 6/6; analyze clean; i18n-check OK
  - files: app folio_controller_runs.dart (new), folio_controller.dart (live-run map), _threads/_studio (per-chat rows), live_turn_notifier.dart (seed), tool_timeline_view.dart (copyWithOutput), folio_sidebar.dart (_RunStateMark); l10n 4 keys
  - open:  done-unread is session-only (no persisted last_viewed_rev / history_rev); gallery review at the end
  - docs:  Spec 08 section 3
- [g] W5.2 U4 U10 U9 P19 lifecycle
  - red:   run_state_test U4/U9/U10/P19 cases (compile-red), providers a_stream_stalled_across_a_resume_ends_when_the_app_comes_back (compile-red: no note_app_resumed; old loop waited 90 s) (2026-11-26)
  - green: Rust 256/256; flutter run_state 6/6
  - files: core providers.rs (RESUME_EPOCH, stalled_across_resume), agent.rs (AppResumed), protocol SystemPowerEvent::AppResumed, ffi api/mod.rs ("app_resumed"); app main.dart (resumed), folio_controller_runs.dart (onAppResumed, _reconcileLiveRuns)
  - open:  U10 event seq + replay cursor not built (lag repair reconciles with the run list instead)
  - docs:  Spec 02 section 6, Spec 08 section 3
- [g] W5.3 P20 U37 P21 P22 P23 P1 feedback
  - red:   egress shutdown_wakes_a_run_waiting_in_backoff attempt assert (FAIL before), retry_notice_test (compile-red, then countdown frozen under fake time), process_util output_arrives_while_the_command_still_runs + shell_progress tests (compile-red), auto_follow P22 (FAIL: 92 px left behind), reveal_message_test and sent_attachments_test (compile-red) (2026-11-26)
  - green: Rust 258/258; flutter 160/160; analyze, guard, i18n-check OK
  - files: core engine_runs.rs (attempt=), process_util.rs (run_bounded_with_progress), tools.rs (tool_shell_with_progress), shell_progress.rs (new), agent_tools.rs (dispatch_with_progress), tool_spill.rs (new, split out); ffi api/mod.rs + dto_mapping.rs (FfiNodeAttachment) + codegen; app folio_composer.dart (_BackoffNotice), folio_message_feed.dart (follow size, reveal), folio_controller_runs.dart (revealNode), folio_sidebar.dart + chat_overlays.dart (pinned reveal, Show), engine_models + mapping (EngineNodeAttachment); l10n 2 keys
  - open:  "a of b": tries are bounded by the retry time budget, not a count, so the notice names the try only; gallery review at the end
  - docs:  Spec 08 section 3, Spec 04 section 2, Spec 00

## W6 Performance and memory
- [ ] W6.1 R33-R37 R39-R41 Rust
  - done:  R33/R34 (frame ticker; red: the_last_text_before_a_pause_is_shown_at_once showed nothing), R41 (red: cleaning_keeps_a_staged_update) (2026-11-26)
  - done:  R35 (parse once; refactor covered by existing parser tests, no new red test), R36 (red: a_long_text_is_counted_once compile), R37 (red: the_branch_walk_returns_only_the_leafs_ancestry compile); Rust 262/262
  - done:  R40 (red: a_stalled_frame_times_out compile; daemon request frames time out at 10 s, replies at 120 s, buffers grow with data)
  - done:  R39 slim DTO (red: the_app_gets_slim_node_metadata compile) + usageMeta parsed once
  - open:  windowed loads / history_rev (P26)
- [ ] W6.2 U13-U15 U19 U22 U23 P24 P26 Flutter
  - done:  U19 (red: compile, no loadWorkspaceEntries), U22 (red: 11 saves per resize), U23 (red: provider was FileImage), P24 (red: compile, no modelPickerMatches) (2026-11-26); flutter 164/164
  - done:  U13 (red: markdown_cache_test compile), U14 (red: tool_timeline_fold_test compile), U15 (red: branch_index_test compile); flutter 168/168
  - open:  P26 (with R39: slim node DTO, windowed loads, history_rev)
- [ ] W6.3 probes (500-turn RSS, idle CPU, streaming p99)
  - done:  test/long_session_probe_test.dart: 500 tool turns keep rows <= 200, outputs <= 16 KiB, parse cache <= 4 Mi chars; after the run no scheduled frame or animation (idle) (2026-11-26)
  - open:  OS-level RSS of the 500-turn session and streaming p99 need just perf --strict on this laptop (run with the final gates) [u until then]

## W7 Background engine and Android service
- [ ] W7.1 daemon launch/connect, power, AutoResume, cron, unattended, events, U34
  - done:  cron (red: all_five_cron_fields_are_honoured compile; old evaluator ignored dom/month/dow; bad schedules became hourly), due jobs start real runs (a_due_scheduled_job_starts_a_run_with_its_prompt), daemon housekeeping never spins or wakes per delta (housekeeping_tests) (2026-11-26); Rust 269/269
  - open:  app launches/connects the daemon (LocalIpcEngine), real power backends to the UI, AutoResume restart + interrupted-run notice, unattended policy in the broker, event replay after reconnect, U34 keep-alive; live daemon runs on Windows/Linux/Android [u]
- [u] W7.2 P13-P16 Android FGS
  - red:   android_service_plan_test (compile-red: no androidServicePlan; the controller stopped the service on any RunFinished) (2026-11-26)
  - green: flutter 170/170; analyze clean
  - files: app folio_controller_runs.dart (AndroidServicePlan, _syncAndroidService), folio_controller.dart, power_guard_host.dart (holdLocks); android BistreAgentService.kt (START_NOT_STICKY, holdLocks, onTaskRemoved), MainActivity.kt
  - open:  Kotlin compiles only in the Android build (CI on the PR); device behaviour [u]
  - docs:  ADR-0012
- [u] W7.3 U40 Linux runner
  - done:  window title "Bistre"; opens on the paper colour (#F6EFE2, or #19120D when GTK prefers dark) instead of black (2026-11-26)
  - open:  title/theme/bounds method channel on Linux; compile and look checked on a Linux host only [u]

## W8 Dead settings, strings, accessibility
- [ ] W8.1 Appendix Phase 3 table
- [ ] W8.2 U29 U41 U20 U21 U24 U25 U28 U31-U33 U38 U39 U42
- [ ] W8.3 inspector, model resolution order, catalog orphans, registry cache
  - done:  price refresh replaces known prices (red: a_refresh_replaces_known_prices compile; Spec 03 TTL now 24 h as in code), diag.tool.path_denied (red: a_skill_outside_the_workspace_is_a_path_denial compile), Gemini dialect id google_gemini everywhere in the app (red: dialect_ids_test compile; storage badge never showed for Gemini) (2026-11-26)
  - done:  model order thread -> assistant -> Default models -> last pick -> provider default (owner decision 2026-11-26; red: the_default_model_setting_wins_over_the_last_pick FAIL, picker_sets_chat_model_test compile); picker sets the open chat's model
  - done:  49 orphan keys removed from en/vi/ar (8 kept for W8.1 features); retry notice reason in words (raw key leak)
  - done:  settings search finds every page (Default models and World book were missing; Providers, Appearance, Memory, Shortcuts missed label groups); settings_search_map_test
  - open:  inspector shows the real request and blocks invalid edits

## W9 CI, packaging, supply chain
- [ ] W9.1 C2-C9
- [ ] W9.2 C13-C30 (C23 without code signing)
- [ ] W9.3 Slice D release steps, renderer assertion, dependency budget

## W10 Computer use and Phone use
- [ ] W10.1 Rust tool + approvals
- [ ] W10.2 Windows host bridge
- [ ] W10.3 Linux host bridge `[u]`
- [ ] W10.4 Android AccessibilityService `[u]`

## W11 Parity and writing studio
- [ ] W11.1 Appendix Phase 5 items
- [ ] W11.2 Kelivo quote, image retention, viewer zoom (P2)
- [ ] W11.3 Android share intake (P17), crash recorder (P18, D9)
- [ ] W11.4 provider share code, SVG preview (P25), Errata Story Studio patterns, subagent cap

## Final
- [ ] just check-all
- [ ] just ui-gallery review (phone, desktop, 200%, RTL)
- [ ] commit layers, push branch, CI dry runs, open PR

## Open [UNVERIFIED]
- Vercel AI Gateway cache-write field names (assumed same as OpenRouter).
- Spec 03 registry TTL reconciled to 24 h (W8.3, 2026-11-26).
