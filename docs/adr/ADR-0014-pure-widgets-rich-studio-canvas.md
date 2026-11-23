# ADR-0014: Pure-Widgets Rich Studio Canvas (Tables, Math, Mermaid, Session Tree & Reasoning)

- **Status**: Accepted
- **Date**: 2026-11-22
- **Deciders**: Bistre Principal Architecture

## Context
Modern AI workbenches must render rich structured outputs—GFM pipe tables, inline & block LaTeX equations, Mermaid architecture diagrams, collapsible extended reasoning traces, structured tool call diffs with inline approvals and 1-click rewind, visual DAG session trees, and multimodal file attachments—without pulling in Material/Cupertino UI kits, WebViews, or bloated third-party Flutter widget libraries (`ADR-0001`).

## Decision
1. **Pure-Dart Rich Renderers on `package:flutter/widgets.dart`**:
   - **GFM Pipe Tables** (`markdown_folio_view.dart`): Horizontally scrollable Sepia-styled tables honoring column alignment (`left`/`center`/`right`) with 1-click **Copy CSV** and **Copy Markdown**.
   - **Native LaTeX Math** (`math_folio_view.dart`): Pure-Dart TeX parser & layout engine rendered directly with bundled offline `NotoSansMath` (fractions, superscripts/subscripts, radicals, Greek symbols, matrices) plus 1-click **Copy LaTeX**.
   - **Native Mermaid Diagrams** (`mermaid_canvas_view.dart`): Pure-Dart parser & Sepia `CustomPainter` supporting `flowchart`/`graph` (TD/LR), `sequenceDiagram`, `stateDiagram`, and `erDiagram` with Source/Diagram toggle and 1-click **Copy Mermaid** (zero WebView/JS runtime).
2. **Reasoning, Tool Timelines & Reversible Compaction**:
   - Collapsible `ReasoningBlock` + `ReasoningEffortSelector` (`off` / `low` / `medium` / `high`) backed by streaming `ThinkingDelta` across all 4 Rust wire dialects.
   - `ToolTimelineView` rendering `imara-diff` unified diffs, inline 4-level Tier-2 approval bar (`Allow once` / `Allow for chat` / `Deny`), and 1-click `Rewind` backed by SQLite `workspace_checkpoints`.
   - Non-destructive `CompactionSummary` DAG cards with `Undo` plus Fixed Context Start Pin (`Pin context start`) cleanly separating prompt projection from canonical history.
3. **Visual DAG Session Tree, 4-Tab Studio Pane & Composer Power Tools**:
   - `SessionTreeOverlay` (`Ctrl+Alt+G` Jump to Earlier Prompt) visualizes the full branching DAG and switches branches in 1 click.
   - Collapsible `328px` Studio Pane (`RunsDockPanel`) unifies `[Runs] [Files] [Story] [Prompt]` with 1-click `"Comment in chat"` (`@file:L1-L20`).
   - Composer supports native OS file attachments (enforcing a 4-image recall window cap), `@` mention popovers, and `/` slash commands.
4. **Strict 10 Ink Primitives Budget Preserved**: All new renderers compose strictly from `ink_primitives.dart` (exact 10 primitives) and 56 offline `.vec` UI icons (`bistre_icons.dart`).

## Rejected Alternatives
- **Embedding a WebView (`webview_flutter`) for KaTeX/Mermaid**: Adds 50–120 MB RSS per webview process, breaks offline determinism, and introduces XSS attack surfaces.
- **Adding Material/third-party markdown packages**: Violates `ADR-0001` and `bistre_forbid_ui_kits`.

## Consequences & Verification
- Delivers zero-WebView, 60/120Hz rich rendering inside the ≤120 MB active RSS budget while maintaining 100% pure-Widgets lint compliance.
- Verified by `just lint-dart` (0 warnings across all 5 `bistre_lints` rules), `bistre_app_test.dart` (Wave B/C rich rendering & tool approval tests), and high-DPI PNG visual inspection via `just ui-gallery`.
