# ADR-0007: Single-Source Metadata ICU Catalog & Runtime Hot-Loadable Locale Packs

- Status: Accepted
- Deciders: Bistre Principal Architecture

## Context & Live-Verified Evidence
- Flutter's standard `gen-l10n` compiles `.arb` files into static Dart classes, making zero-restart hot-loadable OTA locale packs impossible, while `flutter_localizations` transitively pulls Material/Cupertino localization delegates.
- `icu4x 2.4.0` / `intl4x 1.0.1` (`pub.dev/packages/intl4x`) brings Unicode ICU4X plural/number/date primitives to Dart.
- AI coding agents and community translators need per-key context, tone, character limits, and placeholder types in a single catalog file to translate the full app cleanly in one pass.

## Decision
1. Store all strings in `l10n/catalog/<bcp47>.bistre-l10n.json` validated against `l10n/schema.json` with mandatory per-key `{message, context, tone, max_chars, placeholders}` metadata, covering every UI label and every Rust `DiagnosticKey`.
2. Workspace CLI `tools/bistre_i18n` checks key parity, ICU brace balance, placeholder type parity, and `max_chars` overflow (`check`), and emits strongly-typed `L10nKey` enum + typed accessors (`gen`).
3. Runtime `BistreLocalizations` (`InheritedNotifier`) evaluates ICU MessageFormat (`{var}`, `plural`, `select`) with CLDR plural category rules and instant `TextDirection` (`ltr`/`rtl`) switching. Track-A `minisign`-verified JSON locale packs hot-load into memory with zero restart.

## Rejected Alternatives
- Flutter `gen-l10n` + `flutter_localizations`: Cannot hot-load OTA locale packs without app rebuilds and pulls Material/Cupertino dependencies.
- Unchecked raw string keys (`t('some.key')`): Silent typos and missing placeholder regressions at runtime.

## Consequences & Verification
- Any new language can be translated and mechanically validated in one command (`dart run tools/bistre_i18n/bin/bistre_i18n.dart check && dart run tools/bistre_i18n/bin/bistre_i18n.dart gen`).
- Verified via `tools/bistre_i18n` tests and Flutter widget tests switching `en` → `vi` → `ar` (RTL) + runtime hot-pack override.
