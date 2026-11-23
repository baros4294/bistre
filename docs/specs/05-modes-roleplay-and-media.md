# Spec 05 — Core Modes, Roleplay, Lorebooks, Skills & AIO Media/Voice

## 1. Core Modes
Every thread declares a `ThreadMode` (`chat`, `plan`, `code`/`build`, `write`, `translate`) controlling default prompt framing, active tools, and UI affordances:
- **Chat**: Multi-provider conversation, attachments (4-image recall cap), inline branching, visual DAG Session Tree, FTS5 search, GFM tables, `NotoSansMath` LaTeX, and Mermaid diagrams.
- **Plan / Build (Code)**: Workspace binding, in-process Rust tools, hash-anchored edits with `imara-diff` & 1-tap rewind, `rmcp` MCP tools, worktree sub-agents, lifecycle hooks, and Studio `[Runs]`/`[Files]` panes.
- **Write (Unified Roleplay & Long-Form Fiction Studio — `ADR-0015`)**:
  - **Character Cards & Personas**: Native pure-Rust **CCv3 / V2 PNG (`ccv3`/`chara` `tEXt` + CRC-32), JSON, and `.charx` ZIP** importer/exporter (Zip Slip & 16 MiB cap hardened), User Personas, Turn-0 Alternate Greeting `< Opening 1 / N >` switcher, Group Scenes (`natural` / `round_robin` / `manual` turn router), `Continue`, `Draft my reply` (`Impersonate`), and Time Machine revision rollback (`story_snapshots`).
  - **Long-Form Manuscript Canvas**: Toggleable `Chat | Manuscript` view with Chapter & Scene tree, **Scene Outline & Beats → Write prose from beats**, inline word count, **Inline Rewrite Laser Tools** (`Rewrite` / `Expand` / `Shorten` / `Polish`), Two-Phase Prewriter, and Background Continuity Librarian editable Era Summaries.
  - **Creative Samplers & Safe Linear-Time Regex**: Integer milli-unit sampler controls (`min_p`, `top_k`, `repetition_penalty`, `DRY`, `XTC`, banned phrases), safe linear-time Rust `regex` pipeline (`display_only` / `prompt_outgoing` / `incoming_commit`, zero ReDoS, zero HTML/CSS/JS DOM injection), and pure-Widgets Sepia `TextSpan` dialogue/action styling.
- **Inline Translation**: Side-by-side source/target mode with glossary preservation and terminology consistency.

## 2. Unified Story Bible, Lorebook V3, Chronological Progressions & Live Prompt Inspector
- **Lorebook V3 Safety Invariants (`crates/bistre-core/src/story/lorebook.rs`)**: Primary & secondary keys (`and_any` / `and_all` / `not_any` / `not_all`), linear-time `regex`, cycle-safe recursion (`max_recursion_depth = 3` + visited set), hard token budget cap (`<= 25%` of active context window), CCv3 `@@` / `@@@` fallback decorators, sticky/cooldown/delay turn timers, and **Chronological Progressions** strictly gated by `chapter_order <= current_chapter_order` (zero future spoilers).
- **Prompt-Cache Prefix Boundary & Live Prompt Inspector (`crates/bistre-core/src/story/prompt_assembler.rs`)**: Static prefix blocks (System Prompt, Characters, Persona, Story Memory, Continuity Era Summaries) stay strictly ahead of `cache_boundary_index`, while volatile Lorebook triggers, floating Author's Note (`@D`), and Active Scene Beats inject strictly after the boundary. The Studio `[Prompt]` tab displays live token bars, expandable prompt blocks, the highlighted Cache Boundary divider, and every Lorebook entry's fired/skipped reason.
- **`SKILL.md` Skills**: Discovered from workspace and user skill directories (`crates/bistre-core/src/skills.rs`); YAML frontmatter (`name`, `description`) indexed at startup with zero prompt bloat and bodies loaded on demand.

## 3. Wave 2 & Wave 3 AIO Media & Voice Architecture (Day-1 Abstractions)
- **Async Media Jobs (Wave 2 Image / Wave 3 Video)**: Schema-driven OpenAPI form generation, WAL-before-POST durable job ledger, status polling / webhook delivery, local artifact cache, and Wallet Shield pre-authorization gate.
- **Voice & Fireside Full-Duplex (Wave 2 STT/TTS / Wave 3 Duplex)**:
  - Android: `AudioManager.setCommunicationDevice()` + `OnCommunicationDeviceChangedListener` (API 31+, replacing deprecated `startBluetoothSco()`), BLE Audio support, Oboe low-latency duplex stream, `AcousticEchoCanceler` + WebRTC APM software AEC3 fallback + Silero VAD barge-in gate, run-scoped `FOREGROUND_SERVICE_MICROPHONE`.
  - Desktop: `cpal` audio I/O + WebRTC APM AEC3 + Silero VAD.
