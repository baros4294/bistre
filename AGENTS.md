# Bistre engineering contract

## 1. Product
- Bistre is a public, MIT, local-first, zero-telemetry AI client for Android (`arm64-v8a`), Windows, and Linux.
- One pure-Rust core (`crates/bistre-*`) and one thin Flutter UI on `package:flutter/widgets.dart` only (`apps/bistre_app`). Protocol, storage, and harness logic live in Rust, never in Dart or platform code.
- Specs describe the target; Spec 00 §6 records what is live.

## 2. Approach
- The owner's explicit instruction overrides any rule here. Conflicting rules, or one that worsens UX, go to the owner.
- Scale effort and report length to the task. Read the owning code and specs before a change.
- On design tasks, walk each user path (model switch, mixed output, multi-turn, unknown data, §3 layouts), test the first idea's mechanisms, failures, and cost, and build the simplest design that holds on all.
- Ask only when code, specs, and conventional defaults cannot settle a decision that blocks correct work.
- Agree or push back on evidence alone. Correct a flawed premise directly; fix your own mistake plainly, without apology.

## 3. Engineering rules
- Less is more: the simplest code that solves the problem. Delete or reuse before adding; no layers, helpers, toggles, or libraries nobody asked for.
- Parse untrusted input once, at the boundary, into types that cannot hold invalid states. Bound every loop, recursion, queue, buffer, retry, cache, and I/O.
- Fail closed: a safety check (spending limit, OTA signature, tool approval, path policy) denies when its own inputs fail to load; only the check constructs its guarantee type.
- Never silence errors (`let _ =`, empty `catch`, `.ok()`, `unwrap_or_default()`, `unwrap_or(..)`, `if let Ok(..)` on a `Result` whose error matters). Propagate, or log a `DiagnosticKey` with a reason.
- Conditions are objective: a limit or trigger is a named constant or observable state (count, size, role, explicit input), never "if large", "when relevant", or "if unclear", in code and prompts alike.
- One fact, one home: each rule, constant, version, and doc fact lives in one place the rest refers to. One name per concept across code, docs, and UI copy; identifiers carry units (`_ms`, `_bytes`, `_micros`).
- A ban targets one failure (silenced error, unbounded queue, raw spawn) and names the sanctioned path, never a valid construct as a whole.
- Never weaken verification (dropped features, skipped work, weaker tests, smaller stress sizes, looser budgets, retries). A regression test fails without its fix.
- Fix causes, never samples: separate a flake (load, timing, ordering) from a defect, never special-case a test input. Read the log, fix the root cause and related ones, then rerun only the failed test (`cargo nextest run -p <crate> <name>`, `flutter test <file> --plain-name <name>`) or CI job (`gh run rerun <id> --failed`), once.
- No volatile facts (model IDs, capabilities, prices, device brands, dates, tracker IDs like `W8`) in code, comments, test names, or docs. Dates and IDs live in `tasks.md`; wire-protocol versions and fixtures are exempt.
- Derived caches carry a format version and rebuild on mismatch.
- Check every layout a change touches: phone (< 720 dp), desktop, 200% text, RTL.
- What was not read, run, or measured this session is `[UNVERIFIED]`. Check versions, APIs, protocols, Action SHAs, and store policies against live official docs.
- Nothing partial sold as done (platforms, locales, widths, states). Before "done": re-read the request, run `just check-all`, review gallery PNGs for UI changes, report what is open.

## 4. Writing
Applies to all text: docs, comments, commits, PRs, reports, UI copy, prompts.
- Deliver the whole answer on the first pass: no preamble, recap, disclaimer, sign-off, unrequested advice, or follow-up offer. A report opens with the outcome, then what is open or unverified.
- Markdown carries structure only: headings to `###`, hyphen bullets, numbered lists for ordered steps, tables for row-and-column data. No bold, italics, horizontal rules, or emoji; a bullet may open with a plain label and a colon. Backticks hold literal code, paths, commands, and keys, never emphasis or plain numbers.
- Prose sits in paragraphs. A sentence starts from known context, lands on the new point, and ends there, with no trailing hedge or clause restating what it showed.
- Plain, specific words: the function, file, number, and unit. No inflated vocabulary, filler adverbs, stacked synonyms, maxims, signposting, performative self-correction, or a point made by denying a foil ("not X, but Y"); `just guard` holds the banned words.
- No em dashes (use a comma, colon, parentheses, or a new sentence), exclamation marks, ellipses, or all-caps emphasis.
- Comments state what the signature cannot (why, invariants, units, bounds, the failure prevented), never a narration of the next line or history.
- UI copy is plain everyday language, idiomatic in each locale with no calques from English (`just i18n-check`).

## 5. Model prompts
Prompts the app sends are code.
- One bullet, one job, stated once at its intended strength; "avoid Y repeatedly" licenses every other Y.
- Name the failure to stop (restated content, padding, invented facts), never a valid structure; no checklist of optional devices, no request to vary its own surface.
- A prompt change names the failure it fixes and ships with a test on recorded output.

## 6. Documentation and hygiene
- Update all affected documentation in the same change as the code, schema, FFI, token, lint, CI, or dependency change. Record each pitfall (tool, environment, CI, test harness) in CONTRIBUTING Known Pitfalls that session; read it before building.
- Owners: architecture and deps: ADR, Spec 00, README, AGENTS. Domain: its spec. UI: `docs/design/design.md`, Spec 08. Strings and `DiagnosticKey`: `l10n/catalog/`, Spec 09. Commands and CI: `justfile`, README, CONTRIBUTING. Security: `SECURITY.md`. Notices: `third-party-notices.md`.
- No `TODO`, `FIXME`, `HACK`, `XXX`, dead code, generator boilerplate, BOM, or CRLF (except `.bat`, `.cmd`, `.iss`, `.rc`); `.ps1` stays ASCII.
- Budgets: non-generated code files at most 1,000 lines, split by responsibility (Spec 00 §5); `AGENTS.md` and `tasks.md` at most 10,000 characters; `tasks.md` lists open work only.
- Names are lowercase with `-`, `_`, or `.`, except names a tool looks up exactly (`just guard` lists them).
- Lint exceptions: Rust `#[expect(.., reason)]` only when unavoidable, never for `unsafe_code`, `unwrap_used`, `expect_used`, `panic`; Dart never suppresses `bistre_*`.

## 7. Build, disk, and git
- Batch edits, iterate with `cargo check -p <crate>`, never overlap heavy builds or wait idle (start CI or `gh workflow run release.yml --ref <branch>`, keep working); release builds once, at task end. On Windows, Cargo and Flutter run in PowerShell: Git Bash's `link` shadows MSVC `link.exe`.
- `target/` at most 4 GiB, `apps/bistre_app/build/` at most 1 GiB (`just disk`); `just prune` keeps the debug and Android caches.
- Never touch `%LOCALAPPDATA%\Bistre` or an installed build. Debug uses `<repo>/.bistre-dev/`; tests use temp dirs.
- Never commit, push, open or merge a PR, tag, or release unless the owner asks for that step. Then: Conventional Commits in reviewable layers, `gh pr merge --rebase`.

## 8. Layer boundaries (mechanically enforced)
- Core crates (protocol, crypto, storage, core): no Flutter, FRB, `openssl`/`native-tls`, GUI, or tray deps; `rusqlite` only in storage, `minisign-verify` only in crypto. Emit `DiagnosticKey` (`diag.*`), never English strings. Money is `MoneyMicros(i64)`, never floats.
- `bistre-ffi`: DTO mapping, runtime bootstrap, and 16 ms delta coalescing only.
- `apps/bistre_app`: no Material/Cupertino, `flutter_localizations`, `google_fonts`, third-party state/HTTP/SQL packages, hardcoded strings, raw `Color(...)` outside `bistre_theme.dart`, or left/right geometry. State is `ChangeNotifier`/`ValueNotifier` split by domain; the root `WidgetsApp` listens only to appearance and locale.

## 9. Runtime, security, and UI invariants
- Rust: `#![deny(unsafe_code)]` (audited `// SAFETY:` shims only in crypto, daemon); no `unwrap`, `expect`, `panic!`, `dbg!`, `process::exit`; bounded channels; no blocking I/O on async threads; every await in a run races its cancel signal.
- Processes: `no_window_command`, `spawn_contained`/`run_bounded`, `spawn_detached`; whole-tree kill on timeout. Raw `Command::new`, Dart `Process`, and `mmap` are banned.
- Domain invariants live in their specs with tests (Spec 01, 02, 04, 06, 10, ADR-0017); never retry a spend cap, and reserve before each paid POST. One version: `Cargo.toml` = `pubspec.yaml` (`just bump`).
- Flutter UI: read `docs/design/design.md` and `.agents/skills/fullstack-architect/SKILL.md` first. 10 Ink Primitives, typed `BistreUiIcon`, streaming deltas only in a leaf `ValueNotifier`, Reduce motion honoured, tap targets labelled and at least 40 px (48 dp touch), `TextEditingController.text` untouched while composing.
- CI: Actions pinned to 40-char SHAs, `persist-credentials: false`, least privilege, `timeout-minutes`, no `${{ }}` inside `run:`.
- Spec 11 performance budgets are hard failures.

## 10. Commands and index
- `just check-all` runs every gate; also `just ui-gallery`, `just perf`, `just status`, `just codegen-frb` (after FFI changes).
- Specs (`docs/specs/`): `00-architecture`, `01-canonical-history-and-storage`, `02-providers-wire-and-self-healing`, `03-aio-registry-and-slots`, `04-agent-harness-tools-and-mcp`, `05-modes-roleplay-and-media`, `06-trust-and-wallet-shield`, `07-secrets-and-os-security`, `08-sepia-book-ui`, `09-i18n-and-ai-translation`, `10-silent-ota-and-distribution`, `11-performance-and-budgets`.
- ADRs (`docs/adr/`, topic in the file name): ADR-0001, ADR-0002, ADR-0003, ADR-0004, ADR-0005, ADR-0006, ADR-0007, ADR-0008, ADR-0009, ADR-0010, ADR-0011, ADR-0012, ADR-0013, ADR-0014, ADR-0015, ADR-0016, ADR-0017, ADR-0018, ADR-0019.
