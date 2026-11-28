# Spec 09: Multilingual i18n, Hot-Loadable Locale Packs & AI Translation

## 1. Zero Hardcoded UI Strings & Typed Rust Diagnostics
- `tools/bistre_lints` (`bistre_forbid_hardcoded_ui_strings`) fails `flutter analyze` whenever a raw string literal (including inside ternaries or `+`/`??` expressions) is passed to `Text`, `InkText`, `TextSpan`, `Semantics`, `RawTooltip`, `Tooltip`, `WidgetsApp`, `EngravedButton`, `WaxSealBadge`, `InkChip`, `QuillInput`, or `EngravedIcon`.
- Text the app sends to a model on the user's behalf and shows as the user's message (Writing Studio `story.request_*`: prose from beats, rewrite / expand / shorten / polish, continue, impersonate) is localized like any UI string; the UI resolves it and passes the finished text to `FolioController`.
- Pure Rust crates never format English UI messages; they emit stable `DiagnosticKey` dot-keys (`diag.*`) resolved in Flutter against the active locale catalog, with Rust↔catalog parity verified by `tools/bistre_i18n check`.
- Plain Everyday Language Rule: Every catalog message across `en`, `vi`, `ar`, and future locale packs must use plain, clear everyday words (`Send`, `New chat`, `You`, `Light`, `Dark`, `Document`, `Bubbles`, `Providers & Keys`, `Daily spending limit`) rather than thematic or internal jargon (`just i18n-check` enforces the banned-word list across every locale).

## 2. Single-Source Metadata Catalog Schema (`l10n/catalog/*.bistre-l10n.json`)
Master catalog `l10n/catalog/en.bistre-l10n.json` conforms to `l10n/schema.json`:
```json
{
  "$schema": "../schema.json",
  "locale": "en",
  "direction": "ltr",
  "entries": {
    "shell.send": {
      "message": "Send",
      "context": "Primary composer submit button",
      "tone": "concise_action",
      "max_chars": 16,
      "placeholders": {}
    }
  }
}
```
Rich metadata (`context`, `tone`, `max_chars`, `placeholders`) enables any human contributor or AI coding agent to translate the entire app accurately in a single pass.

## 3. Runtime ICU Evaluator & Hot-Loadable Locale Packs
Standard Flutter `gen-l10n` compiles static Dart classes and cannot hot-load OTA locale packs without restarting/rebuilding (`ADR-0007`). Instead:
- `tools/bistre_i18n check` validates JSON schema, filename↔locale match, key parity against `en`, ICU brace balance, placeholder name & type parity, `max_chars` limits, Rust `DiagnosticKey` parity against `crates/bistre-protocol/src/lib.rs`, and byte-for-byte freshness of `l10n_keys.g.dart` and `apps/bistre_app/assets/l10n/`.
- `tools/bistre_i18n gen` emits strongly-typed `L10nKey` enum + typed helper methods (`apps/bistre_app/lib/l10n/l10n_keys.g.dart`) and copies validated catalogs to `apps/bistre_app/assets/l10n/`.
- `apps/bistre_app/lib/l10n/` runs a pure-Dart ICU MessageFormat parser/evaluator (`{var}`, `{n, plural, =0{...} one{...} other{...}}`, `{v, select, ...}` + CLDR plural rules for `en`, `vi`, `ar`, etc.) inside `BistreLocalizations` (`InheritedNotifier`).
- Switching locale (`en` ↔ `vi` ↔ `ar`) updates `Directionality` (`ltr`/`rtl`) and every visible string in 1 frame with zero restart. Track-A `minisign`-verified JSON locale packs hot-load directly into `BistreLocalizations.applyHotLocalePack(...)` without restarting.

- `diag.tool.path_denied`: a path outside what a tool or import may use (a skill outside the workspace, a CHARX entry escaping its folder) has its own key; it reused the edit hash-mismatch key, which pointed the user at the wrong fix.
- No orphan strings: 49 keys no code used (old shell headings, topics, welcome prompts, locale labels, retired badges) were removed from every locale. Kept for the settings they belong to: text scale, Send on Enter, the summary and translation model headings, `mode.translate`, and the two live-voice states.
