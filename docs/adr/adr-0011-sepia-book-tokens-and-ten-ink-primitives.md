# ADR-0011: Sepia Book WCAG AA/AAA Tokens, 10 Ink Primitives & Frequency-Aware Motion

- Status: Accepted
- Deciders: Bistre Principal Architecture

## Context & Live-Verified Evidence
- Generic AI client UIs suffer visual slop (unmotivated gradients, inconsistent component proliferation, janky layout animations, broken dark-mode contrast, and emoji icons).
- Bistre's brand emblem `assets/brand/bistre-icon.svg` establishes an archival warm-paper, bistre ink, vermilion seal, and brass palette.
- Flutter 3.50 exposes `MediaQuery.reduceMotionOf` (`PR #190287`), `vector_graphics 1.3.1` pre-compiles SVGs to fast binary `.vec` files, and Impeller is now the default renderer on Windows, Linux, and Android API 29+.

## Decision
1. Anchor `docs/design/design.md` tokens directly to `assets/brand/bistre-icon.svg`, mathematically calibrated so every foreground/background pair passes WCAG AA (≥4.5:1) and primary/secondary inks pass WCAG AAA (7.5:1–17.27:1) across both Warm Sepia and Warm Dark themes.
2. Restrict all UI composition to a disciplined 10 Ink Primitives budget (`BistreScaffold`, `FolioSurface`, `InkText`, `EngravedButton`, `WaxSealBadge`, `QuillInput`, `FolioDivider`, `InkChip`, `FolioOverlay`, `EngravedIcon`).
3. (Partly superseded by the owner's decision in design §6: pointer press/hover springs, disclosure height animation, smooth wheel scrolling, and paced streaming text now animate, keyboard actions, sending, thread switching, and message arrival stay instant.) Apply frequency-aware motion: 0ms for 100+/day and keyboard-initiated actions; 160ms ease-out animating `transform`/`opacity` only for occasional overlays; `Duration.zero` whenever `MediaQuery.reduceMotionOf` is true.
4. Bundle exact static OFL weights (`Inter`, `JetBrainsMono`, `NotoSansMath`) and compile all vector icons to `.vec`.

## Rejected Alternatives
- Dynamic runtime font downloads / variable mega-fonts: Breaks offline-first local guarantee and bloats Android APK by 20+ MB.
- Animating layout properties (`AnimatedContainer` height/padding): Triggers per-frame layout passes and violates 60/120Hz budgets.

## Consequences & Verification
- Verified via Flutter theme contrast unit tests, reduced-motion widget tests, and `Semantics` tree accessibility assertions.
