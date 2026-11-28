set shell := ["bash", "-euo", "pipefail", "-c"]
set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

# Format Rust and Dart codebases
fmt:
  cargo fmt --all
  dart format apps/bistre_app/lib apps/bistre_app/test apps/bistre_app/hook tools/bistre_lints tools/bistre_i18n tools/bistre_guard

# Check formatting without modifying files
fmt-check:
  cargo fmt --all -- --check
  dart format --output=none --set-exit-if-changed apps/bistre_app/lib apps/bistre_app/test apps/bistre_app/hook tools/bistre_lints tools/bistre_i18n tools/bistre_guard

# Run mechanical code hygiene, doc-sync, version-parity, and CI security guards
guard:
  dart run tools/bistre_guard/bin/bistre_guard.dart

# Run Rust Clippy, supply-chain deny, and boundary checks (single-run lock + storage budget)
lint-rust:
  dart run tools/bistre_guard/bin/bistre_guard.dart locked cargo clippy --locked --workspace --all-targets -- -D warnings
  cargo deny --locked check

# Run Dart static analysis (includes all 5 bistre_lints rules)
lint-dart:
  flutter analyze apps/bistre_app
  dart analyze tools/bistre_lints tools/bistre_i18n tools/bistre_guard

# Validate ICU localization catalogs, Rust DiagnosticKey parity, and generated assets
i18n-check:
  dart run tools/bistre_i18n/bin/bistre_i18n.dart check

# Regenerate typed Dart i18n keys and bundled locale assets
i18n-gen:
  dart run tools/bistre_i18n/bin/bistre_i18n.dart gen

# Regenerate flutter_rust_bridge v2 bindings
codegen-frb:
  flutter_rust_bridge_codegen generate --config-file apps/bistre_app/flutter_rust_bridge.yaml

# Run all Rust unit, integration, and doc tests, then smoke-test the daemon and updater binaries
test-rust:
  dart run tools/bistre_guard/bin/bistre_guard.dart locked cargo nextest run --locked --workspace
  dart run tools/bistre_guard/bin/bistre_guard.dart locked cargo test --doc --locked --workspace
  dart run tools/bistre_guard/bin/bistre_guard.dart smoke

# Run Dart workspace tooling unit tests
test-tools:
  dart test tools/bistre_lints tools/bistre_i18n tools/bistre_guard

# Run Flutter widget, a11y, RTL, contrast, and live Rust FRB v2 tests
[working-directory: 'apps/bistre_app']
test-flutter:
  dart run ../../tools/bistre_guard/bin/bistre_guard.dart locked flutter test

# Render the UI gallery from scratch into apps/bistre_app/build/ui_gallery/ (stale PNGs are removed first)
[working-directory: 'apps/bistre_app']
ui-gallery:
  git clean -fdXq -- build/ui_gallery
  dart run ../../tools/bistre_guard/bin/bistre_guard.dart locked flutter test test/ui_gallery_shell_test.dart test/ui_gallery_overlays_test.dart test/ui_gallery_settings_test.dart test/ui_gallery_matrix_test.dart test/ui_gallery_stress_test.dart test/ui_gallery_sheets_test.dart

# Run all Dart & Flutter tests (cross-platform safe on Windows PowerShell and Linux bash)
test-dart: test-tools test-flutter

# Verify Android 16KB ELF PT_LOAD alignment of a .so, a directory of .so files, or an APK (pure Dart, no llvm-readelf)
verify-16kb path:
  dart run tools/bistre_guard/bin/bistre_guard.dart verify-elf "{{path}}"

# Report workspace build-cache usage against Spec 11 storage budgets
disk:
  dart run tools/bistre_guard/bin/bistre_guard.dart disk

# Non-destructively prune stale Cargo incremental/build units, orphaned deps, and oversized logs (never cargo clean)
prune:
  dart run tools/bistre_guard/bin/bistre_guard.dart prune

# Show storage warnings and files changed since the last green verification run
status:
  dart run tools/bistre_guard/bin/bistre_guard.dart status

# Print the recipes affected by unverified changes (`just affected --run` runs them and records the ledger)
affected *flags:
  dart run tools/bistre_guard/bin/bistre_guard.dart affected {{flags}}

# Repeatable perf harness: streaming frame probe + 300-chat desktop cold start & idle RSS (`--android` adds adb probes)
perf *flags:
  dart run tools/bistre_guard/bin/bistre_guard.dart locked dart run tools/bistre_guard/bin/bistre_guard.dart perf --rss-report-only {{flags}}

# Install the repository pre-commit hook (MSVC link.exe PATH fix + fmt-check + guard)
install-hooks:
  git config core.hooksPath .githooks

# Run full local verification suite and record the verification ledger on success
check-all: fmt-check guard lint-rust i18n-check lint-dart test-rust test-dart
  dart run tools/bistre_guard/bin/bistre_guard.dart record
