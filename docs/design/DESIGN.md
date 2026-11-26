# DESIGN.md — Bistre Sepia Book UI Design System

Single source of truth for Bistre's visual tokens, typography, spacing, 10 Ink Primitives, layout modes, motion language, and accessibility invariants. All Flutter UI code in `apps/bistre_app` MUST derive from this document (`ADR-0001`, `ADR-0011`).

## 1. Visual Identity, Plain Copy & Anti-Slop Discipline
- **Metaphor**: Illuminated archival book and brass fountain nib on warm paper (`assets/brand/bistre-icon.svg`) — **visual craft only, never user-facing copy jargon**.
- **App icon sizes** (2026-11-26): the plate version (`bistre-icon.svg`) stays the master and the Android launcher icon. Desktop icons drop the plate so the book and nib fill the icon: `bistre-icon-glyph.svg` (about 1.9× larger, full detail) for 40 px and up, and `bistre-icon-small.svg` (one bold silhouette: thick page outlines, two text lines per page, the nib with a heavy light halo for dark taskbars) for 16–32 px. The Windows `app_icon.ico` holds 16, 20, 24, 32 (small) and 40, 48, 64, 128, 256 (glyph), each rendered from vector; Linux ships the glyph as `bistre.svg` and a 256 px `bistre.png`. Regenerate with any SVG renderer (for example `resvg -w N -h N <svg> <png>`) and pack the PNGs as ICO entries.
- **Plain Everyday UI Copy (Mandatory)**: Every label, button, tab, placeholder, and empty state MUST use normal everyday words a competent non-expert understands (`Send`, `New chat`, `Recent`, `Pinned`, `You`, `Light`, `Dark`, `Document`, `Bubbles`, `Settings`, `Providers & Keys`, `API key`, `Daily spending limit`). Never expose internal or literary jargon in user-facing strings across any locale (`en`, `vi`, `ar`; enforced by `just i18n-check`).
- **Vertical-First Restraint**: Use clean vertical list items for navigation, providers, assistants, topics, chats, and settings rows. Only place controls horizontally where 2–3 compact options naturally fit on a single row.
- **Focal Point**: One primary reading/writing surface per screen. No decorative card grids, no gratuitous gradients, no drop-shadow soup, no emojis as UI icons.
- **Surface Separation**: Subtle translucent hairline borders (`1px`) and stepped warm tonal layers (`bgCanvas` → `bgSurface` → `bgElevated`).

### 1.1 Craft Principles
- **Bubbles hold only the message**: model icon, name, timestamp, and the collapsible `Thinking` summary sit *outside* the bubble; code cards carry only language + line count and trailing icon buttons.
- **One bold mark**: a single `rubricMark` start-edge accent bar (`apps/bistre_app/lib/design/bistre_decorations.dart`) marks ONLY the selected sidebar chat, the active settings category, the empty-chat intro, and user prompts in `Document` layout — never competing accent borders.
- **Controls appear when needed**: desktop row/message actions reveal on hover or keyboard focus (plus right-click menu); on touch, only the newest turns expose actions and older turns fold to one quiet `More` button; Android long-press stays reserved for native text selection.
- **Explain on hover**: every icon button and chip shows a short plain hint of what happens.
- **Undo instead of asking**: deleting a chat shows an `8 s` `Undo` toast instead of a confirmation dialog; bulk destructive actions (`Clear all`) never sit next to routine sidebar or filter headers — they live in Settings → Storage.
- **Empty states teach the next step**: the empty chat shows a `rubricMark` intro ("Start with a question, a draft, or a file."), the active model, and one `Set up <provider>` button when no key exists; an empty model list explains why and offers `Fetch models`.
- **Single top header bar**: at most one `~60 dp` header (sidebar toggle, chat title, interactive model subtitle; workspace + settings on the trailing edge) — never stacked double bars. The native window caption reads `<chat title> — Bistre` (or `Settings — Bistre`) with live run progress; off-screen window bounds recenter on launch.
- **Typed icons only**: pass `BistreUiIcon` enums directly; never encode icons as emoji strings or parse labels back into icons.

## 2. Calibrated Sepia Color Tokens (WCAG AA/AAA Verified)
Anchored directly to pigments in `assets/brand/bistre-icon.svg`. Every foreground/background text pair passes WCAG AA (≥4.5:1), and primary/secondary inks pass WCAG AAA (≥7.5:1).

| Token | Warm Sepia | Warm Dark | Semantic Role |
|---|---|---|---|
| `bgCanvas` | `#F6EFE2` | `#19120D` | Primary reading sheet / app backdrop |
| `bgSurface` | `#EFE3CF` | `#231912` | Sidebar, message container, code frame |
| `bgElevated` | `#FFFDF8` | `#2E2118` | Composer sheet (`QuillInput`), popovers, overlays |
| `inkPrimary` | `#24160E` | `#F2E6D3` | Primary reading prose & headings (15.35:1 Light / 15.03:1 Dark) |
| `inkSecondary` | `#594030` | `#C9B69E` | Secondary labels, speaker names, subtle prose (8.34:1 / 9.41:1) |
| `inkMuted` | `#6E5442` | `#A38E76` | Timestamps, token counts, hints (6.10:1 / 5.90:1) |
| `accentWax` | `#8B5014` | `#E5A44D` | Default Warm Sepia Brown primary CTA & emphasis (`wax` Vermilion stays available as an optional swatch) |
| `onAccentWax` | `#FFFDF8` | `#19120D` | High-contrast ink rendered directly atop `accentWax` primary buttons |
| `accentBrass` | `#9C5D18` | `#F0BE73` | Focus rings, active tabs, interactive highlights |
| `statusOk` | `#2B5E3F` | `#74B88E` | Verified WAL/OTA/pack status (paired with icon + text, never color alone) |
| `statusWarn` | `#8A520F` | `#E6A856` | Budget warning, degraded fallback |
| `statusErr` | `#9E2A1C` | `#EB6B59` | Hard block, signature failure, storage error |
| `borderHairline` | `#6B4B32` @ 18% | `#E8D7BC` @ 16% | 1px translucent ink dividers and outlines |
| `selectionFill` | `#DA8F3D` @ 26% | `#E8A955` @ 28% | Text selection highlight under `SelectableRegion` |
| `hoverTint` | `#6B4B32` @ 8% | `#E8D7BC` @ 8% | Subtle hover highlight on sidebar rows & icon buttons |
| `scrim` | `#24160E` @ 32% | `#0D0906` @ 56% | Modal backdrop & mobile drawer scrim |

- **Dark theme identity & curated color presets**: Bistre's defaults remain warm sepia (`Warm Sepia` / `Warm Dark`), and Settings → Appearance offers 9 curated color presets (`BistreThemePreset`) with plain everyday names and live miniature preview cards: `Warm Sepia`, `Blue Cream`, `Night Blue`, `Warm Ivory`, `Deep Sepia`, `Warm Dark`, `Pure Black`, `Clean Paper`, and `Dark Slate`.
- **4-surface auto-contrast**: `readableInk` nudges `inkMuted`, `accentWax`, `accentBrass`, `statusOk`, `statusWarn`, and `statusErr` until each reaches `>= 4.5:1` on all four reading surfaces (`bgCanvas`, `bgSurface`, `bgElevated`, and the `hoverTint` composite) across all presets; `onFillInk` picks warm ivory `#FFFDF8` before pure white/black for text on filled accents.

## 3. Offline Bundled & Local Custom Typography
Bundled static OFL weights serve as zero-network defaults (zero runtime font fetches):
- **Prose & UI**: `Inter` (`Regular` 400, `Medium` 500, `SemiBold` 600, `Bold` 700)
- **Code & Diffs**: `JetBrainsMono` (`Regular` 400, `Medium` 500)
- **Math**: `NotoSansMath` (`Regular` 400), registered lazily on the first rendered math block
- **Budget**: all bundled font files together `<= 2.0 MB` (currently `1.58 MB`), OFL-subsetted with fontTools `subset` to Basic Latin, Latin-1, Latin Extended-A/B, Latin Extended Additional (full Vietnamese), combining marks, Greek, punctuation, currency, letterlike, arrows, math operators, technical, box drawing, shapes, and dingbats; `NotoSansMath` additionally keeps math alphanumerics and supplemental operators. Arabic renders through the platform fallback font. None of the three fonts declares a Reserved Font Name, so subsets keep their names (`docs/specs/11-performance-and-budgets.md`).
- **End-User Typography Control**: Users can pick any locally installed OS font or browse a local `.ttf`/`.otf` file (`apps/bistre_app/lib/platform/font_manager.dart` via `FontLoader`), and continuously adjust base font size (`12–28px`), line height (`1.30–2.00`), reading column width (`600–1120px`), theme (`System | Light | Dark`), and accent presets or custom `#RRGGBB` hex (with automatic WCAG AA contrast selection via `BistreAccentOption.highContrastInkOn`).

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
- **Custom Editorial UI Icons**: Hand-crafted 24×24 pixel-aligned SVG icons pre-compiled offline to `.vec` under `apps/bistre_app/assets/icons/ui/` (`BistreUiIcon` / `BistreIcon` / `BistreIconButton` in `apps/bistre_app/lib/design/bistre_icons.dart`).
- **Offline AI Lab Icons**: Pre-compiled `.vec` provider marks under `apps/bistre_app/assets/icons/labs/` (`LabIconCatalog` / `LabIcon`), supporting optional local user PNG/WebP custom provider images. Zero external icon catalog references or network URLs exist in runtime code (enforced by `just guard`; all third-party attributions live strictly in [`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md)).

## 4. 8pt Spacing, Radii & Layout Modes
- **Spacing Scale**: `4`, `8`, `12`, `16`, `24`, `32`, `48` logical px (strictly `EdgeInsetsDirectional` for RTL).
- **Radii**: `6` (chips/inputs), `10` (surfaces/bubbles), `14` (composer/modals), `999` (status pills).
- **Reading Measure**: Max prose width `740px` centered, for chat prose only; **full-width breakouts** expand wide tables, diffs, and code blocks up to `1160px` on desktop. **Settings and other tool pages fill the content width** (24–28 px gutters) so wide windows show more content rather than empty margins.
- **Dual Layout Modes**:
  - **Bubbles**: User utterances aligned `AlignmentDirectional.centerEnd` in warm `bgSurface` cards; assistant responses aligned `AlignmentDirectional.centerStart` with hairline ink border.
  - **Document**: Full editorial column where user and assistant turns alternate with engraved hairline rules, speaker rubric labels, and generous typographic breathing room.

## 5. Disciplined 10 Ink Primitives Budget
Every screen in `apps/bistre_app` composes exclusively from these 10 reusable widgets in `apps/bistre_app/lib/design/ink_primitives.dart` (mechanically verified by `just guard`):
1. `BistreScaffold` — Edge-to-edge viewport inset scope (`paddingOf` + `viewInsetsOf`), top bar, scrollable body, docked composer slot.
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
Animation never delays an action: the action fires on the event, and motion only describes it.
- **Instant (0 ms)**: typing, sending, every keyboard-initiated action, thread switching, and message arrival. A committed message never replays an entrance animation.
- **Timings**: `BistreMotion.arriving` **150 ms**, `leaving` **110 ms**, `travelling` **180 ms**, `Curves.easeOutCubic`.
- **Pointer feedback on every clickable** (buttons, chips, icon buttons, rows, tabs, header pressables), built into the shared primitives so every screen gets it:
  - press scales to **0.96** (spring damping 0.78, stiffness 680);
  - hover scales to **1.012** and lifts **0.75 dp** (spring, no bounce, stiffness 560);
  - wide rows (sidebar chats, list rows, tabs) press to **0.985** and only lift on hover, so a 300 px row never visibly jumps (`kRowPressScale`);
  - the focus ring shows for keyboard focus only, never after a pointer press.
- **Disclosures & docked panels animate smoothly**:
  - Disclosures (`DisclosureReveal`, stiffness 420) ease height + fade on a critically damped spring;
  - The docked desktop sidebar (`SidebarDock`, `apps/bistre_app/lib/design/sidebar_slide_reveal.dart`) slides over `travelling` with `Curves.easeOutCubic` and reverses from where it is mid-flight. The chat area takes its final width once, when the toggle is pressed, and only moves while the sidebar slides, so text, titles, and the composer never re-lay out frame by frame. No fade (no offscreen layer per frame). A closed sidebar stays mounted (offstage, not ticking, not focusable) so reopening it costs nothing. The trailing docks (inspector, Studio) use `SidebarSlideReveal` with the same motion, also mounted while closed;
  - The header has one sidebar toggle, always first in the chat header (open or closed, LTR or RTL), and the trailing header buttons (New chat, Studio, Settings) are always there and never change with the sidebar; the phone drawer keeps its own close button;
  - `BistreSlider` thumbs glide smoothly on tap/step via critically damped spring (stiffness 520) and track 1:1 on pointer drag;
  - Settings category changes cross-fade smoothly via `FolioFadeSlide`.
- **Overlays, banners, and pills**:
  - modals, menus, and popovers fade and rise in over `arriving`, and leave over `leaving`.
  - Slim top update/status banners (`FolioTopBanner`) reveal beneath the header via `DisclosureReveal`.
  - Floating pills (centered top toasts `• <message> [Action] ×`, Jump to latest) pop in from half their height, scale 0.90 to 1 and fade, on a brisk spring (stiffness 580).
  - Side drawers slide over `travelling`.
- **Model picker**: cross-provider searchable picker (`ModelPickerPopover`): search input (`Enter` selects top match), provider filter chips (`All providers (N)`), slash-prefixed model-family filter chips (`All families`), active model pinned first when unfiltered, and per-row privacy badges (`On device` in ok ink for loopback hosts, else `Cloud`; `Stored` / `No store` when server response storage applies).
- **Tab switcher**: desktop tab strip (`ChatTabStrip`) adds `+` and `N tabs`, and phone headers show a compact tab counter badge once `> 1` tab is open or any background chat is streaming; both open `TabSwitcherModal` (bottom sheet on phone, centered modal on desktop, 1 column below 420 effective px, filter above 3 tabs, `Close N empty`, `StreamingPulseDot` on streaming tabs). `Ctrl+Tab` / `Ctrl+Shift+Tab` cycles open tabs.
- **Android back**: back closes the innermost open layer first (command palette, overlays, tab switcher, chat map, model picker, studio pane, inspector, search panel, phone drawer); Settings steps back inside itself; with nothing open the app exits as usual.
- **Context menu**: right-clicking a sidebar chat offers Pin, Rename, and Delete; right-clicking a message opens its actions at the pointer (Reply or Edit, Copy, Pin reply, Turn details, Regenerate, Start context here, Delete in error ink); right-clicking a code card offers Copy, Wrap/Unwrap, Fold/Unfold, and Save (`ContextMenuRegion`, `apps/bistre_app/lib/design/context_menu.dart`). Arrow keys move, Enter chooses, Escape or an outside click closes. Touch keeps the visible action bar, because long-press selects text.
- **Hover hints**: icon buttons, header pressables, context gauge, thinking chip, and per-turn usage pills name themselves in a small bubble 500 ms after the pointer rests on them (`HoverHint`, `apps/bistre_app/lib/design/hover_hint.dart`), placed below or above near the bottom edge, and gone on exit or press. Pointer only.
- **State changes**: selection, toggle, chip, and accent colours cross-fade over `travelling` (`EaseDecoration` in the button, chip, icon-button, and switch primitives); progress and token counters ease to their new value.
- **Scrolling**:
  - on desktop, mouse-wheel scrolling is smooth: notches accumulate into a target that the view eases toward (170 ms ease-out, `SmoothScrollController` in `apps/bistre_app/lib/design/smooth_scroll.dart`; scroll views without their own state use `SmoothScrollable`);
  - trackpad and touch scrolling stay 1:1 (pan-zoom gestures and wheel deltas of 16 px or less pass straight through), and Reduce motion keeps the plain jump;
  - programmatic scrolls (Jump to latest, search hits, branch switches) glide over `travelling`.
- **Streaming text is paced**: replies and thinking reveal in step with the display frame clock:
  - ~92 characters per second, carrying fractional characters between frames;
  - elastic catch-up when more than 28 characters are waiting (the excess shrinks on an 80 ms time constant);
  - the rest appears at once when the reply is committed.
  Implemented in `LiveTurnNotifier` (frame callbacks only while text is waiting, so zero idle frames); Reduce motion and low-memory mode publish each batch as it arrives.
- **Reduced motion**: if `MediaQuery.maybeReduceMotionOf(context)`, `maybeDisableAnimationsOf`, `maybeAccessibleNavigationOf`, or the user's `reduceMotionOverride` is true, every duration and spring above resolves to an instant change, including ones already running, and streamed text appears as it arrives.

## 7. Accessibility, IME & RTL Non-Negotiables
- All interactive controls are keyboard-focusable (`FocusableActionDetector`; never a bare `GestureDetector`) and expose `Semantics` labels, **keyboard-only** 2px `accentBrass` focus rings (shown when focus arrived by keyboard, never after a pointer click), and minimum `40x40` touch/click targets (`48x48` on Android). Small icon buttons keep their visual size and take taps across the full target through `TapTargetExpander` (`apps/bistre_app/lib/design/bistre_icons.dart`). Disabled buttons keep their hairline outline.
- **`200%` text scale**: fixed-width columns (sidebar, settings nav) scale with `textScaledWidth` up to `1.6x`; when the effective width (width ÷ text scale) is below 600 px the composer splits into 2 rows while streaming or at `>= 130%` text and the header stacks (and wraps) secondary actions at `>= 135%` text; setting rows stack below 480 px effective width; below 720 px Settings switches to the compact phone layout (`apps/bistre_app/lib/features/settings/settings_mobile.dart`): one header (`Settings` + `Chat` at the root, a `Settings` back button + page name on a page), a search field, and a vertical list of page cards (tinted icon box, name, one-line summary, matched settings, chevron); one page at a time; Android back and a start-edge swipe (72 px) step back from search, to the page, to the list, then close; at `>= 130%` text the page name gets its own header row; every model/provider/assistant pill uses `Flexible` + ellipsis. The UI gallery renders `phone-text200` and `desktop-text200`.
- Modals and drawers trap focus (`FocusScope`) and wrap occluded background UI in `ExcludeSemantics` + `ExcludeFocus`; every input keeps its accessible field name; toasts and errors are `liveRegion`s.
- All directional spacing/alignment uses `EdgeInsetsDirectional`, `AlignmentDirectional`, and `TextDirection` resolved from active `BistreLocalizations`.
- **Message direction follows the message**: chat content takes its direction from its first strong character (`contentDirection`, `apps/bistre_app/lib/features/chat/content_direction.dart`), so an English reply inside the Arabic UI reads left to right with its punctuation in place, and an Arabic reply inside the English UI reads right to left; text with no strong character keeps the UI direction.
- Never alter `TextEditingController.text` during active IME composition (`value.composing.isValid`); an edit that has to wait (clearing sent text, restoring a draft) runs as soon as the composition ends. While composing, arrows, Tab, and Enter belong to the IME (the `/` and `@` menu and the command palette ignore them). Never set `enableSuggestions: false` on general text inputs (`flutter#192714`).
- **Text fields** (`QuillInput`): a one-line field always submits on Enter (`TextInputAction.done`); the field itself carries its accessible name (the placeholder unless `semanticsLabel` is given) and the drawn placeholder is hidden from screen readers. The right-click menu uses Flutter's live rules (`TextSelectionHandleControls`): Paste only when the clipboard holds text, no Cut or Copy in a masked field; selected message text gets Copy and Select all. Only messages are selectable; the empty chat page is not.
- **Close buttons are named for what they do**: Dismiss for a notice (toast, banner, error), Close for a panel, dialog, or search bar, Remove for an attached file or queued message; Cancel only cancels an action. A disabled button tints its icon with the muted ink, so it never looks empty.
- **Model field** (`ModelPickerField`): one combobox, no second filter box or Choose button; the list opens under the field, follows the highlight with arrow keys, and closes on Enter, Esc, or a click elsewhere.
- **Renaming a chat**: click the header title; Enter or clicking elsewhere saves, Esc cancels (and never reaches the reply). The box fits the title (up to 420 px) and closes when the chat changes or Settings opens.
- **Esc and stopping a reply** (D3): Esc stops a reply only from the empty composer (not mid-IME, no menu open); from any other field it only closes that field's layer. `Ctrl+.` (rebindable, Shortcuts) and the Stop button stop it from anywhere. A scroll that moves up during a reply stops auto-follow, which resumes only when a scroll ends near the bottom or on Jump to latest.
- **Modals** (`FolioModalBackdrop`): Tab cycles inside the modal, the page behind it is excluded from focus and semantics, and focus returns to where it was when the modal closes.

## 8. Hot-Path UI, Viewport & Low-Memory Invariants
- **Leaf-isolated state**: 16 ms streaming deltas flow into a dedicated leaf `ValueNotifier` (`LiveTurnNotifier`) read only by the active streaming turn inside a `RepaintBoundary`; the shell, header, and sidebar rebuild `0` times per delta. The composer owns its `TextEditingController` (keystrokes never notify the root). Hover, press, focus, and pulse layers animate inside leaf `RepaintBoundary` widgets with `0` parent rebuilds.
- **Viewport & scroll**: the message feed is a full-width `CustomScrollView` (`SliverList.builder`) whose items each center a `ConstrainedBox(maxWidth: readingWidth)`, so the mouse wheel scrolls from the empty page margins; a non-empty chat opens anchored at the bottom; auto-follow pauses immediately on drag or wheel.
- **Code & tools**: code fences soft-wrap by default below `640 px` viewport width, with a global `Wrap code` preference and a per-fence wrap toggle that survives scrolling; fenced `svg` blocks offer an offline `Preview` / `Source` toggle; wide layouts (≥ 720 px effective width) offer a `Split` / `Unified` diff toggle; consecutive read/search tool steps fold into one quiet row; Markdown export skips empty assistant stubs.
- **Composer context gauge**: a compact radial `ContextGaugeRing` (`apps/bistre_app/lib/features/chat/context_gauge_ring.dart`) shows how full the conversation limit is. Every number comes from core (`context_breakdown`, `crates/bistre-core/src/context_breakdown.rs`), counted with the builders a run uses, so it never counts text the model will not see. Tapping it opens What fills this conversation (`context_breakdown_popover.dart`): the share used in the header, one stacked bar, then a row per category with tokens and its percent of the limit (Messages with turn count, Built-in tools, MCP tools, Instructions, Project instructions, Story notes and cards, Attachments, Unsent draft; empty rows hidden), Kept free for shortening, Free space, and below a divider what is not sent (MCP tools on demand, "—" for the percent). The MCP row opens a second page listing each server's tools with their schema size; Esc goes back a page, then closes; the page switch cross-fades and honours Reduce motion. Each row is one labelled screen-reader node. Under 600 logical px (phones, large text) the ring drops its number label and the Thinking chip shows only its level (`Auto`), keeping the full names for screen readers and hover hints.
- **Low-memory mode** (`< 4 GB` RAM or Android `isLowRamDevice`): no overlay drop shadows, streaming redraw capped at `30 fps`, attachment decode `<= 2560 px` off the UI thread, and Skia GPU resource cache capped at `32 MiB` (`48 MiB` on normal hosts via `SystemChannels.skia` `Skia.setResourceCacheMaxBytes`).

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
- **Header (one bar)**: leading sidebar toggle → chat title (click to rename) with `model on Provider ▾` as an interactive subtitle beneath it → trailing Chat Notes & Memory, New chat, on-demand Studio pane (when active), and Settings. Slim update/status banners reveal directly below the header when needed; centered top floating pill toasts announce connection checks, copy, pin, and undo notices. Open chats show as tabs under the header. Every icon has a hover hint.
- **Message**: messenger bubbles by default: yours a tinted pill on the trailing side; replies a hairline-bordered card. Model name and time sit above the bubble, with a collapsed `Thinking` toggle on the trailing edge and collapsible Agent Step Checklists (`Worked for Xs — N/N steps`). Actions reveal on hover or keyboard focus (`Copy`, `Regenerate`/`Edit`, and expandable inline `More` for reply/pin/context start/turn details/delete); a trailing `MessageNavRail` with `Message Map (N/N)` supports fast long-thread navigation. Per-turn usage pills show input, reused/saved cache, thinking, output, TTFT, duration, tok/s, and exact cost.
- **Code card**: `language (N lines)` on the leading edge; optional SVG `Preview`/`Source` toggle plus wrap, fold, download, and copy as equal icon buttons on the trailing edge.
- **Composer**: the only elevated surface on the page; placeholder `Message <assistant>...`. Bottom row: Attach, `Tools` popover (Mode `Chat/Plan/Build/Write`, 4 Tool permission presets `Off/Strict/Balanced/Sandbox`, native OS `Choose folder...`, Web search, reply prefill), `Thinking` level (smooth VSYNC slider + `Adaptive`/`Automatic` + custom effort), `Draft saved`, the labelled conversation-limit ring, and a quiet `Send` on the trailing side. Typing `@` or `/` opens a vertical keyboard-navigable menu with live mounted files, `@mount`, slash commands, and installed skills; while it is open, Enter picks the highlighted entry (it never sends `/plan` as a message). Text typed while a reply streams is never cleared. The draft follows the text: after Send or a command the saved draft is empty, and the last keystrokes are saved when the app is backgrounded or closed.
- **Empty chat**: one `rubricMark` line, "Start with a question, a draft, or a file.", with the active model beneath it. Without a key, one clean setup card with a single `Set up provider` button (zero hardcoded brand icon strip).
- **Sidebar**: search field with a `+` new-chat button, then `Assistant | Chat | Pinned` (showing both pinned chats and pinned replies); chats grouped by date with assistant subtitles, each row a title and relative time. Only the selected row carries the `rubricMark`; row actions reveal on hover or focus.
