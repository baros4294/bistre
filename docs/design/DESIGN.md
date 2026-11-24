# DESIGN.md — Bistre Sepia Book UI Design System

Single source of truth for Bistre's visual tokens, typography, spacing, 10 Ink Primitives, layout modes, motion language, and accessibility invariants. All Flutter UI code in `apps/bistre_app` MUST derive from this document (`ADR-0001`, `ADR-0011`).

## 1. Visual Identity, Plain Copy & Anti-Slop Discipline
- **Metaphor**: Illuminated archival book and brass fountain nib on warm parchment (`assets/brand/bistre-icon.svg`) — **visual craft only, never user-facing copy jargon**.
- **Plain Everyday UI Copy (Mandatory)**: Every label, button, tab, placeholder, and empty state MUST use normal everyday words a competent non-expert understands (`Send`, `New chat`, `Recent`, `Pinned`, `You`, `Light`, `Dark`, `Document`, `Bubbles`, `Settings`, `Providers & Keys`, `API key`, `Daily spending limit`). Never expose internal/literary jargon (`Inscribe`, `Folio`, `Passage`, `Author`, `Parchment`, `Candlelight`, `Guided Craft`, `Unchained`, `Wax Seal`, `Quill`) in user-facing strings across any locale (`en`, `vi`, `ar`).
- **Vertical-First Restraint**: Use clean vertical list items for navigation, providers, assistants, topics, chats, and settings rows. Only place controls horizontally where 2–3 compact options naturally fit on a single row.
- **Focal Point**: One primary reading/writing surface per screen. No decorative card grids, no gratuitous gradients, no drop-shadow soup, no emojis as UI icons.
- **Surface Separation**: Subtle translucent hairline borders (`1px`) and stepped warm tonal layers (`bgCanvas` → `bgSurface` → `bgElevated`).

### 1.1 Craft Principles (Inherited from the `parchment` v2.6.0 Benchmark)
Parchment `v2.6.0` (the last stable Kotlin/Compose release) is the UX bar Bistre must match or exceed, screen by screen; Parchment v3+ (the abandoned Rust/GPUI port) is never a UI reference. Known gaps against these principles are tracked in Spec 08 §4 until closed.
- **Bubbles hold only the message**: model icon, name, timestamp, and the collapsible `Thinking · 2 tools` summary sit *outside* the bubble; code cards carry only language + line count and right-aligned icon buttons.
- **One bold mark**: a single `rubricMark` start-edge accent bar (`apps/bistre_app/lib/design/bistre_decorations.dart`) marks ONLY the selected sidebar chat, the active settings category, the empty-chat intro, and user prompts in `Document` layout — never competing accent borders.
- **Controls appear when needed**: desktop row/message actions reveal on hover or keyboard focus (plus right-click menu); on touch, only the newest turns expose actions and older turns fold to one quiet `More` button; Android long-press stays reserved for native text selection.
- **Explain on hover**: every icon button and chip shows a short plain hint of what happens.
- **Undo instead of asking**: deleting a chat shows an `8 s` `Undo` toast instead of a confirmation dialog; bulk destructive actions (`Clear all`) never sit next to routine sidebar or filter headers — they live in Settings → Storage.
- **Empty states teach the next step**: the empty chat shows a `rubricMark` intro ("Start with a question, a draft, or a file."), the active model, and one `Set up <provider>` button when no key exists; an empty model list explains why and offers `Fetch models`.
- **Single top header bar**: at most one `~60 dp` header (sidebar toggle, chat title, interactive model subtitle; workspace + settings on the trailing edge) — never stacked double bars. The native window caption reads `<chat title> — Bistre` (or `Settings — Bistre`) with live run progress; off-screen window bounds recenter on launch.
- **Typed icons only**: pass `BistreUiIcon` enums directly; never encode icons as emoji strings or parse labels back into icons.

## 2. Calibrated Sepia Color Tokens (WCAG AA/AAA Verified)
Anchored directly to pigments in `assets/brand/bistre-icon.svg`. Every foreground/background text pair passes WCAG AA (≥4.5:1), and primary/secondary inks pass WCAG AAA (≥7.5:1).

| Token | Day Parchment | Night Candlelight | Semantic Role |
|---|---|---|---|
| `bgCanvas` | `#F6EFE2` | `#19120D` | Primary reading sheet / app backdrop |
| `bgSurface` | `#EFE3CF` | `#231912` | Folio sidebar, message container, code frame |
| `bgElevated` | `#FFFDF8` | `#2E2118` | Composer sheet (`QuillInput`), popovers, overlays |
| `inkPrimary` | `#24160E` | `#F2E6D3` | Primary reading prose & headings (15.35:1 Day / 15.03:1 Night) |
| `inkSecondary` | `#594030` | `#C9B69E` | Secondary labels, speaker names, subtle prose (8.34:1 / 9.41:1) |
| `inkMuted` | `#6E5442` | `#A38E76` | Timestamps, token counts, hints (6.10:1 / 5.90:1) |
| `accentWax` | `#A83625` | `#E06350` | Wax Seal approvals, primary send CTA, destructive emphasis |
| `onAccentWax` | `#FFFDF8` | `#19120D` | High-contrast ink rendered directly atop `accentWax` primary buttons |
| `accentBrass` | `#8B5014` | `#E8A955` | Focus rings, active tabs, interactive engraved highlights |
| `statusOk` | `#2B5E3F` | `#74B88E` | Verified WAL/OTA/pack status (paired with icon + text, never color alone) |
| `statusWarn` | `#8A520F` | `#E6A856` | Budget warning, degraded fallback |
| `statusErr` | `#9E2A1C` | `#EB6B59` | Hard block, signature failure, storage error |
| `borderHairline` | `#6B4B32` @ 18% | `#E8D7BC` @ 16% | 1px translucent ink dividers and outlines |
| `selectionFill` | `#DA8F3D` @ 26% | `#E8A955` @ 28% | Text selection highlight under `SelectableRegion` |
| `hoverTint` | `#6B4B32` @ 8% | `#E8D7BC` @ 8% | Subtle hover highlight on sidebar rows & icon buttons |
| `scrim` | `#24160E` @ 32% | `#0D0906` @ 56% | Modal backdrop & mobile drawer scrim |

- **Dark theme identity**: Bistre keeps the warm espresso `Night Candlelight` palette above (not a cool blue-slate night theme) while adopting the benchmark layout, spacing, and contrast discipline.
- **4-surface auto-contrast**: `readableInk` nudges `inkMuted`, `accentWax`, `accentBrass`, `statusOk`, `statusWarn`, and `statusErr` until each reaches `>= 4.5:1` on all four reading surfaces (`bgCanvas`, `bgSurface`, `bgElevated`, and the `hoverTint` composite); `onFillInk` picks warm ivory `#FFFDF8` before pure white/black for text on filled accents.

## 3. Offline Bundled & Local Custom Typography
Bundled static OFL weights serve as zero-network defaults (zero Google Fonts runtime fetches):
- **Prose & UI**: `Inter` (`Regular` 400, `Medium` 500, `SemiBold` 600, `Bold` 700)
- **Code & Diffs**: `JetBrainsMono` (`Regular` 400, `Medium` 500)
- **Math**: `NotoSansMath` (`Regular` 400), registered lazily on the first rendered math block
- **Budget**: all bundled font files together `<= 2.0 MB` (currently `1.58 MB`), OFL-subsetted with fontTools `subset` (layout features and name records kept, hinting dropped) to Basic Latin + Latin-1 + Latin Extended-A/B + Latin Extended Additional (full Vietnamese) + combining marks + Greek + punctuation, currency, letterlike, arrows, math operators, technical, box drawing, shapes, and dingbats; `NotoSansMath` additionally keeps math alphanumerics and supplemental operators. Arabic renders through the platform fallback font (none of the bundled faces ship Arabic). None of the three fonts declares a Reserved Font Name, so subsets keep their names (`docs/specs/11-performance-and-budgets.md`)
- **End-User Typography Control**: Users can pick any locally installed OS font or browse a local `.ttf`/`.otf` file (`apps/bistre_app/lib/platform/font_manager.dart` via `FontLoader`), and continuously adjust base font size (`12–28px`), line height (`1.30–2.00`), reading column width (`600–1120px`), theme (`System | Light | Dark`), and 5 Atelier accent presets or custom `#RRGGBB` hex (with automatic WCAG AA contrast selection via `BistreAccentOption.highContrastInkOn`).

| Role | Default Family | Default Size / Line-Height | Weight |
|---|---|---|---|
| `titleLarge` | Inter | 22 / 1.32 | 600 |
| `titleMedium` | Inter | 16 / 1.36 | 600 |
| `bodyProse` | Inter | `baseFontSizePx` (15) / `lineHeightFactor` (1.60) | 400 |
| `bodyCompact` | Inter | 14 / 1.44 | 400 |
| `labelStrong` | Inter | 13.5 / 1.38 | 600 |
| `captionMeta` | Inter | 12.5 / 1.34 | 500 |
| `codeBlock` | JetBrainsMono | 13.5 / 1.52 | 400 |

## 3.5 Offline Vector Iconography
- **58 Custom Editorial UI Icons**: Hand-crafted 24×24 pixel-aligned SVG icons pre-compiled offline to `.vec` under `apps/bistre_app/assets/icons/ui/` (`BistreUiIcon` / `BistreIcon` / `BistreIconButton` in `apps/bistre_app/lib/design/bistre_icons.dart`), covering workspace navigation, extended reasoning (`think`), sandboxed shell (`terminal`), DAG session tree (`branch_tree`), 1-click rewind (`rewind`), attachments (`paperclip`), OS sleep guard (`awake`), cron schedules (`schedule`), worktrees (`worktree`), MCP (`mcp_plug`), tables (`table_grid`), Mermaid (`diagram`), saved memory (`memory`), and Story Bible/Manuscript (`book_open`).
- **42 Offline Full-Color AI Lab Icons**: Pre-compiled MIT-licensed `.vec` marks under `apps/bistre_app/assets/icons/labs/` (`LabIconCatalog` / `LabIcon`), supporting optional local user PNG/WebP custom provider images. Zero external icon catalog references or network URLs exist in runtime code (enforced by `just guard`; provenance and MIT notices live strictly in [`ICON-SOURCES.md`](ICON-SOURCES.md) and [`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md)).

## 4. 8pt Spacing, Radii & Layout Modes
- **Spacing Scale**: `4`, `8`, `12`, `16`, `24`, `32`, `48` logical px (strictly `EdgeInsetsDirectional` for RTL).
- **Radii**: `6` (chips/inputs), `10` (surfaces/bubbles), `14` (composer/modals), `999` (wax seal pills).
- **Reading Measure**: Max prose width `740px` centered, for chat prose only; **full-width breakouts** expand wide tables, diffs, and code blocks up to `1160px` on desktop. **Settings and other tool pages fill the content width** (24-28 px gutters), as in `v2.6.0`, so wide windows show more, not more empty space.
- **Dual Layout Modes**:
  - **Sepia Bubbles**: User utterances aligned `AlignmentDirectional.centerEnd` in warm `bgSurface` cards; assistant responses aligned `AlignmentDirectional.centerStart` with hairline ink border.
  - **Open Folio**: Full book-spread editorial column where user and assistant turns alternate with engraved hairline rules, speaker rubric labels, and generous typographic breathing room.

## 5. Disciplined 10 Ink Primitives Budget
Every screen in `apps/bistre_app` composes exclusively from these 10 reusable widgets in `apps/bistre_app/lib/design/ink_primitives.dart` (mechanically verified by `just guard`):
1. `ParchmentScaffold` — Edge-to-edge viewport inset scope (`paddingOf` + `viewInsetsOf`), top bar, scrollable body, docked composer slot.
2. `FolioSurface` — Tonal container (`canvas`/`surface`/`elevated`) with optional 1px hairline border.
3. `InkText` — Semantic text primitive binding `BistreTypography` & `BistreThemeData` colors.
4. `EngravedButton` — Keyboard-focusable (`FocusableActionDetector`), visible brass focus ring, hover/press opacity shift, `Semantics(button: true)`.
5. `WaxSealBadge` — Status seal pairing icon glyph + localized label + tonal border (never color alone).
6. `QuillInput` — Pure `EditableText` wrapper with IME composing guard (`!value.composing.isValid`), Shift+Enter newline / Enter submit, focus ring, placeholder overlay.
7. `FolioDivider` — 1px horizontal/vertical `borderHairline` rule.
8. `InkChip` — Compact toggleable chip (layout, theme, locale, mode) with explicit selected state semantics.
9. `FolioOverlay` — `OverlayPortal`-backed modal/popover with Escape dismiss and focus trap.
10. `EngravedIcon` — Unified `.vec` (`vector_graphics`) resolution-independent GPU `ui.Picture` renderer (`vg.loadPicture` + `CustomPaint`, zero low-res raster downsampling/bilinear blur, zero Material Icons, zero emojis).

## 6. Motion: Instant Where You Act, Alive Where You Look
Owner decisions (2026-11-24): Bistre should feel at least as alive as Parchment `v2.6.0`, and never slower to use. Animation never delays an action: the action fires on the event, and motion only describes it.
- **Instant (0 ms)**: typing, sending, every keyboard-initiated action, thread switching, and message arrival. A committed message never replays an entrance animation.
- **Timings**: `BistreMotion.arriving` **150 ms**, `leaving` **110 ms**, `travelling` **180 ms**, `Curves.easeOutCubic`. Springs are used where `v2.6.0` uses them.
- **Pointer feedback on every clickable** (buttons, chips, icon buttons, rows, tabs, header pressables), built into the shared primitives so every screen gets it:
  - press scales to **0.96** (spring damping 0.78, stiffness 680);
  - hover scales to **1.012** and lifts **0.75 dp** (spring, no bounce, stiffness 560);
  - wide rows (sidebar chats, list rows, tabs) press to **0.985** and only lift on hover, so a 300 px row never visibly jumps (`kRowPressScale`);
  - the focus ring shows for keyboard focus only, never after a pointer press.
- **Disclosures animate their height** (Thinking, the context breakdown, the tools drawer, code fold, settings sections, inspector panels): the size eases on a critically damped spring (stiffness 420) while the content fades with it. Fast input reverses it from the current height and speed. Every disclosure uses `DisclosureReveal` (`lib/design/disclosure_reveal.dart`), the only sanctioned height animation; today it runs Thinking, tool-step details, code fold, prompt-inspector blocks, and skill bodies.
- **Overlays and pills**:
  - modals, menus, and popovers fade and rise in over `arriving`, and leave over `leaving`. That is quicker than `v2.6.0`'s 250 ms, but never an abrupt snap.
  - Floating pills (toasts, Jump to latest) pop in from half their height, scale 0.90 to 1 and fade, on a brisk spring (stiffness 580).
  - Side drawers slide over `travelling`.
- **Hover hints**: every icon button names itself in a small bubble 500 ms after the pointer rests on it (`HoverHint`, `lib/design/hover_hint.dart`), placed below it or above it near the bottom edge, and gone on exit or press. Pointer only.
- **State changes**: selection, toggle, chip, and accent colours cross-fade over `travelling` (`EaseDecoration` in the button, chip, icon-button, and switch primitives); progress and token counters ease to their new value.
- **Scrolling**:
  - on desktop, mouse-wheel scrolling is smooth: notches accumulate into a target that the view eases toward (170 ms ease-out, `SmoothScrollController` in `lib/design/smooth_scroll.dart`; scroll views without their own state use `SmoothScrollable`);
  - trackpad and touch scrolling stay 1:1 (pan-zoom gestures and wheel deltas of 16 px or less pass straight through), and Reduce motion keeps the plain jump;
  - programmatic scrolls (Jump to latest, search hits, branch switches) glide over `travelling`.
- **Streaming text is paced**: replies and thinking reveal in step with the display frame clock:
  - ~92 characters per second, carrying fractional characters between frames;
  - elastic catch-up when more than 28 characters are waiting (the excess shrinks on an 80 ms time constant);
  - the rest appears at once when the reply is committed.
  Implemented in `LiveTurnNotifier` (frame callbacks only while text is waiting, so zero idle frames); Reduce motion and low-memory mode publish each batch as it arrives.
  The text never lags the stream by more than a fraction of a second.
- **Reduced motion**: if `MediaQuery.maybeReduceMotionOf(context)`, `maybeDisableAnimationsOf`, `maybeAccessibleNavigationOf`, or the user's `reduceMotionOverride` is true, every duration and spring above resolves to an instant change, including ones already running, and streamed text appears as it arrives.
- **Lint**: the `bistre_lints` layout-animation rule allows height animation for disclosures; it is narrowed in the same change that implements them.

## 7. Accessibility, IME & RTL Non-Negotiables
- All interactive controls are keyboard-focusable (`FocusableActionDetector`; never a bare `GestureDetector`) and expose `Semantics` labels, **keyboard-only** 2px `accentBrass` focus rings (shown when focus arrived by keyboard, never after a pointer click), and minimum `40x40` touch/click targets (`48x48` on Android). Small icon buttons keep their visual size and take taps across the full target through `TapTargetExpander` (`apps/bistre_app/lib/design/bistre_icons.dart`). Disabled buttons keep their hairline outline.
- **`200%` text scale**: fixed-width columns (sidebar, settings nav) scale with `textScaledWidth` up to `1.6x`; when the effective width (width ÷ text scale) is below 600 px the composer splits into 2 rows while streaming or at `>= 130%` text and the header stacks (and wraps) secondary actions at `>= 135%` text; setting rows stack below 480 px effective width; every model/provider/assistant pill uses `Flexible` + ellipsis. The UI gallery renders `phone-text200` and `desktop-text200`.
- Modals and drawers trap focus (`FocusScope`) and wrap occluded background UI in `ExcludeSemantics` + `ExcludeFocus`; every input keeps its accessible field name; toasts and errors are `liveRegion`s.
- All directional spacing/alignment uses `EdgeInsetsDirectional`, `AlignmentDirectional`, and `TextDirection` resolved from active `BistreLocalizations`.
- **Message direction follows the message**: chat content takes its direction from its first strong character (`contentDirection`, `apps/bistre_app/lib/features/chat/content_direction.dart`), so an English reply inside the Arabic UI reads left to right with its punctuation in place, and an Arabic reply inside the English UI reads right to left; text with no strong character keeps the UI direction.
- Never alter `TextEditingController.text` during active IME composition (`value.composing.isValid`); never set `enableSuggestions: false` on general text inputs (`flutter#192714`).

## 8. Hot-Path UI, Viewport & Low-Memory Invariants
- **Leaf-isolated state**: 16 ms streaming deltas flow into a dedicated leaf `ValueNotifier` (`LiveTurnNotifier`) read only by the active streaming turn inside a `RepaintBoundary`; the shell, header, and sidebar rebuild `0` times per delta. The composer owns its `TextEditingController` (keystrokes never notify the root). Hover, press, focus, and pulse layers animate inside leaf `RepaintBoundary` widgets with `0` parent rebuilds.
- **Viewport & scroll**: the message feed is a full-width `CustomScrollView` (`SliverList.builder`) whose items each center a `ConstrainedBox(maxWidth: readingWidth)`, so the mouse wheel scrolls from the empty page margins; a non-empty chat opens anchored at the bottom; auto-follow pauses immediately on drag or wheel.
- **Code & tools**: code fences soft-wrap by default below `640 px` viewport width, with a global `Wrap code` preference and a per-fence wrap toggle that survives scrolling; wide layouts (≥ 720 px effective width) offer a `Split` / `Unified` diff toggle; consecutive read/search tool steps fold into one quiet row; Markdown export skips empty assistant stubs.
- **Composer context gauge**: a compact radial `ContextGaugeRing` (`apps/bistre_app/lib/features/chat/context_gauge_ring.dart`) shows conversation-limit use. The token count comes from core (`context_usage`): what the next request sends after compaction and the context pin, so it never counts text the model will not see. A newer chat or branch always replaces an older answer. The ring is a button: it opens What fills this conversation, a popover above it with a stacked bar, one row per category (instructions, story notes, chat history, draft, free space), and the Shorten and Prices actions.
- **Low-memory mode** (`< 4 GB` RAM or Android `isLowRamDevice`): no overlay drop shadows, streaming redraw capped at `30 fps`, attachment decode `<= 2560 px` off the UI thread.

## 9. Recovery Surfaces & Plain-Language Glossary
- Backoff notices show the countdown, the plain reason, and an inline trailing `Retry now` button; fixable errors (bad key, missing model, conversation limit, spending limit) show one button that jumps straight to the fix. Unavailable costs show a quiet info icon with a breakdown popup instead of noisy "cost unavailable" text.
- Use these everyday terms in every locale (pair unavoidable terms of art such as `temperature` with a one-line plain description; widely known terms like `API key`, `tokens`, and `Markdown` stay):

| Internal / technical term | UI wording |
|---|---|
| Wire dialect / protocol | API format |
| Base URL / endpoint | Server URL |
| Compact / compaction | Shorten the conversation |
| Context window | Conversation limit |
| Steer | Send now |
| Fork | Branch |
| Mount | Choose folder |
| Reasoning | Thinking |
| Cache read / write | Reused / Saved for reuse |
| Utility requests | Background requests |
| Auto-retrying / backoff | Trying again |

## 10. Screen Anatomy
Each screen's layout contract. Parchment `v2.6.0` parity gaps against it are tracked in Spec 08 §4.
- **Header (one bar)**: leading sidebar toggle → chat title (click to rename) with `model on Provider ▾` as an interactive subtitle beneath it → trailing workspace (folder count), new chat, and settings. Run and sleep status do not live in the header; secondary tools (branches, inspector, shortcuts) live in the command palette and settings. Open chats show as tabs under the header. Every icon has a hover hint.
- **Message**: messenger bubbles by default: yours a tinted pill on the trailing side; replies a hairline-bordered card. Model name and time sit above the bubble, with a collapsed `Thought 4s, 2 tools` on the trailing edge (expanded: a tinted "Thinking and tool steps" panel). Actions reveal on hover or keyboard focus (touch: under the newest turns, older ones in `More`). The streaming and committed views share one layout, so finishing a reply never shifts text.
- **Code card**: `language (N lines)` on the leading edge; wrap, fold, download, and copy as equal icon buttons on the trailing edge.
- **Composer**: the only elevated surface on the page; placeholder `Message <assistant>...`. Bottom row: attach, voice, thinking level, and tools chips on the leading side; the labelled conversation-limit ring (`217/128k (0%)`) and a quiet `Send ↵` on the trailing side. Text typed while a reply streams is never cleared.
- **Empty chat**: one `rubricMark` line, "Start with a question, a draft, or a file.", with the active model beneath it. Without a key, one `Set up <provider>` button instead. No second accent bar, no starter cards.
- **Sidebar**: search field with a `+` new-chat button, then `Assistants | Chats | Pinned`; chats grouped by assistant (count and `Clear all`), each row a title and a relative time. Only the selected row carries the `rubricMark`; row actions reveal on hover or focus.
