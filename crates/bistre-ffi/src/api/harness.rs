//! Agent-harness FFI entrypoints: tool approval and execution, checkpoints, compaction, context
//! pins, local/MCP servers, key-value metadata, memory, skills, cron, and sub-agent sandboxes.

use flutter_rust_bridge::frb;

use super::{current_engine, FfiNodeRecord};
use crate::dto_mapping::map_node;
use bistre_protocol::DiagnosticKey;

/// Records the user's approval of one exact tool call and returns its one-use permit id.
#[frb]
pub async fn approve_tool_call(
    thread_id: String,
    tool_name: String,
    arguments_json: String,
) -> Result<String, String> {
    let engine = current_engine()?;
    engine
        .approve_tool_call(thread_id, tool_name, arguments_json)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Executes a capability-scoped built-in workspace or web tool and returns a JSON `ToolExecutionOutput`.
/// Non-read-only tools need the `permit_id` returned by `approve_tool_call`.
#[frb]
pub async fn execute_workspace_tool_json(
    workspace_root: String,
    thread_id: String,
    tool_name: String,
    arguments_json: String,
    permit_id: Option<String>,
) -> Result<String, String> {
    let engine = current_engine()?;
    let output = engine
        .execute_workspace_tool(
            workspace_root,
            thread_id,
            tool_name,
            arguments_json,
            permit_id,
        )
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&output).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Rewinds a single file edit cleanly from a persisted SQLite pre-image checkpoint.
#[frb]
pub async fn rewind_checkpoint(
    workspace_root: String,
    checkpoint_id: String,
) -> Result<String, String> {
    let engine = current_engine()?;
    engine
        .rewind_checkpoint(workspace_root, checkpoint_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Lists persisted file-edit pre-image checkpoints for `thread_id` as JSON.
#[frb]
pub async fn list_checkpoints_json(thread_id: String, limit: u32) -> Result<String, String> {
    let engine = current_engine()?;
    let cps = engine
        .list_checkpoints(thread_id, limit)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&cps).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Inserts a reversible `CompactionSummary` DAG node without deleting original history.
#[frb]
pub async fn compact_thread(
    thread_id: String,
    keep_recent_turns: u32,
    custom_summary: Option<String>,
) -> Result<FfiNodeRecord, String> {
    let engine = current_engine()?;
    let node = engine
        .compact_thread(thread_id, keep_recent_turns, custom_summary)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_node(node))
}

/// Reverts a reversible `CompactionSummary` node, restoring 100% of prior verbatim turns.
#[frb]
pub async fn undo_compaction(thread_id: String, compaction_node_id: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .undo_compaction(thread_id, compaction_node_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Pins (or clears with `None`) a Fixed Context Start node for `thread_id`.
#[frb]
pub async fn set_context_start_pin(
    thread_id: String,
    node_id: Option<String>,
) -> Result<Option<String>, String> {
    let engine = current_engine()?;
    engine
        .set_context_start_pin(thread_id, node_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Returns the current Fixed Context Start pin for `thread_id`, if set.
#[frb]
pub async fn get_context_start_pin(thread_id: String) -> Result<Option<String>, String> {
    let engine = current_engine()?;
    engine
        .get_context_start_pin(thread_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Probes loopback Ollama, LM Studio, llama.cpp, and KoboldCPP servers (`$0` local priority).
#[frb]
pub async fn discover_local_servers_json() -> Result<String, String> {
    let engine = current_engine()?;
    let found = engine
        .discover_local_servers()
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&found).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Discovers tools from a Streamable HTTP MCP server (`2026-07-28` primary -> `2025-11-25` fallback).
#[frb]
pub async fn discover_mcp_server_json(server_config_json: String) -> Result<String, String> {
    let engine = current_engine()?;
    let cfg: bistre_core::mcp::McpServerConfig = serde_json::from_str(&server_config_json)
        .map_err(|_| DiagnosticKey::InvalidInput.as_key().to_owned())?;
    let report = engine
        .discover_mcp_server(cfg)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&report).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Invokes a tool on a configured Streamable HTTP MCP server with 256 KiB output capping.
#[frb]
pub async fn call_mcp_tool_json(
    server_config_json: String,
    tool_name: String,
    arguments_json: String,
) -> Result<String, String> {
    let engine = current_engine()?;
    let cfg: bistre_core::mcp::McpServerConfig = serde_json::from_str(&server_config_json)
        .map_err(|_| DiagnosticKey::InvalidInput.as_key().to_owned())?;
    engine
        .call_mcp_tool(cfg, tool_name, arguments_json)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Reads an arbitrary JSON/text configuration key from local SQLite `kv_meta`.
#[frb]
pub async fn get_kv_meta(key: String) -> Result<Option<String>, String> {
    let engine = current_engine()?;
    engine
        .get_kv_meta(key)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Writes an arbitrary JSON/text configuration key into local SQLite `kv_meta`.
#[frb]
pub async fn set_kv_meta(key: String, value: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .set_kv_meta(key, value)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Lists persistent cross-chat SQLite memory entries as JSON.
#[frb]
pub async fn list_memory_entries_json(scope: Option<String>) -> Result<String, String> {
    let engine = current_engine()?;
    let items = engine
        .list_memory_entries(scope)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&items).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Upserts a persistent cross-chat SQLite memory entry and returns it as JSON.
#[frb]
pub async fn upsert_memory_entry_json(
    id: Option<String>,
    scope: String,
    scope_id: String,
    key: String,
    content: String,
    pinned: bool,
) -> Result<String, String> {
    let engine = current_engine()?;
    let item = engine
        .upsert_memory_entry(id, scope, scope_id, key, content, pinned)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&item).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Deletes a persistent memory entry by ID.
#[frb]
pub async fn delete_memory_entry(entry_id: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .delete_memory_entry(entry_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Scans `workspace_root` for progressive-disclosure `SKILL.md` frontmatter entries as JSON.
#[frb]
pub async fn discover_workspace_skills_json(workspace_root: String) -> Result<String, String> {
    let engine = current_engine()?;
    let skills = engine
        .discover_workspace_skills(workspace_root)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&skills).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Loads a specific `SKILL.md` instruction body on demand.
#[frb]
pub async fn load_skill_body(workspace_root: String, skill_path: String) -> Result<String, String> {
    let engine = current_engine()?;
    engine
        .load_skill_body(workspace_root, skill_path)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Lists all scheduled cron/timer automation jobs as JSON.
#[frb]
pub async fn list_cron_jobs_json() -> Result<String, String> {
    let engine = current_engine()?;
    let jobs = engine
        .list_cron_jobs()
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&jobs).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Creates or updates a scheduled cron/timer automation job from JSON and returns the saved JSON.
#[frb]
pub async fn upsert_cron_job_json(job_json: String) -> Result<String, String> {
    let engine = current_engine()?;
    let parsed: bistre_protocol::CronJobRecord = serde_json::from_str(&job_json)
        .map_err(|_| DiagnosticKey::InvalidInput.as_key().to_owned())?;
    let saved = engine
        .upsert_cron_job(parsed)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&saved).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Deletes a scheduled cron/timer automation job by ID.
#[frb]
pub async fn delete_cron_job(job_id: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .delete_cron_job(job_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Prepares an isolated `git worktree` (or copy-sandbox fallback) for a background subagent.
#[frb]
pub async fn prepare_subagent_sandbox_json(workspace_root: String) -> Result<String, String> {
    let engine = current_engine()?;
    let sb = engine
        .prepare_subagent_sandbox(workspace_root)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&sb).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}
