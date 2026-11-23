# `bistre_app` — Bistre Flutter Presentation Shell

Pure `package:flutter/widgets.dart` Sepia Book UI for Android (`arm64-v8a`, 16 KB aligned), Windows, and Linux.

## Invariants
- Zero Material or Cupertino UI libraries, third-party state frameworks, or direct HTTP/SQL logic (enforced by [`tools/bistre_lints`](../../tools/bistre_lints) inside `flutter analyze`).
- Visual tokens, typography, motion, and the 10 Ink Primitives are governed by [`docs/design/DESIGN.md`](../../docs/design/DESIGN.md) and [`docs/specs/08-sepia-book-ui.md`](../../docs/specs/08-sepia-book-ui.md).
- Native Rust bridge (`crates/bistre-ffi`) compiles automatically via Dart Native Assets (`hook/build.dart`).

## Verification
Run from repository root:
```bash
just check-all
```
