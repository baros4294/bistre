# ADR-0002: `flutter_rust_bridge` v2 + Dart Native Assets Build Hooks & Android 16KB Alignment

- **Status**: Accepted
- **Date**: 2026-11-21
- **Deciders**: Bistre Principal Architecture

## Context & Live-Verified Evidence
- `flutter_rust_bridge 2.13.0` (2026-08-23) ships first-class Dart Native Assets integration via `flutter_rust_bridge_hooks 2.13.0` and `native_toolchain_rust 1.1.1` (`cjycode.com/flutter_rust_bridge/manual/integrate/native-assets`).
- Legacy Cargokit broke under Flutter `3.44+` / AGP 9 / Gradle 9.1 (`fzyzcjy/flutter_rust_bridge#3300`).
- Google Play requires 16 KB ELF page alignment on `arm64-v8a` for Android 15+ (Nov 2025; API 36 / Feb 1, 2027 enforcement). NDK r28+ (local NDK r30 `30.0.16248370`) defaults to 16 KB alignment; explicit Rust linker flags guarantee alignment across all build invocations.

## Decision
1. Use `flutter_rust_bridge 2.13.0` with Dart Native Assets (`apps/bistre_app/hook/build.dart`) compiling `crates/bistre-ffi` (`crate-type = ["staticlib", "cdylib"]`).
2. Pin exact Rust toolchain `1.100.0` in `rust-toolchain.toml` (required by `native_toolchain_rust` for deterministic build hooks).
3. Enforce `-C link-arg=-Wl,-z,max-page-size=16384` (plus size flags `force-unwind-tables=no`, `--gc-sections`, `--icf=safe`; `ADR-0016`) in `.cargo/config.toml` and `apps/bistre_app/hook/build.dart` for `aarch64-linux-android`, and `useLegacyPackaging = false` in Android Gradle.
4. Keep `crates/bistre-ffi` on Rust edition `2021` for maximum `frb_codegen 2.13.0` compatibility while pure domain crates use Rust edition `2024`.

## Rejected Alternatives
- **Cargokit**: Fragile Gradle Groovy scripts broken on AGP 9 / Gradle 9.
- **Hand-written `dart:ffi` C bindings**: High boilerplate and error-prone memory/async marshalling across streams and nested DTOs.

## Consequences & Verification
- Zero platform plugin boilerplate across Windows, Linux, and Android.
- Verified in CI and locally via the pure-Dart ELF64 verifier (`just verify-16kb <apk>`, `ADR-0016`) asserting every `PT_LOAD` `p_align >= 0x4000`, plus `zipalign -c -P 16 4 <apk>`.
