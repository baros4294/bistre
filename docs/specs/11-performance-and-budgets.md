# Spec 11 — Performance, Memory, Battery & Binary Budgets

## 1. Measurable Day-1 Invariants & CI Guardrails
| Metric | Budget | Hard Fail | Enforcement |
|---|---|---|---|
| Cold Start to First Paint (Windows / Linux) | `<= 400 ms` | `> 600 ms` | `[BISTRE_PERF] first_frame_ms` post-frame probe |
| Cold Start to First Paint (Android arm64-v8a) | `<= 650 ms` | `> 900 ms` | `adb shell am start-activity -W` (`TotalTime`) |
| Idle RAM — Desktop Daemon Only (Window Closed) | `<= 30 MB` RSS | `> 45 MB` | `bistre-daemon --health-check` RSS check |
| Idle RAM — Active Flutter GUI + Core | `<= 120 MB` RSS (Desktop) / `<= 110 MB` PSS (Android) | `> 160 MB` | `ProcessInfo.currentRss` probe |
| Frame Build+Raster @ 120 tok/s Streaming | `p99 <= 12 ms` (60Hz) / `<= 7.5 ms` (120Hz) | `> 16 ms` | Flutter `TimelineSummary` benchmark |
| Idle Background CPU & Wakeups | `0.0%` CPU, `0` wakeups/sec | Any polling timer | Event-driven tokio/OS watchers only |
| Local SQLite FTS5 Search (`10k` nodes) | `p95 <= 15 ms` | `> 50 ms` | Rust storage latency test |
| Stripped `libbistre_ffi.so` (`arm64-v8a`) | `<= 8 MB` Wave 1 (`~2.7 MB` Slice 0 measured) | `> 10 MB` | CI `android-arm64-16kb` `stat` gate |
| Android `arm64-v8a` Release APK | `<= 28 MB` Wave 1 (`~19.5 MB` Slice 0 measured) | `> 32 MB` | CI `android-arm64-16kb` `stat` gate |

## 2. Structural Efficiency Techniques
- **FFI Delta Coalescing**: `crates/bistre-ffi` batches high-frequency streaming deltas on a `16ms` cadence over bounded channels (`cap=256`), preventing Dart isolate thrashing. The core already coalesces each run's text into at most one `DeltaBatch` per `16 ms` frame before the `broadcast(256)` bus (`engine_runs::DELTA_FRAME`), so a fast stream cannot overrun it; if a subscriber still lags, FFI sends `events_lagged` and the app reloads state from storage instead of showing an error. Unknown event kinds from a newer core are ignored.
- **Streaming checkpoints**: the partial reply is checkpointed append-only (`append_agent_run_partial_text`) at most every `250 ms` and only after `4 KiB` of new text, plus once at the end (previously the whole buffer was rewritten every 24 chunks, quadratic in reply length).
- **Zero-Fork Native Tools**: File read, ripgrep search, glob, hash-anchored edit, and diff execute in-process inside Rust with zero subprocess spawn overhead.
- **Asset & Binary Hygiene**: Bundled static weights only (`Inter`, `JetBrainsMono`, `NotoSansMath`), pre-compiled `.vec` vector icons (`vector_graphics`), Rust `lto = "thin"`, `codegen-units = 1`, `panic = "abort"`, `strip = "symbols"`, `opt-level = "z"` for Android, and `arm64-v8a` ABI split with `0x4000` (16KB) ELF alignment.
- **Zero Idle FGS & Daemon Drain**: Android `BistreAgentService` (`FOREGROUND_SERVICE_SPECIAL_USE` / `MICROPHONE`) and desktop `bistre-daemon` run strictly while `active_runs > 0` or a scheduled job is active and stop cleanly when idle (`ADR-0012`, `ADR-0013`).

## 3. Reference Hardware & Low-Memory Mode
Every budget above is measured on, and must hold for, these documented reference devices:

| Class | Device Profile | Role |
|---|---|---|
| Low-end Windows | `2 cores, 4 GB RAM` | Minimum supported desktop |
| Low-end Android | `API 29+ (minSdk), 2 cores, 2 GB RAM` | Minimum supported phone (audited `API 26` peer baseline is below Bistre's `minSdk = 29`) |
| Everyday development laptop | `Intel i5-1135G7, 7.7 GB RAM`, Windows 11 | Build, test, and storage-budget reference |
| Everyday phone | Current-generation Android phone | Manual on-device checks |

- **Low-memory mode**: When host RAM is `< 4 GB` (desktop) or Android `ActivityManager.isLowRamDevice()` is true, Bistre caps streaming redraw at `30 fps`, skips overlay drop shadows, and uses smaller image/attachment decode caches (`docs/design/DESIGN.md` §7).
- **Bundled fonts**: All bundled OFL font files together stay `<= 2.0 MB` (OFL-compliant subsetting that preserves full Latin, Vietnamese, Arabic, prose, code, and math glyph coverage); `NotoSansMath` registers lazily on the first rendered math block.
- **SQLite WAL**: `PRAGMA journal_size_limit = 8388608` (8 MiB) + `wal_autocheckpoint = 1000`; tool outputs `> 64 KiB` spill to a blob column; `reclaim_storage()` runs `wal_checkpoint(TRUNCATE)` + `PRAGMA optimize` (Spec 01).

## 4. Workspace Build & Storage QC Budgets
Local build caches are budgeted like runtime memory (`ADR-0016`), so a 7.7 GB laptop never runs out of disk:

| Bucket | Budget | Enforcement |
|---|---|---|
| `target/` (all Cargo profiles) | `<= 5.0 GiB` | `just disk`, `just prune`, auto-prune after `locked` heavy runs |
| `apps/bistre_app/build/` | `<= 1.0 GiB` | `just disk` |
| `apps/bistre_app/.dart_tool/` | `<= 512 MiB` | `just disk` |
| `.bistre-local/` (ledger, lock, logs) | `<= 128 MiB` | `just disk`, `just prune` |
| Single verification `.log` | `<= 2.0 MiB` | `just prune` |

- **Cargo profiles** (`Cargo.toml`): `[profile.dev] debug = "line-tables-only"` and `[profile.dev.package."*"] opt-level = 2, debug = false` (backtraces keep `file:line` for Bistre crates; stepping into dependency locals in a native debugger is intentionally unavailable). `[profile.release-android]` adds `opt-level = "z"`, `lto = "fat"`, `codegen-units = 1`, `panic = "abort"`, `strip = "symbols"`.
- **Cargo config** (`.cargo/config.toml`): `[build] jobs = 4`; `[registry] global-min-publish-age = "3 days"`; Android `aarch64` rustflags `force-unwind-tables=no`, `--gc-sections`, `--icf=safe`, `-z max-page-size=16384` (mirrored by `apps/bistre_app/hook/build.dart`, which also passes SQLite `-Oz -fno-unwind-tables -fno-asynchronous-unwind-tables -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_DEPRECATED`).
- **Surgical pruner** (`tools/bistre_guard/lib/storage_qc.dart`, never `cargo clean`): keeps the newest incremental session per crate stem; removes an orphaned flat `deps/` once the nested `build/<crate>/<16hex>/out/` layout is active (`>= 5` crates and `deps/` older than `build/`); keeps the newest `2` (debug) / `1` (release, release-android) nested build units per fingerprint unit kind while skipping any unit holding a shared library (rust-analyzer-mapped proc-macro `.dll`); keeps the newest hashed flat `deps/` file per `<stem>\0<ext>`; deletes verification logs `> 2 MiB`.
- **Single-run lock & ledger** (`tools/bistre_guard/lib/ledger.dart`): heavy recipes run through `bistre_guard locked …` holding `.bistre-local/verification/run.lock`; `just check-all` records an FNV-1a 64-bit file ledger so `just status` / `just affected` report and run only the checks touched files need (`docs`, `rust`, `dart`, `android`, `l10n`, `ci`).

## 5. Repeatable Performance Harness (`just perf`)
- **Desktop** (`tools/bistre_guard/lib/perf_runner.dart`): `bistre-daemon --seed-synthetic 300 --data-dir <scratch>` seeds **300 synthetic chats in a scratch temp directory** (never user data); the release app is launched three times with `BISTRE_DATA_DIR=<scratch>` and `BISTRE_PERF_PROBE=<file>`, which makes `apps/bistre_app/lib/main.dart` append `first_frame_ms`, `chat_ready_ms`, `chat_count`, and (10 s after the chats load) `idle_rss_bytes`. Medians of three runs are compared with the budgets above. Requires one `cargo build --release -p bistre-daemon` and `flutter build <windows|linux> --release`; missing binaries are reported as `SKIP`.
- **Streaming** (`apps/bistre_app/test/perf/streaming_frame_probe_test.dart`): streams an **~87 KB code fence** in 16 ms delta batches and reports UI-thread build + layout + paint + semantics p50/p95, once with semantics off (a device without assistive technology) and once with semantics on (screen reader active). Widget-test frames run in the debug JIT and exclude GPU raster, so the probe tracks regressions; it is not a release device frame time. Recorded runs (2026-11-23, debug test VM, 1320×820): before chunked fences p50 `53.23 ms` / p95 `114.33 ms`; after chunked fences + the open-fence parse memo (Spec 08) p50 `7.11 ms` / p95 `10.54 ms`, screen reader p50 `8.01 ms` / p95 `11.29 ms` (probe run alone). Inside `just check-all`, where Flutter test files run in parallel on the same CPU, the same probe read p50 `13.06 ms` / p95 `19.79 ms` (screen reader `8.96` / `16.32 ms`), so compare probe numbers only between runs made the same way (`just perf` runs it alone). Follow-up (2026-11-23): the feed's `LayoutBuilder` now gets tight constraints (`StackFit.expand`), which makes it a relayout boundary, so a delta no longer re-lays out the shell's `LayoutBuilder`s (21 → 2 shell `LayoutBuilder` layouts per 20 deltas; `apps/bistre_app/test/anti_pattern_regression_test.dart` fails without it). Probe runs alone stayed at p50 `6.95–7.23 ms` / p95 `10.54–11.28 ms`. Timeline profiling shows the remainder is spread over many cheap per-frame calls (about 30 early-return `layout()` calls on unchanged code chunks plus mouse-region, semantics and padding wrappers along the streaming card's ancestor chain), each carrying debug-mode assertion overhead. Repaint boundaries around the static streaming and code-card headers were tried and removed (no measurable gain). The `7.5 ms` 120 Hz budget therefore remains unconfirmed until a profile build runs on a device. That meets the `12 ms` 60 Hz budget but not the `7.5 ms` 120 Hz budget in the debug VM; a two-character delta alone costs ~6–8 ms there (layout + paint of the streaming item's ancestor chain and debug asserts), so the 120 Hz budget must be confirmed with a profile build on a device (`flutter drive --profile`), which needs the Visual Studio C++ workload (Windows) or a connected Android device. `just perf` reports both budget lines.
- **Android** (`just perf --android`): `adb shell am start -W -S` (`TotalTime`) and `dumpsys meminfo` `TOTAL PSS` after 10 s on an installed APK.
- `just perf` exits non-zero only on a hard-fail budget; `OVER` lines are reported without failing.
- Never loosen a budget to make a failing measurement pass; budgets change only with explicit maintainer agreement and recorded evidence.

## 6. CI Wall-Clock & Cache Budgets
- `Swatinem/rust-cache` runs with `shared-key`, `save-if: ${{ github.ref == 'refs/heads/main' }}`, and `cache-bin: false` (PRs restore but never write cache; binaries are never cached).
- A path-based `plan` job lets docs-only PRs skip Rust, Flutter desktop, and Android builds while `security-and-hygiene` and `repo-guard-and-docs` always run; any `.github/` change runs everything.
- Dependency downloads (`flutter pub get`, `sdkmanager`, tool archives) run through `.github/scripts/with-download-retry.sh` (transport errors only, `10/20/30 s` backoff, never retries compile/test/checksum failures).
- Superseded PR runs cancel via `concurrency`; `main` runs never cancel.

## 7. Fonts & Low-Memory Probes (Measured)
- Bundled fonts: `3.22 MB -> 1.58 MB` after OFL subsetting (Inter 4 x ~200 KB, JetBrains Mono 2 x ~133 KB, Noto Sans Math ~506 KB); `NotoSansMath` is no longer a pubspec font family — `MathFontGate` registers it on the first math block.
- Low-memory detection runs after startup without blocking `bootstrap`; unknown memory is treated as normal.
