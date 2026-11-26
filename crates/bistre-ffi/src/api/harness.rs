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

/// "Allow once": the chat's next run may send requests whose price is unknown while a spending
/// cap is active (`diag.wallet.price_unknown`).
#[frb]
pub async fn allow_unpriced_once(thread_id: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .allow_unpriced_once(thread_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Validates and saves a provider's custom headers and body fields (JSON objects); an invalid
/// header or body is refused with `diag.provider.headers_invalid` / `diag.provider.body_invalid`.
#[frb]
pub async fn save_provider_overrides(
    provider_id: String,
    headers_json: String,
    body_json: String,
) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .save_provider_overrides(provider_id, headers_json, body_json)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// "Allow once" for the next read-aloud or live-voice request whose price is unknown.
#[frb]
pub async fn allow_unpriced_media_once() -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .allow_unpriced_media_once()
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Responds to a live `ToolApprovalRequested` event paused inside an active agent run.
/// `decision`: `"approve_once"`, `"approve_for_thread"`, `"deny"`, or `"stop"`.
#[frb]
pub async fn respond_tool_approval(
    thread_id: String,
    run_id: String,
    call_id: String,
    decision: String,
) -> Result<bool, String> {
    let engine = current_engine()?;
    let parsed = bistre_protocol::ToolApprovalDecision::parse(&decision);
    engine
        .respond_tool_approval(thread_id, run_id, call_id, parsed)
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
pub async fn list_checkpoints(thread_id: String, limit: u32) -> Result<Vec<FfiCheckpoint>, String> {
    let cps = current_engine()?
        .list_checkpoints(thread_id, limit)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(cps
        .into_iter()
        .map(|c| FfiCheckpoint {
            id: c.id,
            thread_id: c.thread_id,
            file_path: c.file_path,
            before_blake3: c.before_blake3,
            after_blake3: c.after_blake3,
            created_at_ms: c.created_at_ms,
        })
        .collect())
}

/// One file checkpoint in a chat's edit history. The pre-image bytes stay in core: rewinding
/// uses the id, so the list never ships file contents across FFI.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiCheckpoint {
    pub id: String,
    pub thread_id: String,
    pub file_path: String,
    pub before_blake3: String,
    pub after_blake3: String,
    pub created_at_ms: i64,
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
pub async fn list_memory_entries(scope: Option<String>) -> Result<Vec<FfiMemoryEntry>, String> {
    let items = current_engine()?
        .list_memory_entries(scope)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(items.into_iter().map(FfiMemoryEntry::from).collect())
}

/// Persistent cross-chat memory entry (`MemoryEntryRecord`).
#[frb]
#[derive(Debug, Clone)]
pub struct FfiMemoryEntry {
    pub id: String,
    pub scope: String,
    pub scope_id: String,
    pub key: String,
    pub content: String,
    pub source_thread_id: Option<String>,
    pub pinned: bool,
    pub updated_at_ms: i64,
}

impl From<bistre_protocol::MemoryEntryRecord> for FfiMemoryEntry {
    fn from(r: bistre_protocol::MemoryEntryRecord) -> Self {
        Self {
            id: r.id,
            scope: r.scope,
            scope_id: r.scope_id,
            key: r.key,
            content: r.content,
            source_thread_id: r.source_thread_id,
            pinned: r.pinned,
            updated_at_ms: r.updated_at_ms,
        }
    }
}

/// Upserts a persistent cross-chat SQLite memory entry and returns the saved entry.
#[frb]
pub async fn upsert_memory_entry(
    id: Option<String>,
    scope: String,
    scope_id: String,
    key: String,
    content: String,
    pinned: bool,
) -> Result<FfiMemoryEntry, String> {
    let item = current_engine()?
        .upsert_memory_entry(id, scope, scope_id, key, content, pinned)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(item.into())
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
pub async fn list_cron_jobs() -> Result<Vec<FfiCronJob>, String> {
    let jobs = current_engine()?
        .list_cron_jobs()
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(jobs.into_iter().map(FfiCronJob::from).collect())
}

/// Creates or updates a scheduled cron/timer automation job and returns the saved job.
#[frb]
pub async fn upsert_cron_job(job: FfiCronJob) -> Result<FfiCronJob, String> {
    let saved = current_engine()?
        .upsert_cron_job(job.into())
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(saved.into())
}

/// Scheduled automation job (`CronJobRecord`); enums travel as their stable keys.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiCronJob {
    pub id: String,
    pub name: String,
    pub workspace_id: String,
    pub assistant_id: String,
    pub schedule_expr: String,
    pub prompt: String,
    pub mode: String,
    pub unattended_policy: String,
    pub use_worktree: bool,
    pub enabled: bool,
    pub next_run_ms: i64,
    pub last_run_id: Option<String>,
    pub last_status: String,
}

impl From<bistre_protocol::CronJobRecord> for FfiCronJob {
    fn from(r: bistre_protocol::CronJobRecord) -> Self {
        Self {
            id: r.id,
            name: r.name,
            workspace_id: r.workspace_id,
            assistant_id: r.assistant_id,
            schedule_expr: r.schedule_expr,
            prompt: r.prompt,
            mode: r.mode.as_str().to_owned(),
            unattended_policy: r.unattended_policy.as_str().to_owned(),
            use_worktree: r.use_worktree,
            enabled: r.enabled,
            next_run_ms: r.next_run_ms,
            last_run_id: r.last_run_id,
            last_status: r.last_status,
        }
    }
}

impl From<FfiCronJob> for bistre_protocol::CronJobRecord {
    fn from(j: FfiCronJob) -> Self {
        Self {
            id: j.id,
            name: j.name,
            workspace_id: j.workspace_id,
            assistant_id: j.assistant_id,
            schedule_expr: j.schedule_expr,
            prompt: j.prompt,
            mode: bistre_protocol::ThreadMode::parse(&j.mode),
            unattended_policy: bistre_protocol::UnattendedPolicy::parse(&j.unattended_policy),
            use_worktree: j.use_worktree,
            enabled: j.enabled,
            next_run_ms: j.next_run_ms,
            last_run_id: j.last_run_id,
            last_status: j.last_status,
        }
    }
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

/// One hook from `.bistre/hooks.json`, as shown for review.
#[derive(Debug, Clone)]
pub struct FfiWorkspaceHook {
    /// `pre_tool_use`, `post_tool_use`, `run_finished`, or `run_failed`.
    pub event: String,
    pub command: String,
    pub tool_filter: Option<String>,
}

/// The workspace's hooks file, its digest, and whether the user approved exactly this file.
#[derive(Debug, Clone)]
pub struct FfiWorkspaceHooksStatus {
    pub hooks: Vec<FfiWorkspaceHook>,
    pub digest: String,
    pub approved: bool,
}

/// The hooks of `workspace_root` for review; `None` when the folder has no hooks file.
#[frb]
pub async fn workspace_hooks_status(
    workspace_root: String,
) -> Result<Option<FfiWorkspaceHooksStatus>, String> {
    let engine = current_engine()?;
    let status = engine
        .workspace_hooks_status(workspace_root)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(status.map(|s| FfiWorkspaceHooksStatus {
        hooks: s
            .hooks
            .into_iter()
            .map(|h| FfiWorkspaceHook {
                event: match h.event {
                    bistre_core::hooks::HookEventKind::PreToolUse => "pre_tool_use",
                    bistre_core::hooks::HookEventKind::PostToolUse => "post_tool_use",
                    bistre_core::hooks::HookEventKind::RunFinished => "run_finished",
                    bistre_core::hooks::HookEventKind::RunFailed => "run_failed",
                }
                .to_owned(),
                command: h.command,
                tool_filter: h.tool_filter,
            })
            .collect(),
        digest: s.digest,
        approved: s.approved,
    }))
}

/// Approves the hooks file the user reviewed (by its `digest`); a changed file is refused.
#[frb]
pub async fn approve_workspace_hooks(workspace_root: String, digest: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .approve_workspace_hooks(workspace_root, digest)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// One web page a reply used (B2): `http(s)` only, bounded text.
#[derive(Debug, Clone)]
pub struct FfiGroundingSource {
    pub node_id: String,
    pub url: String,
    pub title: String,
    pub cited_text: Option<String>,
}

/// Web sources of every reply in `thread_id`, oldest reply first.
#[frb]
pub async fn list_thread_grounding(thread_id: String) -> Result<Vec<FfiGroundingSource>, String> {
    let engine = current_engine()?;
    let replies = engine
        .list_thread_grounding(thread_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(replies
        .into_iter()
        .flat_map(|reply| {
            let node_id = reply.node_id;
            reply.sources.into_iter().map(move |s| FfiGroundingSource {
                node_id: node_id.clone(),
                url: s.url().to_owned(),
                title: s.title().to_owned(),
                cited_text: s.cited_text().map(str::to_owned),
            })
        })
        .collect())
}
