# Bistre execution ledger

States: `[ ]` open, `[r]` red test recorded, `[g]` green, `[v]` verified (gates + docs), `[b]` blocked (reason), `[u]` UNVERIFIED (no device/host).
Rules: re-read this file at session start and after every compaction. It holds open work only: IDs, states and what is left. Finished items are removed.

## Current

Wave: next release after v0.2.2   Next action: work through the gaps below, one tested slice per item.

Scope (owner): the next release completes everything `docs/` describes, not only the items below. That is every Spec 00 section 6 row that is not Implemented (Partial, Built not wired, Planned), every `Open:` and `[UNVERIFIED]` note in `docs/specs/` and `docs/adr/` (for example ADR-0019 Not Built), and the design gaps in `docs/design/design.md`. Each one becomes a test and code, or an owner decision when it cannot be built (a live device, a paid service); the row or note changes in the same commit.

- [ ] Windows code signing through SignPath Foundation's free open-source program: owner applies; then a signing step in `release.yml`, Spec 10, and the README SmartScreen note
- [ ] Auto-tag: a workflow tags `v<version>` when a merge to `main` raises the version, then starts the release
- [ ] `release.yml` checks that CI passed on the tagged commit (the push to `main`) instead of running the CI gates again, then builds, packages, and signs from that commit; Spec 10 and CONTRIBUTING

### Gaps `docs/` records (build each with a test; change the doc line in the same commit)
- [ ] G4 In-app audio and video playback beyond WAV (ADR-0019 Not Built, Spec 00 media row)
- [ ] G5 Linux drag and drop; pasted files and pictures on Linux and Android; touch toolbar Paste for files (Spec 08)
- [ ] G10 Android full-duplex voice: `microphone` service type, Oboe, AEC, VAD, BLE Audio routing (Spec 05, ADR-0012)
- [ ] G11 Remote Bridge over TLS 1.3 mTLS with QR pairing (Spec 07, Spec 00 Planned)
- [ ] G12 Video dubbing (Spec 00 roadmap)
- [ ] G13 Byte-for-byte reproducible release check (Spec 10)

## Decisions (owner)

- Approvals: "Approve for this chat" covers the exact command for the whole chat (tool-wide grants only for Tier-0 reads); an approval waits with no time limit, releases keep-awake, and shows a badge.
- Esc stops a run only from a focused, empty, non-composing composer with no overlay, beside the Stop button and its shortcut.
- Signing: Windows ships unsigned (SmartScreen documented) until SignPath accepts the project. Android uses the owner's release keystore through the `release` environment secrets `ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`; pinned cert SHA-256 `AF:EC:66:EA:61:57:A7:62:F4:F9:DE:7D:BB:78:B4:66:A9:AD:3B:A4:C7:0E:7C:95:C5:C8:70:F9:57:2E:04:BC`.
- Renderer: Impeller by default on Windows and Linux, `BISTRE_IMPELLER=off` falls back to Skia; if Impeller breaks a budget, keep it and report.
- Linux packages build in an older container (glibc 2.31).
- Gates: `just check-all` and `just ui-gallery` run once at the end (weak laptop); per slice `cargo check -p`, targeted tests, `just codegen-frb` after FFI changes.
- Git: commit, push, PR, merge, tag, and release only when the owner asks; a release PR may auto-merge on `ci-gate`. A failed release that published nothing ships as the next patch (`just bump patch`, delete the unpublished tag).
- No Linux host or Android device: those live checks are `[u]`.

## Open

### Blocked
- [b] W0.3b C10 vendored Noto Sans Arabic subset (needs owner OK to download the font)

### Needs a live run, a device, or CI
- [u] W1.6 daemon pipe ACL: the refusal path (pipe served by a second Windows account) needs a second account
- [u] W3.A 1b Ctrl+V passes in the test harness; needs a live Windows trace
- [u] W3.S scroll stutter not yet measured (needs a Windows profile run)
- [u] W3.D the release dry run exercises the new OTA manifest step for real (needs the release environment secrets; at PR time)
- [u] W4.5 MCP 2026-07-28 removes ping and server-initiated requests; the replies serve 2025-11-25 servers. A live third-party stdio server run
- [u] MCP `subscriptions/listen` and `cacheScope` against a real `2026-07-28` server (mock streams and lists only)
- [u] W6.3 OS-level RSS of the 500-turn session and streaming p99 need `just perf --strict` on this laptop (run with the final gates)
- [u] W7.1 daemon: live Linux run (socket, Secret Service key in the daemon); a real reply surviving a window close needs a provider key (owner check)
- [u] W7.2 P13-P16 Android FGS: Kotlin compiles only in the Android build (CI on the PR); device behaviour
- [u] W7.3 U40 Linux runner: title/theme/bounds method channel on Linux; compile and look checked on a Linux host only
- [u] W8.2 live Linux run of the core folder picker, notifications and open-folder helpers
- [u] W9.1 C7 removing `--rss-report-only` on a real GPU
- [u] W10.3 Linux host bridge (`agent_tools_settings_view.dart` hides Computer use on Wayland when `WAYLAND_DISPLAY` is set; XTest X11 bridge `[u]`: no Linux host)
- [u] W10.4 Android AccessibilityService (`BistrePhoneUseService.kt`, `res/xml/accessibility_service_config.xml`, `AndroidManifest.xml`, `MainActivity.kt` `bistre/phone_use` channel) + Android Phone use naming in `en`/`vi`/`ar` (`settings.agent.phone_use`, `settings.agent.phone_use_hint`); Dart `computer_use_wiring_test` GREEN; Kotlin compile & live device test `[u]`
- [u] W11.3 Android `ACTION_SEND` `text/plain` share intake on a device
- [u] Windows live behaviour (links in CI): Computer use bridge, file dialogs, SAPI read aloud and dictation, waveOut, the quick entry shortcut pressed from another app
- [u] Linux XTest live; the `.deb` start under `xvfb` with the GL libraries declared (v0.2.2 release run)
- [u] Media (ADR-0019) live runs: an OpenRouter image, video, and speech model; a ModelArk Seedream and Seedance model; a Gemini image and Omni video model; a gpt-audio reply; a Nano Banana multi-turn edit with thinking on; unverified shapes: OpenRouter image `input_references` and chat `image_config`, OpenRouter `pcm` sample rate, Gemini Interactions media deltas and default image output, `generateContent` `imageConfig`, Gemini video format fields, Gemini 3 signature checks on carried and replayed pictures; provider tools on Gemini and Anthropic (a link read, a code run, a Gemini 2.5 model rejecting them)
- [u] App icon: the Android adaptive launcher icon (transparent background layer) and the Windows taskbar icon on a device; the notification small icon still points at the colour launcher icon, which Android draws as a silhouette (needs a one-colour icon)
- [u] MCP 2026-07-28 era probe, `_meta`, `notifications/cancelled`, and graceful stdio close are tested against mock servers only; run one real modern and one real legacy server (stdio and HTTP)
- [u] OpenRouter (2026-11-27 docs): a live keyed run; whether a signature arrives in one fragment or several; whether a provider remaps tool ids that `reasoning_details[].id` links to (Bistre keeps unique valid ids as stored); `/models/user` with a key

### Parchment parity (reference repo `C:\baros4294\parchment`; port its tests with each behaviour)
- [u] T2 a live GitHub skill install (`archive/<ref>.zip` checked against built links only)
- [u] T4 Android paste and drop (`SharedFiles.kt`, decor-view drop listener) and Linux paste (`wl-paste`/`xclip`) and drop (GTK runner): compile in CI, live on a device or host
- [u] T4 Windows drop and clipboard files and pictures (`host_drop.cpp`) live on a desktop
- [u] Video job resume (Try again after a stop or restart) and Gemini picture replay with signatures: mocks only; Google's live docs describe no signature on picture parts
- [u] File viewer: Android Open (chooser) and Copy picture through the `FileProvider`, Linux GTK save and open dialogs and picture clipboard (`my_application.cc`) compile in CI and run on a device or host; Windows `CF_DIBV5` copy compiled with `cl.exe /W4`, live paste into another app
- [u] Paid provider tools against live Anthropic and OpenAI keys (request and count shapes from the docs and mocks only); OpenAI code interpreter needs a catalog `code_interpreter_cost_per_session`, absent from LiteLLM entries now, so it stays unsent until one is listed
- [u] T5 erase at next start on Android: where the vault key sits relative to the data folder
