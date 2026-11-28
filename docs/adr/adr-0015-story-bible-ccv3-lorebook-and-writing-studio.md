# ADR-0015: Unified Story Bible, CCv3 Lorebook V3, Long-Form Manuscript & Safe Regex Studio

- Status: Accepted
- Deciders: Bistre Principal Architecture

## Context
Users writing long-form fiction or running rich roleplay sessions currently split workflows across disconnected tools: one app for Character Cards (`CCv3`/V2 PNG/`.charx`), Lorebook V3 keyword triggers, alt-greetings, and samplers, and another for chapter/scene outlines, scene beats → prose generation, chronological character updates without future spoilers, and live prompt cache inspection. Meanwhile, HTML/JS regex scripts in legacy roleplay frontends introduce severe XSS and catastrophic backtracking (`ReDoS`) vulnerabilities.

## Decision
1. Schema v7 Additive Story Studio Tables (`bistre-storage/src/story.rs`): Add 10 Expand-Contract tables (`character_cards`, `user_personas`, `story_books`, `story_entries`, `story_progressions`, `story_chapters`, `story_scenes`, `story_thread_state`, `regex_rules`, `story_snapshots`) with automatic Time Machine revision snapshots on card/entry/scene updates.
2. Pure-Rust Native Card I/O, Lorebook V3 & Cache-Preserving Assembler (`bistre-core/src/story/`):
   - `card_io.rs`: Native CCv3/V2 PNG `tEXt` (`ccv3`/`chara` with IEEE CRC-32), JSON, and `.charx` ZIP import/export with strict Zip Slip path-traversal blocking and 16 MiB decompression cap.
   - `lorebook.rs`: Unified Codex + Lorebook V3 engine supporting primary/secondary keys, linear-time `regex`, cycle-safe recursion (`max_depth = 3`), hard ≤ 25% token budget, CCv3 `@@`/`@@@` decorators, sticky/cooldown/delay, chronological progressions strictly gated by `chapter_order <= current_chapter_order` (zero future spoilers), and full transparent `LoreEvalResult.trace`.
   - `prompt_assembler.rs`: Strictly enforces a Prompt-Cache Prefix Boundary (`cache_boundary_index`) separating static cached prefix (System Prompt, Characters, Persona, Story Memory, Continuity Librarian Era Summaries) from dynamic volatile suffix (Triggered Lorebook entries, floating Author's Note `@D`, Active Scene Beats), wired directly into live `ThreadMode::Write` LLM streaming.
   - `writer_agents.rs`: Two-Phase Prewriter, Background Continuity Librarian, Group Scene Turn Router (`natural` / `round_robin` / `manual`), Continue, Impersonate, and Inline Rewrite Laser Tools (`rewrite` / `expand` / `shorten` / `polish`).
3. Linear-Time Regex + Safe Pure-Widgets Dialogue Styling (`regex_pipeline.rs`):
   - All user regex transforms execute exclusively via Rust's linear-time `regex` DFA/NFA engine (`display_only` | `prompt_outgoing` | `incoming_commit`): mathematically immune to backtracking `ReDoS` and zero HTML/CSS/JS DOM injection.
   - Editorial dialogue (`"..."`) & action (`*...*`) emphasis renders purely via native Flutter `TextSpan` styling in `MarkdownFolioView`.
4. Integrated Write-Mode Studio UI (`apps/bistre_app/lib/features/story/`):
   - `StoryBiblePanel` (Studio `[Story]` tab), `PromptInspectorPanel` (Studio `[Prompt]` tab visualizing Cache Boundary & Lorebook Trigger Log), `RoleplayControlsBar` (`Chat | Manuscript`, Turn-0 Alt-Greetings, `Continue`, `Draft my reply`, Creative Samplers & Phrase Bans, Dialogue Styling), and `ManuscriptCanvas` (Chapters/Scenes, Beats → Prose, Inline Rewrite Laser Tools).

## Rejected Alternatives
- Evaluating JavaScript / HTML CSS macros from character cards: Unacceptable XSS, layout corruption, and WebView bloat risks.
- Injecting dynamic Lorebook triggers before the system prompt or story memory: Invalidates provider prompt caches on every turn, multiplying latency and API cost.
- Unrestricted backtracking regex engines (PCRE/JS): Vulnerable to ReDoS hangs on adversarial community cards.

## Consequences & Verification
- Unifies Roleplay and Long-Form Fiction inside Bistre's local-first SQLite WAL + pure-Widgets Sepia Book aesthetic with zero security regressions and intact prompt caching.
- Verified across 6 dedicated Rust unit tests (`card_io`, `lorebook`, `prompt_assembler`, `regex_pipeline`, `writer_agents`, `schema_v7`), live Rust↔Flutter FRB E2E (`ffi_roundtrip_test.dart`), writing-studio widget tests (`bistre_app_test.dart`), and visual gallery PNG captures.
