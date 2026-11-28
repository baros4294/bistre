# ADR-0001: Pure `package:flutter/widgets.dart` UI & First-Party Dart Analyzer Plugin

- Status: Accepted
- Deciders: Bistre Principal Architecture

## Context & Live-Verified Evidence
- Flutter 3.47–3.50.1 (Dart 3.14.0, against `docs.flutter.dev/release/release-notes/release-notes-3.50.0`) officially decoupled `material_ui` and `cupertino_ui` 1.0 and strengthened standalone `package:flutter/widgets.dart` primitives (`SelectableRegion`, `EditableText`, `RawScrollbar`, `RawTooltip`, `OverlayPortal`, `MediaQuery.reduceMotion`, `SliverClipRect`).
- Dart 3.10–3.14 introduced first-party `analysis_server_plugin` (0.3.26 with `analyzer 14.7.0`, verified `dart.dev/tools/analyzer-plugins`), running custom lints natively inside `flutter analyze` and IDEs without spawning a separate `custom_lint` isolate or extra CLI command.
- `SelectionArea`, `TextField`, `Scrollbar`, and `Scaffold` live in `package:flutter/material.dart` and must never enter Bistre.

## Decision
1. `apps/bistre_app` imports strictly `package:flutter/widgets.dart` (plus `foundation`, `rendering`, `services`, `painting`) and builds on `WidgetsApp`, `SelectableRegion`, `EditableText`, `RawScrollbar`, `RawTooltip`, and `OverlayPortal`.
2. State management uses built-in `ChangeNotifier`/`ValueNotifier` + `InheritedNotifier` + `ListenableBuilder` exclusively.
3. Workspace package `tools/bistre_lints` registers via `plugins:` in root `analysis_options.yaml` and fails `flutter analyze` on any forbidden UI/state/HTTP/SQL import (`bistre_forbid_ui_kits`), hardcoded UI string literal (`bistre_forbid_hardcoded_ui_strings`), layout-mutating implicit animation (`bistre_forbid_layout_animations`), raw `Color(...)` literal outside `bistre_theme.dart` (`bistre_forbid_raw_colors`), or physical left/right geometry (`bistre_forbid_non_directional_geometry`).

## Rejected Alternatives
- MaterialApp with stripped theme: Pulls heavy Material design assumptions, ripple semantics, and unwanted visual defaults while violating product non-negotiables.
- `custom_lint` package: Requires a separate CLI command and extra analysis isolate; superseded by Dart's first-party `analysis_server_plugin`.
- Riverpod / Bloc: Unnecessary dependency surface for a thin presentation shell whose state lives in Rust.

## Consequences & Verification
- Requires custom `TextSelectionControls` (`BistreSelectionControls`) and a line-joining selection delegate (`LineSelection`); math blocks copy their LaTeX source with their own Copy button instead of through selection (`flutter#160510`).
- Verified mechanically on every commit via `flutter analyze apps/bistre_app` and `dart test tools/bistre_lints`.
