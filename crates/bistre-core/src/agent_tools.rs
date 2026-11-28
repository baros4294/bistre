//! End-to-end agentic tool-calling loop, approval pausing, MCP schema deferral,
//! and output blob spilling (Spec 04 & Spec 06, Wave 2).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, EngineEvent, NodeRecord, NodeRole, ProviderDialect,
    StoredAttachment, ThreadMode, ToolRiskTier, TrustPreset,
};
use bistre_storage::StorageHandle;
use serde_json::{Value, json};
use tokio::sync::broadcast;

pub use crate::agent_approvals::{
    ApprovalKey, ApprovalMemory, MAX_APPROVAL_MEMORY, PendingApprovalMap, ThreadAutoApprovals,
    deliver_tool_approval,
};
pub(crate) use crate::agent_approvals::{
    pre_tool_hook_verdict, run_post_tool_hooks, wait_for_decision,
};
use crate::approval::ToolApprovalBroker;
use crate::engine_runs::{StreamServices, utc_now_unix_ms};
use crate::events::emit_logged;
use crate::mcp::{McpDiscoveredTool, McpServerConfig};
use crate::replay_policy::{StoredToolCall, StoredToolResult};
pub use crate::tool_batch::ToolBatchOutcome;
pub(crate) use crate::tool_batch::execute_tool_batch;
use crate::tools::{
    ReadLedger, ToolExecutionOutput, classify_tool_risk, compute_unified_diff, tool_web_fetch,
    tool_web_search_with_endpoint,
};

/// Spill threshold for persisted tool outputs (`64 KiB`, AGENTS.md §7).
pub const TOOL_OUTPUT_SPILL_BYTES: usize = 64 * 1024;

/// Maximum direct MCP tool schemas exposed before deferring the rest behind `mcp_schema`.
pub const MAX_DIRECT_MCP_TOOLS: usize = 6;
/// Consecutive tool failures that trip the loop safety breaker.
pub const MAX_CONSECUTIVE_TOOL_FAILURES: u32 = 4;

/// Per-tool user permission policy stored in `kv_meta["agent.tool_permissions"]`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolPermission {
    Allow,
    Ask,
    Off,
}

impl ToolPermission {
    fn parse(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "allow" | "auto" | "on" => Self::Allow,
            "off" | "deny" | "disabled" => Self::Off,
            _ => Self::Ask,
        }
    }
}

/// Active tools available for the current run step, ready for wire serialization and dispatch.
#[derive(Debug, Clone)]
pub struct ActiveToolCatalog {
    /// Sorted canonical tool schemas `{ name, description, parameters }`.
    pub canonical_schemas: Vec<Value>,
    /// Lookup from exposed wire tool name -> `(McpServerConfig, remote_tool_name)`.
    pub mcp_dispatch: HashMap<String, (McpServerConfig, String)>,
    /// Deferred MCP schemas (exposed on demand via `mcp_schema` when > 6 MCP tools exist).
    pub deferred_mcp_schemas: HashMap<String, Value>,
    /// Resolved primary workspace root path if a workspace is bound.
    pub workspace_root: Option<PathBuf>,
    /// All bound workspace roots (primary first, followed by secondary folders).
    pub workspace_roots: Vec<PathBuf>,
    /// Per-tool user policy map (`tool_name -> ToolPermission`).
    pub permissions: HashMap<String, ToolPermission>,
    /// Effective trust preset.
    pub trust_preset: TrustPreset,
    /// The permission map could not be read: only Tier-0 reads may run.
    pub policy_unreadable: bool,
    /// Read-only Plan mode: only Tier-0 reads may run, whatever tool the model calls
    /// (opencode #65442: hiding write tools alone let a shell or MCP call through).
    pub read_only: bool,
}

impl Default for ActiveToolCatalog {
    fn default() -> Self {
        Self {
            canonical_schemas: Vec::new(),
            mcp_dispatch: HashMap::new(),
            deferred_mcp_schemas: HashMap::new(),
            workspace_root: None,
            workspace_roots: Vec::new(),
            permissions: HashMap::new(),
            trust_preset: TrustPreset::Off,
            policy_unreadable: false,
            read_only: false,
        }
    }
}

impl ActiveToolCatalog {
    /// Deterministic canonical JSON string used for `ReplayContext::tools_hash` and token counting.
    pub fn canonical_json(&self) -> String {
        if self.canonical_schemas.is_empty() {
            String::new()
        } else {
            Value::Array(self.canonical_schemas.clone()).to_string()
        }
    }

    /// Tokens the sent tool schemas add to a request, counted schema by schema (the context
    /// breakdown's tool rows add up to exactly this).
    pub fn schema_tokens(&self, model: Option<&str>) -> u64 {
        self.canonical_schemas.iter().fold(0_u64, |acc, s| {
            acc.saturating_add(crate::context_breakdown::tool_schema_tokens(s, model))
        })
    }

    /// Formats `canonical_schemas` into the exact wire shape expected by `dialect`.
    pub fn wire_tools_for_dialect(&self, dialect: ProviderDialect) -> Vec<Value> {
        if self.canonical_schemas.is_empty() {
            return Vec::new();
        }
        match dialect {
            ProviderDialect::OpenAi => self
                .canonical_schemas
                .iter()
                .filter_map(|t| {
                    let name = t.get("name")?.as_str()?;
                    let description = t
                        .get("description")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    let parameters = t
                        .get("parameters")
                        .cloned()
                        .unwrap_or_else(|| json!({ "type": "object", "properties": {} }));
                    Some(json!({
                        "type": "function",
                        "name": name,
                        "description": description,
                        "parameters": parameters,
                    }))
                })
                .collect(),
            ProviderDialect::Anthropic => self
                .canonical_schemas
                .iter()
                .filter_map(|t| {
                    let name = t.get("name")?.as_str()?;
                    let description = t
                        .get("description")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    let input_schema = t
                        .get("parameters")
                        .cloned()
                        .unwrap_or_else(|| json!({ "type": "object", "properties": {} }));
                    Some(json!({
                        "name": name,
                        "description": description,
                        "input_schema": input_schema,
                    }))
                })
                .collect(),
            ProviderDialect::GoogleGemini => self
                .canonical_schemas
                .iter()
                .filter_map(|t| {
                    let name = t.get("name")?.as_str()?;
                    let description = t
                        .get("description")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    let parameters = t
                        .get("parameters")
                        .cloned()
                        .unwrap_or_else(|| json!({ "type": "object", "properties": {} }));
                    Some(json!({
                        "type": "function",
                        "name": name,
                        "description": description,
                        "parameters": parameters,
                    }))
                })
                .collect(),
            ProviderDialect::CustomOpenAi => self
                .canonical_schemas
                .iter()
                .filter_map(|t| {
                    let name = t.get("name")?.as_str()?;
                    let description = t
                        .get("description")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    let parameters = t
                        .get("parameters")
                        .cloned()
                        .unwrap_or_else(|| json!({ "type": "object", "properties": {} }));
                    Some(json!({
                        "type": "function",
                        "function": {
                            "name": name,
                            "description": description,
                            "parameters": parameters,
                        }
                    }))
                })
                .collect(),
        }
    }
}

/// The permission a tool answers to: the file tools share the Find files and Edit files
/// settings, so turning one off covers every tool that does the same thing.
pub(crate) fn permission_key(tool_name: &str) -> &str {
    match tool_name {
        "fs_list" => "glob",
        "fs_write" | "fs_multi_edit" | "fs_move" | "fs_delete" => "edit",
        other => other,
    }
}

/// Moving or deleting a file always asks (or uses this chat's grant), even when Edit files is
/// set to Allow; only the Unchained sandbox preset runs it unasked.
pub(crate) fn always_asks(tool_name: &str) -> bool {
    matches!(tool_name, "fs_move" | "fs_delete")
}

fn normalize_tool_permission_key(raw: &str) -> &str {
    match raw {
        "read_file" => "read",
        "edit_file" => "edit",
        "run_shell" => "shell",
        other => other,
    }
}

/// Loads the per-tool permission map. A storage error or a value that is not a JSON object is
/// an error: the caller then blocks every tool except Tier-0 reads, so a tool the user
/// turned off never silently comes back.
fn load_tool_permissions(storage: &StorageHandle) -> BistreResult<HashMap<String, ToolPermission>> {
    let mut out = HashMap::new();
    let Some(raw) = storage.get_kv_meta("agent.tool_permissions")? else {
        return Ok(out);
    };
    if raw.trim().is_empty() {
        return Ok(out);
    }
    let Ok(Value::Object(map)) = serde_json::from_str::<Value>(&raw) else {
        return Err(BistreError::with_detail(
            DiagnosticKey::ToolApprovalRequired,
            "tool_permissions_unreadable",
        ));
    };
    for (k, v) in &map {
        if let Some(s) = v.as_str() {
            let perm = ToolPermission::parse(s);
            out.insert(k.clone(), perm);
            let canonical = normalize_tool_permission_key(k);
            if canonical != k {
                out.insert(canonical.to_owned(), perm);
            }
        }
    }
    Ok(out)
}

/// Tool-call arguments as a JSON object; an empty string means no arguments.
pub(crate) fn parse_tool_arguments(raw: &str) -> Option<Value> {
    if raw.trim().is_empty() {
        return Some(json!({}));
    }
    match serde_json::from_str::<Value>(raw) {
        Ok(v @ Value::Object(_)) => Some(v),
        _ => None,
    }
}
pub(crate) fn load_enabled_mcp_servers(storage: &StorageHandle) -> Vec<McpServerConfig> {
    let Ok(Some(raw)) = storage.get_kv_meta("agent.mcp_servers") else {
        return Vec::new();
    };
    let Ok(servers) = serde_json::from_str::<Vec<McpServerConfig>>(&raw) else {
        return Vec::new();
    };
    servers.into_iter().filter(|s| s.enabled).collect()
}

pub(crate) fn load_cached_mcp_tools(
    storage: &StorageHandle,
    server_id: &str,
) -> Vec<McpDiscoveredTool> {
    let key = format!("mcp.tools_cache:{server_id}");
    let Ok(Some(raw)) = storage.get_kv_meta(&key) else {
        return Vec::new();
    };
    match serde_json::from_str::<Vec<McpDiscoveredTool>>(&raw) {
        Ok(tools) => tools,
        Err(err) => {
            tracing::warn!(%err, server_id, "malformed cached mcp tools json");
            Vec::new()
        }
    }
}

/// Enabled MCP server tools under deterministic names `mcp__<server_id>__<tool_name>`, minus
/// the ones turned off, sorted by name.
fn enabled_mcp_entries(
    storage: &StorageHandle,
    permissions: &HashMap<String, ToolPermission>,
) -> Vec<(String, McpServerConfig, McpDiscoveredTool)> {
    if permissions.get("mcp") == Some(&ToolPermission::Off) {
        return Vec::new();
    }
    let mut mcp_entries: Vec<(String, McpServerConfig, McpDiscoveredTool)> = Vec::new();
    for srv in load_enabled_mcp_servers(storage) {
        let safe_srv: String = srv
            .id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
            .take(24)
            .collect();
        for def in load_cached_mcp_tools(storage, &srv.id) {
            let safe_tool: String = def
                .name
                .chars()
                .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
                .take(36)
                .collect();
            let exposed = format!("mcp__{safe_srv}__{safe_tool}");
            if permissions.get(&exposed) == Some(&ToolPermission::Off) {
                continue;
            }
            mcp_entries.push((exposed, srv.clone(), def));
        }
    }
    mcp_entries.sort_by(|a, b| a.0.cmp(&b.0));
    mcp_entries
}

/// Adds the tools a turn offers from its own chat: `history_search`/`history_open` after a
/// summary, `goal_complete` while the chat has an open goal.
pub(crate) fn offer_turn_tools(
    catalog: &mut ActiveToolCatalog,
    storage: &StorageHandle,
    thread_id: &str,
    mode: ThreadMode,
    history: &[NodeRecord],
) {
    crate::history_recall::offer(catalog, history);
    crate::goal::offer(catalog, storage, thread_id, mode);
}

/// Builds the active tool catalog for a run step from settings, workspace binding,
/// `agent.tool_permissions`, and enabled MCP servers (with automatic `mcp_schema` deferral past 6).
pub fn resolve_active_tool_catalog(
    storage: &StorageHandle,
    thread_id: Option<&str>,
    thread_mode: ThreadMode,
) -> BistreResult<ActiveToolCatalog> {
    let settings = storage.load_settings()?;
    let (permissions, policy_unreadable) = match load_tool_permissions(storage) {
        Ok(map) => (map, false),
        Err(err) => {
            tracing::warn!(
                key = err.key.as_key(),
                detail = err.detail_code.as_deref().unwrap_or_default(),
                "tool permissions unreadable; only read-only tools run"
            );
            (HashMap::new(), true)
        }
    };
    if settings.trust_preset == TrustPreset::Off {
        return Ok(ActiveToolCatalog {
            trust_preset: TrustPreset::Off,
            permissions,
            policy_unreadable,
            ..ActiveToolCatalog::default()
        });
    }

    let workspace_roots = crate::projects::workspace_roots_for(storage, thread_id)?;
    let workspace_root = workspace_roots.first().cloned();
    let has_workspace = workspace_root.is_some();
    let web_search_on = crate::agent_context::resolve_web_search_endpoint(storage)?.is_some();

    let mut schemas = crate::utility_tools::collect_builtin_schemas(
        storage,
        thread_mode,
        has_workspace,
        web_search_on,
        policy_unreadable,
        &permissions,
    );

    let mcp_entries = enabled_mcp_entries(storage, &permissions);

    let mut mcp_dispatch = HashMap::new();
    let mut deferred_mcp_schemas = HashMap::new();
    let defer_excess = mcp_entries.len() > MAX_DIRECT_MCP_TOOLS;
    for (idx, (exposed, srv, def)) in mcp_entries.into_iter().enumerate() {
        mcp_dispatch.insert(exposed.clone(), (srv, def.name.clone()));
        let schema = json!({
            "name": exposed,
            "description": def.description,
            "parameters": def.input_schema,
        });
        if defer_excess && idx >= MAX_DIRECT_MCP_TOOLS {
            deferred_mcp_schemas.insert(exposed, schema);
        } else {
            schemas.push(schema);
        }
    }

    if !deferred_mcp_schemas.is_empty() {
        let mut names: Vec<&str> = deferred_mcp_schemas.keys().map(String::as_str).collect();
        names.sort_unstable();
        schemas.push(json!({
            "name": "mcp_schema",
            "description": format!(
                "Inspect the full parameter schema for deferred MCP tools before calling them. Available deferred tools: {}",
                names.join(", ")
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "tool_name": { "type": "string" }
                },
                "required": ["tool_name"]
            }
        }));
    }

    schemas.sort_by(|a, b| {
        let an = a.get("name").and_then(Value::as_str).unwrap_or("");
        let bn = b.get("name").and_then(Value::as_str).unwrap_or("");
        an.cmp(bn)
    });

    Ok(ActiveToolCatalog {
        canonical_schemas: schemas,
        mcp_dispatch,
        deferred_mcp_schemas,
        workspace_root,
        workspace_roots,
        permissions,
        trust_preset: settings.trust_preset,
        policy_unreadable,
        read_only: thread_mode == ThreadMode::Plan,
    })
}

/// Computes exact `tiktoken` token count for the active tool schemas of a thread.
pub fn exact_active_tools_tokens(
    storage: &StorageHandle,
    thread_mode: ThreadMode,
    model: Option<&str>,
) -> BistreResult<u64> {
    Ok(resolve_active_tool_catalog(storage, None, thread_mode)?.schema_tokens(model))
}

/// [`dispatch_single_tool`]; a `shell` call also streams its output to the timeline while it
/// runs, through a bounded channel the forwarder drains until the command ends.
#[expect(
    clippy::too_many_arguments,
    reason = "Explicit run context for the one tool-dispatch entry point."
)]
pub(crate) async fn dispatch_with_progress(
    storage: &Arc<StorageHandle>,
    services: &StreamServices,
    catalog: &ActiveToolCatalog,
    helper: &crate::delegate::HelperContext<'_>,
    events_tx: &broadcast::Sender<EngineEvent>,
    thread_id: &str,
    run_id: &str,
    call: &StoredToolCall,
    risk: ToolRiskTier,
    args: &Value,
) -> BistreResult<ToolExecutionOutput> {
    if call.name == "agent_delegate" {
        return crate::delegate::run_helpers(
            storage, services, catalog, helper, thread_id, run_id, args,
        )
        .await;
    }
    if call.name != "shell" {
        return dispatch_single_tool(
            storage, services, catalog, thread_id, run_id, &call.name, args, None,
        )
        .await;
    }
    let (tx, rx) = tokio::sync::mpsc::channel(crate::shell_progress::SHELL_PROGRESS_QUEUE);
    let target = crate::shell_progress::ShellProgressTarget {
        events_tx,
        thread_id,
        run_id,
        call_id: &call.call_id,
        risk,
    };
    let (out, ()) = tokio::join!(
        dispatch_single_tool(
            storage,
            services,
            catalog,
            thread_id,
            run_id,
            &call.name,
            args,
            Some(tx),
        ),
        crate::shell_progress::forward_shell_progress(rx, target),
    );
    out
}

#[expect(
    clippy::too_many_lines,
    reason = "Single flat tool-name router dispatching mcp_schema, MCP tools, web tools, and workspace tools."
)]
#[expect(
    clippy::too_many_arguments,
    reason = "Explicit run context plus the optional shell progress channel (P21)."
)]
async fn dispatch_single_tool(
    storage: &Arc<StorageHandle>,
    services: &StreamServices,
    catalog: &ActiveToolCatalog,
    thread_id: &str,
    run_id: &str,
    tool_name: &str,
    args: &Value,
    progress: Option<tokio::sync::mpsc::Sender<Vec<u8>>>,
) -> BistreResult<ToolExecutionOutput> {
    if tool_name == "mcp_schema" {
        let wanted = args
            .get("tool_name")
            .and_then(Value::as_str)
            .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
        let schema = catalog.deferred_mcp_schemas.get(wanted).ok_or_else(|| {
            BistreError::with_detail(DiagnosticKey::StorageNotFound, "unknown_mcp_tool")
        })?;
        return Ok(ToolExecutionOutput {
            tool_name: "mcp_schema".to_owned(),
            risk_tier: ToolRiskTier::Tier0ReadOnly,
            ok: true,
            summary: format!("Loaded schema for {wanted}"),
            output_text: serde_json::to_string_pretty(schema)
                .unwrap_or_else(|_| schema.to_string()),
            diff_text: None,
            checkpoint_id: None,
            duration_ms: 0,
            media_attachments: Vec::new(),
        });
    }

    if let Some((srv, remote_name)) = catalog.mcp_dispatch.get(tool_name) {
        let started = Instant::now();
        let bearer = match services.vault.get(&crate::mcp::bearer_vault_key(&srv.id)) {
            Ok(Some(b)) => match String::from_utf8(b.to_vec()) {
                Ok(s) => Some(s),
                Err(err) => {
                    tracing::warn!(%err, "mcp bearer utf8 decode failed");
                    None
                }
            },
            Ok(None) => None,
            Err(err) => {
                tracing::warn!(key = err.key.as_key(), "mcp bearer lookup failed");
                None
            }
        };
        let out = crate::mcp::call_mcp_tool_rich(
            &services.mcp_http,
            srv,
            bearer.as_deref(),
            remote_name,
            args,
            Some(&services.data_dir),
        )
        .await?;
        return Ok(ToolExecutionOutput {
            tool_name: tool_name.to_owned(),
            risk_tier: ToolRiskTier::Tier2ExternalSideEffect,
            ok: !out.is_error,
            summary: format!("{} ({})", remote_name, srv.name),
            output_text: out.text,
            diff_text: None,
            checkpoint_id: None,
            duration_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(0),
            media_attachments: out.media_attachments,
        });
    }

    match tool_name {
        "web_fetch" => {
            let url = args
                .get("url")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            tool_web_fetch(&services.web, url).await
        }
        "web_search" => {
            let query = args
                .get("query")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let max_results = args
                .get("max_results")
                .and_then(Value::as_u64)
                .and_then(|v| usize::try_from(v).ok())
                .unwrap_or(6);
            let endpoint =
                crate::agent_context::resolve_web_search_endpoint(storage)?.ok_or_else(|| {
                    BistreError::with_detail(DiagnosticKey::InvalidInput, "web_search_off")
                })?;
            tool_web_search_with_endpoint(&services.web, query, max_results, &endpoint).await
        }
        "skill_load" => {
            let roots =
                crate::skill_install::with_app_skills(storage, catalog.workspace_roots.clone());
            let args = args.clone();
            crate::off_worker::blocking(move || crate::agent_context::run_skill_load(&roots, &args))
                .await
        }
        "agent_memory" => crate::agent_context::run_agent_memory(storage, thread_id, args),
        "diff" => {
            let before = args
                .get("before")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let after = args
                .get("after")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let unified = compute_unified_diff(before, after);
            Ok(ToolExecutionOutput {
                tool_name: "diff".to_owned(),
                risk_tier: ToolRiskTier::Tier0ReadOnly,
                ok: true,
                summary: "computed diff".to_owned(),
                output_text: unified.clone(),
                diff_text: Some(unified),
                checkpoint_id: None,
                duration_ms: 0,
                media_attachments: Vec::new(),
            })
        }
        "calc_eval" | "dice_roll" | "todo_write" | "ask_user" => {
            crate::utility_tools::dispatch(storage, thread_id, tool_name, args)
        }
        "history_search" | "history_open" => {
            crate::history_recall::dispatch(storage, thread_id, tool_name, args)
        }
        crate::goal::GOAL_COMPLETE => crate::goal::dispatch(storage, thread_id, args),
        "read" | "edit" | "grep" | "glob" | "shell" | "fs_list" | "fs_write" | "fs_multi_edit"
        | "fs_move" | "fs_delete" => {
            let ws = catalog.workspace_root.as_ref().ok_or_else(|| {
                BistreError::with_detail(DiagnosticKey::StorageNotFound, "no_workspace")
            })?;
            dispatch_workspace_builtin(
                storage,
                &services.read_ledger,
                ws,
                &catalog.workspace_roots,
                thread_id,
                Some(run_id),
                tool_name,
                args,
                progress,
            )
            .await
        }
        _ => Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "unknown_tool",
        )),
    }
}

/// Workspace tools. `shell` is async already; the file tools (`read`, `edit`, `grep`, `glob`)
/// walk and read the disk synchronously, so they run on the blocking pool and a large
/// repository never stalls the async workers.
#[expect(
    clippy::too_many_arguments,
    reason = "Explicit run context plus workspace roots and optional shell progress channel."
)]
async fn dispatch_workspace_builtin(
    storage: &Arc<StorageHandle>,
    read_ledger: &Arc<ReadLedger>,
    root_path: &Path,
    workspace_roots: &[PathBuf],
    thread_id: &str,
    run_id: Option<&str>,
    tool_name: &str,
    args: &Value,
    progress: Option<tokio::sync::mpsc::Sender<Vec<u8>>>,
) -> BistreResult<ToolExecutionOutput> {
    if tool_name == "shell" {
        let cmd = args
            .get("command")
            .and_then(Value::as_str)
            .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
        let timeout_secs = args
            .get("timeout_secs")
            .and_then(Value::as_u64)
            .unwrap_or(60);
        return crate::tools::tool_shell_with_progress(root_path, cmd, timeout_secs, progress)
            .await;
    }
    let storage = Arc::clone(storage);
    let read_ledger = Arc::clone(read_ledger);
    let roots = if workspace_roots.is_empty() {
        vec![root_path.to_path_buf()]
    } else {
        workspace_roots.to_vec()
    };
    let thread = thread_id.to_owned();
    let run = run_id.map(str::to_owned);
    let name = tool_name.to_owned();
    let args = args.clone();
    crate::off_worker::blocking(move || {
        crate::agent_context::run_workspace_file_tool(
            &storage,
            &read_ledger,
            &roots,
            &thread,
            run.as_deref(),
            &name,
            &args,
        )
    })
    .await
}

#[expect(
    clippy::too_many_arguments,
    reason = "Commits one structured paired NodeRole::Tool record with optional diff/checkpoint/media metadata."
)]
pub(crate) fn commit_tool_result_node(
    storage: &StorageHandle,
    events_tx: &broadcast::Sender<EngineEvent>,
    thread_id: &str,
    run_id: &str,
    parent_id: &str,
    call: &StoredToolCall,
    risk_tier: ToolRiskTier,
    output_text: &str,
    is_error: bool,
    media_attachments: Vec<StoredAttachment>,
    diff_text: Option<String>,
    checkpoint_id: Option<String>,
    duration_ms: i64,
) -> String {
    let attachments_val = if media_attachments.is_empty() {
        None
    } else {
        serde_json::to_value(&media_attachments)
            .map_err(|err| tracing::warn!(%err, "tool result attachments not serialized"))
            .ok()
    };
    let result_meta = StoredToolResult {
        call_id: call.call_id.clone(),
        name: call.name.clone(),
        is_error,
        media_attachments,
    };
    let mut meta = json!({
        "run_id": run_id,
        "tool_result": result_meta,
        "risk_tier": risk_tier,
        "duration_ms": duration_ms,
        "recorded_at_ms": utc_now_unix_ms(),
    });
    if let Some(map) = meta.as_object_mut() {
        if let Some(v) = attachments_val {
            map.insert("attachments".to_owned(), v);
        }
        if let Some(diff) = diff_text {
            map.insert("diff_text".to_owned(), Value::String(diff));
        }
        if let Some(cp) = checkpoint_id {
            map.insert("checkpoint_id".to_owned(), Value::String(cp));
        }
    }
    match storage.append_node(
        thread_id.to_owned(),
        Some(parent_id.to_owned()),
        NodeRole::Tool,
        output_text.to_owned(),
        Some(meta.to_string()),
    ) {
        Ok(node) => {
            let next_id = node.id.clone();
            let ev = EngineEvent::NodeCommitted { node };
            emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
            next_id
        }
        Err(err) => {
            tracing::error!(key = err.key.as_key(), "failed to commit NodeRole::Tool");
            parent_id.to_owned()
        }
    }
}

/// Executes a single built-in workspace/web tool call directly (used by `EngineClient::execute_workspace_tool`).
#[expect(
    clippy::too_many_arguments,
    reason = "Explicit immutable handles keep direct tool execution stateless and testable."
)]
pub async fn execute_workspace_tool_direct(
    storage: &Arc<StorageHandle>,
    web: &crate::ssrf::PublicWebTransport,
    read_ledger: &Arc<ReadLedger>,
    broker: &ToolApprovalBroker,
    workspace_root: &str,
    thread_id: &str,
    tool_name: &str,
    args: &Value,
    permit_id: Option<String>,
) -> BistreResult<ToolExecutionOutput> {
    let settings = storage.load_settings()?;
    if settings.trust_preset == TrustPreset::Off {
        return Err(BistreError::with_detail(
            DiagnosticKey::ToolTierBlocked,
            "tools_disabled",
        ));
    }
    let risk = classify_tool_risk(tool_name, args);
    if risk == ToolRiskTier::Tier3Blocked {
        return Err(BistreError::with_detail(
            DiagnosticKey::ToolTierBlocked,
            "tier3_blocked",
        ));
    }
    let auto_approve =
        risk == ToolRiskTier::Tier0ReadOnly && settings.trust_preset != TrustPreset::Strict;
    let permit = if auto_approve {
        broker.issue(thread_id, tool_name, args)
    } else {
        let id = permit_id.ok_or_else(|| {
            BistreError::with_detail(DiagnosticKey::ToolApprovalRequired, "permit_missing")
        })?;
        broker.take_approved(&id)?
    };
    broker.claim(&permit, thread_id, tool_name, args)?;
    let root_path = PathBuf::from(workspace_root);
    match tool_name {
        "web_fetch" => {
            let url = args
                .get("url")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            tool_web_fetch(web, url).await
        }
        "web_search" => {
            let query = args
                .get("query")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let max_results = args
                .get("max_results")
                .and_then(Value::as_u64)
                .and_then(|v| usize::try_from(v).ok())
                .unwrap_or(6);
            let endpoint = crate::agent_context::resolve_web_search_endpoint(storage)?
                .unwrap_or_else(|| "duckduckgo".to_owned());
            tool_web_search_with_endpoint(web, query, max_results, &endpoint).await
        }
        "skill_load" => {
            let roots = crate::skill_install::with_app_skills(storage, vec![root_path]);
            let args = args.clone();
            crate::off_worker::blocking(move || crate::agent_context::run_skill_load(&roots, &args))
                .await
        }
        "agent_memory" => crate::agent_context::run_agent_memory(storage, thread_id, args),
        "diff" => {
            let before = args
                .get("before")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let after = args
                .get("after")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let unified = compute_unified_diff(before, after);
            Ok(ToolExecutionOutput {
                tool_name: "diff".to_owned(),
                risk_tier: ToolRiskTier::Tier0ReadOnly,
                ok: true,
                summary: "computed diff".to_owned(),
                output_text: unified.clone(),
                diff_text: Some(unified),
                checkpoint_id: None,
                duration_ms: 0,
                media_attachments: Vec::new(),
            })
        }
        _ => {
            let mut roots = crate::agent_context::load_workspace_roots(storage);
            if !roots.iter().any(|r| r == &root_path) {
                roots.insert(0, root_path.clone());
            }
            dispatch_workspace_builtin(
                storage,
                read_ledger,
                &root_path,
                &roots,
                thread_id,
                None,
                tool_name,
                args,
                None,
            )
            .await
        }
    }
}

/// Ensures `broker` is invalidated whenever workspace or tool permissions change.
pub fn invalidate_broker_on_policy_change(broker: &ToolApprovalBroker, key: &str) {
    if matches!(
        key,
        "agent.workspace_root"
            | "agent.workspace_folders"
            | "agent.web_search"
            | "agent.tool_permissions"
            | "agent.mcp_servers"
            | "settings.ui_prefs"
    ) {
        broker.invalidate();
    }
}

#[cfg(test)]
#[path = "agent_tools_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "approval_flow_tests.rs"]
mod approval_flow_tests;
