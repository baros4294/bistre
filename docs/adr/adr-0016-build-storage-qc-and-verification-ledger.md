# ADR-0016: Build & Storage QC Control, Single-Run Lock & Verification Ledger

- Status: Accepted
- Deciders: Bistre Principal Architecture

## Context
- Unbounded Cargo dev builds easily accumulate `10+ GiB` in `target/` from full DWARF/PDB debuginfo across transitive dependencies, accumulated incremental sessions, and superseded nested `build/<crate>/<16hex>/` units.
- `cargo clean` fixes disk usage but forces expensive cold rebuilds and peak linker RAM on every cycle.
- Concurrent heavy runs (two `cargo nextest` / `flutter test` invocations) thrash the pagefile and corrupt timing measurements.
- `just check-all` re-runs every stack even for docs-only edits.
- Verified against the installed Rust 1.100.0 Cargo Book (`share/doc/rust/html/cargo/reference/lints.html`, `config.html`): `[lints.cargo]` names `unused_dependencies`, `unused_workspace_dependencies`, `unused_workspace_package_fields`, `missing_lints_inheritance`, `redundant_homepage`, and `registry.global-min-publish-age`.

## Decision
1. Profile containment (`Cargo.toml`): `[profile.dev] debug = "line-tables-only"`, `[profile.dev.package."*"] opt-level = 2, debug = false`, and a size-first `[profile.release-android]` (`opt-level = "z"`, `lto = "fat"`, `codegen-units = 1`, `panic = "abort"`, `strip = "symbols"`); Cargo-native manifest hygiene via `[workspace.lints.cargo]` at `deny`.
2. Config containment (`.cargo/config.toml`): `[build] jobs = 4`, `[registry] global-min-publish-age = "3 days"`, Android `force-unwind-tables=no` + `--gc-sections` + `--icf=safe` + `-z max-page-size=16384` (mirrored by `apps/bistre_app/hook/build.dart` together with SQLite size flags).
3. Budgets & surgical pruning (`tools/bistre_guard/lib/storage_qc.dart`): `target/ <= 4.0 GiB`, `apps/bistre_app/build/ <= 1.0 GiB`, `apps/bistre_app/.dart_tool/ <= 512 MiB`, `.bistre-local/ <= 128 MiB`, logs ≤ 2 MiB; `just disk` reports, `just prune` keeps only the reused caches (`target/debug`, `target/tmp`, `target/aarch64-linux-android`), deletes the other `target/` folders and a stray root `build/`, and removes superseded units inside the kept caches (never `cargo clean`), skipping any unit that holds a shared library so rust-analyzer-mapped proc-macro DLLs are never touched.
4. Single-run lock (`tools/bistre_guard/lib/ledger.dart`): heavy recipes (`lint-rust`, `test-rust`, `test-flutter`, `ui-gallery`) run as `bistre_guard locked <cmd>`, which holds an exclusive advisory lock on `.bistre-local/verification/run.lock` and auto-prunes afterwards when any budget is exceeded.
5. Verification ledger: `just check-all` ends with `bistre_guard record`, writing an FNV-1a 64-bit fingerprint per workspace file; `just status` lists unverified files and `just affected [--run]` maps them to the minimal recipe set.
6. Pure-Dart 16 KB ELF verifier (`tools/bistre_guard/lib/elf_verify.dart`): `just verify-16kb <so|dir|apk>` parses ELF64 `PT_LOAD` `p_align` directly (APK entries read from the ZIP central directory), so neither developers nor CI need `llvm-readelf`.
7. Local/CI parity (`justfile` `test-rust`): `just check-all` runs the same Rust gates as CI: nextest, doctests (`cargo test --doc`, which nextest skips), and `bistre_guard smoke` (`tools/bistre_guard/lib/binary_smoke.dart`), which builds `bistre-daemon` in debug and checks the `--health-check` JSON (`wal_mode_active`, `diag.ok`). Crate boundaries are enforced by `cargo deny` `[bans]` `wrappers` in `lint-rust`, which covers the CI `cargo tree` step.
8. Pre-commit hook (`.githooks/pre-commit`, `just install-hooks`): moves Git-for-Windows `/usr/bin` and `/mingw64/bin` behind MSVC `link.exe`, then runs `just fmt-check` and `just guard`.

## Rejected Alternatives
- Periodic `cargo clean`: reclaims disk but forces 10+ minute cold rebuilds and peak linker RAM on every cycle.
- `sccache` / shared global target dir: adds a daemon and cross-project cache coupling for no gain on a single-workspace laptop.
- A Rust `xtask` crate: duplicates the existing Dart tooling (`tools/bistre_guard`) and itself adds to `target/`.

## Consequences & Verification
- Native debuggers cannot step into third-party dependency locals in dev builds; Bistre crates keep `file:line` backtraces.
- Surgical pruning keeps `target/` within the 4.0 GiB budget without cold debug or Android rebuilds; a release build after a prune starts cold.
- Verified by `tools/bistre_guard/test/` (smoke health/usage checks, pruner unit-kind grouping and shared-library skip, FNV-1a vectors, ledger classification, lock contention, ELF `PT_LOAD` parsing of synthetic 4 KiB vs 16 KiB images), `just disk`, and `just check-all`.
