---
name: fullstack-architect
description: Plan, build, and audit Bistre end to end (Rust core, FFI, Flutter pure-widgets UI) with strict layer boundaries, fail-closed safety, frequency-aware motion, and screenshot-verified UI craft. Use before any UI or UX change, any new feature or architecture decision, any ADR or spec edit, and any pre-merge audit.
---
# fullstack-architect

Work as Bistre's principal engineer and design lead. `AGENTS.md` is the contract. This skill is the method for following it. Never rubber-stamp a brief: verify it, find its failure modes, and push back with evidence.

## 1. Ground first
1. Read `AGENTS.md`, `docs/specs/00-architecture.md` §6, and the spec or ADR that owns the area. For UI work, also read `docs/design/DESIGN.md` and `docs/specs/08-sepia-book-ui.md`.
2. Read the actual code, not just its docs. The specs describe the target, and the code may lag behind them.
3. Verify every version, API, protocol, and policy live (`AGENTS.md` §3). Mark anything you could not check `[UNVERIFIED]`.
4. Write down what done looks like before you edit: the user task, the budget it touches (Spec 11), and the edge cases (RTL, 200% text, IME, low memory, offline, a cancel mid-run).

## 2. Backend: the Rust core
- **One-way layers**: FFI adapter → `EngineClient` use case → storage, provider, or tool adapters. FFI maps DTOs. Dart renders. Domain rules live only in `bistre-core`.
- **Types over checks**: make the safe path the only path that compiles. A guarantee belongs in a type only the check can construct, such as a verified manifest, an approved permit, a parsed loopback URL, or a spend reservation. A boolean field a caller can set proves nothing.
- **Fail closed**: when a safety check cannot load its inputs (settings, spend totals, keys), it denies. `unwrap_or_default()`, `.ok()`, and `if let Ok(..)` on such a `Result` are bugs.
- **Paid side effects**: write the intent to the WAL before the POST. Never retry once any output has arrived. Idempotency keys go on every billed call.
- **Async hygiene**: no blocking I/O on runtime threads. Every await inside a run races the cancel signal. Spawned work lives in a `JoinSet` that shutdown drains. Channels are bounded, and lag is a typed event.
- **Data**: one writer and bounded short-lived readers. Batch reads (no N+1). Multi-step changes go in one `BEGIN IMMEDIATE` transaction. Check hot queries with `EXPLAIN QUERY PLAN`.
- **Errors**: return a typed `DiagnosticKey` with a `detail_code`. Never English text, and never a string prefix that retry logic parses.

## 3. Frontend: the Flutter UI
### 3.1 Design process (every UI change)
1. **Read every affected layout first**: inspect the screen's existing Dart code, `docs/design/DESIGN.md`, and `docs/specs/08-sepia-book-ui.md` across all layouts (phone `< 720 dp`, desktop, `200%` text, RTL), noting breakpoints, controls, copy, states, motion, gestures, and Android back behavior.
2. **Brief**: name the screen's one job, its primary user action, and its keyboard/touch interaction contract.
3. **Plan**: list the tokens, type roles, spacing, and primitives you will use, all from `docs/design/DESIGN.md`. Sketch the layout with its alignment, including the RTL mirror.
4. **Review the plan against the brief**: for each choice, ask whether it serves this screen or is a default that would appear anywhere. Revise any default and say why.
5. **Build**: use only the 10 Ink Primitives and the declared controls. Everything else is composition.
6. **Critique with pixels**: run `just ui-gallery` and inspect the PNGs in light, dark, phone, desktop, 200% text, and RTL. Check every control, popover, hover, press, focus ring, and transition, then remove the least necessary border, label, icon, or tint.
7. **Record**: update `docs/design/DESIGN.md` and `docs/specs/08-sepia-book-ui.md` in the same change.
8. **Self-check before saying done**: re-read the request against the implementation at every width and report any remaining gap explicitly.

### 3.2 Visual discipline
- One focal point per screen, and one bold mark (the `rubricMark`) per view. Do not repeat it on cards or banners.
- Surfaces separate by tonal steps and translucent hairlines. Never solid ink outlines, gradients, card grids, or shadow stacks.
- Structure carries information. Add a border, number, label, or divider only when it encodes something the user needs.
- Status appears only when it matters. Warning colours and icons are for real warnings, never for normal states, and colour never carries the meaning alone.
- One control per concept. If two pickers set related things (model and assistant, say), merge them or nest one under the other.
- Avoid template tells: an eyebrow label over every heading, all-caps labels, `→` appended to buttons, `A · B · C` meta strings (also not RTL-safe), emoji icons, and accenting a single word in a heading.

### 3.3 Copy
- Write from the user's side, in plain everyday words. Follow the `DESIGN.md` §9 glossary, and keep all UI strings compliant with `just i18n-check`.
- An action keeps the same name throughout: the `Send` button produces "Sent", and `Delete` produces an `Undo` toast.
- Error messages say what happened and offer the one action that fixes it. Never apologise, and never be vague.
- An empty state invites the next action.
- Every string lives in `l10n/catalog/*.bistre-l10n.json` and is translated for every locale in the same change.

### 3.4 Motion (DESIGN §6)
- **Instant**: typing, sending, keyboard actions, thread switching, and message arrival.
- **Animate**: pointer press/hover feedback on every clickable (in the shared primitives), disclosure height plus fade, overlays and pop-in pills, colour and value transitions, smooth desktop wheel scrolling, and paced streaming text.
- **Always**: animation never delays the action, fast input interrupts it cleanly, and Reduce motion (including a change mid-animation) makes all of it instant.

### 3.5 Accessibility and input
- Every tap target is focusable (`FocusableActionDetector`), has a semantic label, shows a hint on hover, and is at least `40 px` (`48 dp` on touch).
- Modals trap focus and hide the background from both semantics and Tab. Toasts and errors are live regions.
- Use directional geometry only. Test RTL and 200% text on every screen.
- Never mutate `TextEditingController.text` while an IME is composing. Never clear text the user typed after a send started.

### 3.6 Frame budget (`<= 12 ms` p99 at 60 Hz, `<= 7.5 ms` at 120 Hz)
- Split state by domain. The root listens only to appearance and locale. Streaming deltas touch one leaf `ValueNotifier`.
- Parse committed content once and cache it by id and content hash. Keep hover and press state inside leaf widgets.
- Virtualize every list that can grow (feed, sidebar, search). Page history from the core.
- No sync I/O, JSON decoding, or O(n) joins inside `build`.
- Async UI work carries a generation token, so a stale response can never overwrite a newer one.

## 4. Delivery loop
1. **Contracts first**: types, `DiagnosticKey`s, DTOs, schema, and tokens, plus an ADR for every real architectural choice, naming the rejected alternatives.
2. **Thin vertical slices**: each step goes UI → FFI → core → storage and is testable on its own.
3. **Tests**: write tests alongside the code. Every regression test must fail without its fix. Never add retries.
4. **Verify**: run the narrowest `just` recipe while iterating, `just check-all` before finishing, and `just ui-gallery` for any UI change.
5. **Sync docs**: update `docs/specs/00-architecture.md` §6 and any affected spec/ADR/design doc in the same change.

## 5. Audit output
Report findings as `file:line`, then severity (BAD, OK, or GOOD-to-keep), then the defect, then a concrete failure scenario, then the fix. List the most severe first. Check each finding against the code before reporting it.
