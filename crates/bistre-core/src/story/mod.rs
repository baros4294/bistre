//! Writing & Roleplay Studio pure-Rust engine.
//!
//! Combines CCv3/V2 PNG/JSON/`.charx` card I/O, unified Story Bible (Codex) + Lorebook V3
//! with Chronological Progressions, cache-preserving Prompt Assembly + Live Inspector,
//! linear-time safe Regex transforms, and optional Prewriter / Continuity Librarian / Group Router.

pub mod card_io;
pub mod lorebook;
pub mod prompt_assembler;
pub mod regex_pipeline;
pub mod writer_agents;
