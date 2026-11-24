//! End-to-end agentic tool-calling loop, approval pausing, MCP schema deferral,
//! and output blob spilling (Spec 04 & Spec 06, Wave 2).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, EngineEvent, NodeRecord, NodeRole, ProviderDialect,
    RunStatus, RunStepKind, StoredAttachment, ThreadMode, ToolApprovalDecision, ToolRiskTier,
    TrustPreset, lock_or_recover,
};
use bistre_storage::{AgentRunUpdate, StorageHandle};
use serde_json::{Value, json};
use tokio::sync::{broadcast, oneshot};
use uuid::Uuid;

use crate::approval::ToolApprovalBroker;
use crate::engine_runs::{StreamServices, utc_now_unix_ms};
use crate::events::{emit, emit_logged, note_write};
use crate::hooks::HookEventKind;
use crate::mcp::{McpDiscoveredTool, McpServerConfig};
use crate::replay_policy::{StoredToolCall, StoredToolResult};
use crate::tools::{
    ReadLedger, ToolExecutionOutput, classify_tool_risk, compute_unified_diff, file_digest,
    tool_edit, tool_glob, tool_grep, tool_read, tool_shell, tool_web_fetch, tool_web_search,
};

/// Spill threshold for persisted tool outputs (`64 KiB`, AGENTS.md §7).
pub const TOOL_OUTPUT_SPILL_BYTES: usize = 64 * 1024;
/// Maximum time a tool call waits for user approval before timing out safely (fail-closed deny).
const APPROVAL_WAIT_TIMEOUT: Duration = Duration::from_secs(300);
/// Maximum direct MCP tool schemas exposed before deferring the rest behind `mcp_schema`.
pub const MAX_DIRECT_MCP_TOOLS: usize = 6;
/// Consecutive tool failures that trip the loop safety breaker.
pub const MAX_CONSECUTIVE_TOOL_FAILURES: u32 = 4;

/// Pending live tool-approval waiters keyed by `call_id`.
pub type PendingApprovalMap = Arc<Mutex<HashMap<String, oneshot::Sender<ToolApprovalDecision>>>>;
/// Thread-scoped auto-approved tool names granted via `ApproveForThread`.
pub type ThreadAutoApprovals = Arc<Mutex<HashSet<(String, String)>>>;

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
    /// Resolved workspace root path if a workspace is bound.
    pub workspace_root: Option<PathBuf>,
    /// Per-tool user policy map (`tool_name -> ToolPermission`).
    pub permissions: HashMap<String, ToolPermission>,
    /// Effective trust preset.
    pub trust_preset: TrustPreset,
}

impl Default for ActiveToolCatalog {
    fn default() -> Self {
        Self {
            canonical_schemas: Vec::new(),
            mcp_dispatch: HashMap::new(),
            deferred_mcp_schemas: HashMap::new(),
            workspace_root: None,
            permissions: HashMap::new(),
            trust_preset: TrustPreset::Off,
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

fn normalize_tool_permission_key(raw: &str) -> &str {
    match raw {
        "read_file" => "read",
        "edit_file" => "edit",
        "run_shell" => "shell",
        other => other,
    }
}

fn load_tool_permissions(storage: &StorageHandle) -> HashMap<String, ToolPermission> {
    let mut out = HashMap::new();
    let Ok(Some(raw)) = storage.get_kv_meta("agent.tool_permissions") else {
        return out;
    };
    let Ok(val) = serde_json::from_str::<Value>(&raw) else {
        return out;
    };
    if let Some(map) = val.as_object() {
        for (k, v) in map {
            if let Some(s) = v.as_str() {
                let perm = ToolPermission::parse(s);
                out.insert(k.clone(), perm);
                let canonical = normalize_tool_permission_key(k);
                if canonical != k {
                    out.insert(canonical.to_owned(), perm);
                }
            }
        }
    }
    out
}

fn load_enabled_mcp_servers(storage: &StorageHandle) -> Vec<McpServerConfig> {
    let Ok(Some(raw)) = storage.get_kv_meta("agent.mcp_servers") else {
        return Vec::new();
    };
    let Ok(servers) = serde_json::from_str::<Vec<McpServerConfig>>(&raw) else {
        return Vec::new();
    };
    servers.into_iter().filter(|s| s.enabled).collect()
}

fn load_cached_mcp_tools(storage: &StorageHandle, server_id: &str) -> Vec<McpDiscoveredTool> {
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

/// Builds the active tool catalog for a run step from settings, workspace binding,
/// `agent.tool_permissions`, and enabled MCP servers (with automatic `mcp_schema` deferral past 6).
pub fn resolve_active_tool_catalog(
    storage: &StorageHandle,
    thread_mode: ThreadMode,
) -> BistreResult<ActiveToolCatalog> {
    let settings = storage.load_settings()?;
    let permissions = load_tool_permissions(storage);
    if settings.trust_preset == TrustPreset::Off {
        return Ok(ActiveToolCatalog {
            trust_preset: TrustPreset::Off,
            permissions,
            ..ActiveToolCatalog::default()
        });
    }

    let workspace_root = storage
        .get_kv_meta("agent.workspace_root")?
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .map(PathBuf::from);
    let has_workspace = workspace_root.is_some();

    let mut schemas = Vec::new();
    // Workspace tools are exposed when a workspace is bound (write tools only outside read-only Plan mode).
    let include_write_tools = has_workspace && thread_mode != ThreadMode::Plan;
    let builtin = crate::tools::builtin_tool_schemas(include_write_tools);
    for tool in builtin {
        let Some(name) = tool.get("name").and_then(Value::as_str) else {
            continue;
        };
        if permissions.get(name) == Some(&ToolPermission::Off) {
            continue;
        }
        let is_web_tool = matches!(name, "web_fetch" | "web_search");
        if is_web_tool {
            let web_flag = storage
                .get_kv_meta("agent.web_tools_enabled")?
                .is_some_and(|v| v == "true" || v == "1");
            let web_enabled = permissions
                .get(name)
                .is_some_and(|p| *p != ToolPermission::Off)
                && (has_workspace || web_flag);
            if !web_enabled {
                continue;
            }
        } else if !has_workspace {
            continue;
        }
        schemas.push(tool);
    }

    // Add enabled MCP server tools with deterministic names `mcp__<server_id>__<tool_name>`.
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
        permissions,
        trust_preset: settings.trust_preset,
    })
}

/// Computes exact `tiktoken` token count for the active tool schemas of a thread.
pub fn exact_active_tools_tokens(
    storage: &StorageHandle,
    thread_mode: ThreadMode,
    model: Option<&str>,
) -> BistreResult<u64> {
    let catalog = resolve_active_tool_catalog(storage, thread_mode)?;
    let canon = catalog.canonical_json();
    if canon.is_empty() {
        Ok(0)
    } else {
        Ok(crate::compaction::estimate_tokens_for_model(&canon, model))
    }
}

/// Delivers a user approval decision to a paused tool call waiter. Returns `true` if a waiter existed.
pub fn deliver_tool_approval(
    pending: &PendingApprovalMap,
    thread_approvals: &ThreadAutoApprovals,
    thread_id: &str,
    call_id: &str,
    decision: ToolApprovalDecision,
    tool_name_hint: Option<&str>,
) -> bool {
    if decision == ToolApprovalDecision::ApproveForThread
        && let Some(tool) = tool_name_hint
    {
        lock_or_recover(thread_approvals, "thread_auto_approvals")
            .insert((thread_id.to_owned(), tool.to_owned()));
    }
    let sender = lock_or_recover(pending, "pending_approvals").remove(call_id);
    match sender {
        Some(tx) => tx.send(decision).is_ok(),
        None => false,
    }
}

/// Spills outputs larger than `TOOL_OUTPUT_SPILL_BYTES` (`64 KiB`) to `<data_dir>/tool_blobs/`
/// and returns a compact inline preview referencing the full blob path.
fn spill_large_output(data_dir: &Path, call_id: &str, text: &str) -> String {
    if text.len() <= TOOL_OUTPUT_SPILL_BYTES {
        return text.to_owned();
    }
    let dir = data_dir.join("tool_blobs");
    let safe_id: String = call_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .take(40)
        .collect();
    let filename = format!("{safe_id}-{}.txt", Uuid::now_v7().simple());
    let dest = dir.join(&filename);
    let wrote = std::fs::create_dir_all(&dir)
        .and_then(|()| std::fs::write(&dest, text.as_bytes()))
        .is_ok();
    let mut cut = 16 * 1024;
    while cut > 0 && !text.is_char_boundary(cut) {
        cut -= 1;
    }
    let preview = &text[..cut];
    if wrote {
        format!(
            "{preview}\n\n[tool output spilled: {} bytes saved to tool_blobs/{filename}]",
            text.len()
        )
    } else {
        format!(
            "{preview}\n\n[tool output truncated at {} of {} bytes]",
            cut,
            text.len()
        )
    }
}

/// Outcome of executing all tool calls emitted in one assistant turn.
#[derive(Debug)]
pub struct ToolBatchOutcome {
    pub last_node_id: String,
    pub any_succeeded: bool,
    pub all_failed: bool,
    pub cancelled: bool,
}

/// Executes every tool call emitted by an assistant turn, enforcing `TrustPreset`,
/// `ToolApprovalBroker` permits, `ReadLedger`, lifecycle hooks, output spilling, and guaranteed
/// `NodeRole::Tool` pairing (even on denial, cancellation, or error).
#[expect(
    clippy::too_many_arguments,
    reason = "Explicit immutable handles keep tool-loop dispatch deterministic and testable."
)]
#[expect(
    clippy::too_many_lines,
    reason = "Linear approval, hook, dispatch, and paired node commit sequence for one tool batch."
)]
pub(crate) async fn execute_tool_batch(
    storage: &Arc<StorageHandle>,
    services: &StreamServices,
    events_tx: &broadcast::Sender<EngineEvent>,
    cancel_flag: &Arc<AtomicBool>,
    catalog: &ActiveToolCatalog,
    thread_id: &str,
    run_id: &str,
    assistant_node_id: &str,
    step_index: &mut u32,
    calls: &[StoredToolCall],
) -> ToolBatchOutcome {
    let mut parent_id = assistant_node_id.to_owned();
    let mut any_succeeded = false;
    let mut all_failed = true;
    let mut cancelled = false;

    for call in calls {
        *step_index = step_index.saturating_add(1);
        let parsed_args: Value =
            serde_json::from_str(&call.arguments_json).unwrap_or_else(|_| json!({}));
        let risk = if call.name == "mcp_schema" {
            ToolRiskTier::Tier0ReadOnly
        } else {
            classify_tool_risk(&call.name, &parsed_args)
        };

        // Fail-closed checks: cancelled, Tier 3, TrustPreset::Off, or explicit tool Off.
        if cancel_flag.load(Ordering::SeqCst) {
            cancelled = true;
            parent_id = commit_tool_result_node(
                storage,
                events_tx,
                thread_id,
                run_id,
                &parent_id,
                call,
                risk,
                "Cancelled by user before tool execution.",
                true,
                Vec::new(),
                None,
                None,
                0,
            );
            continue;
        }
        if risk == ToolRiskTier::Tier3Blocked
            || catalog.trust_preset == TrustPreset::Off
            || catalog.permissions.get(&call.name) == Some(&ToolPermission::Off)
        {
            parent_id = commit_tool_result_node(
                storage,
                events_tx,
                thread_id,
                run_id,
                &parent_id,
                call,
                risk,
                "Tool execution blocked by security policy or trust preset.",
                true,
                Vec::new(),
                None,
                None,
                0,
            );
            continue;
        }

        // Determine whether this call needs interactive user approval.
        let thread_approved =
            lock_or_recover(&services.thread_auto_approvals, "thread_auto_approvals")
                .contains(&(thread_id.to_owned(), call.name.clone()));
        let explicit_perm = catalog.permissions.get(&call.name).copied();
        let auto_approve = match explicit_perm {
            Some(ToolPermission::Allow) => catalog.trust_preset != TrustPreset::Strict,
            Some(ToolPermission::Ask) => thread_approved,
            Some(ToolPermission::Off) => false,
            None => {
                thread_approved
                    || (risk == ToolRiskTier::Tier0ReadOnly
                        && catalog.trust_preset != TrustPreset::Strict)
                    || (risk == ToolRiskTier::Tier1ReversibleEdit
                        && catalog.trust_preset == TrustPreset::UnchainedSandbox)
            }
        };

        let permit = if auto_approve {
            services.broker.issue(thread_id, &call.name, &parsed_args)
        } else {
            // Pause and request explicit user approval via EngineEvent::ToolApprovalRequested.
            let (tx, rx) = oneshot::channel();
            lock_or_recover(&services.pending_approvals, "pending_approvals")
                .insert(call.call_id.clone(), tx);
            note_write(
                "agent_run_waiting_approval",
                storage.update_agent_run(
                    run_id.to_owned(),
                    AgentRunUpdate {
                        status: Some(RunStatus::WaitingApproval),
                        ..AgentRunUpdate::default()
                    },
                ),
            );
            emit_logged(
                storage,
                events_tx,
                Some(thread_id.to_owned()),
                EngineEvent::ToolApprovalRequested {
                    thread_id: thread_id.to_owned(),
                    run_id: run_id.to_owned(),
                    call_id: call.call_id.clone(),
                    tool_name: call.name.clone(),
                    arguments_json: call.arguments_json.clone(),
                    risk_tier: risk,
                },
            );
            let decision = tokio::select! {
                biased;
                () = crate::providers::until_cancelled(cancel_flag) => {
                    cancelled = true;
                    ToolApprovalDecision::Deny
                }
                res = tokio::time::timeout(APPROVAL_WAIT_TIMEOUT, rx) => {
                    match res {
                        Ok(Ok(d)) => d,
                        _ => ToolApprovalDecision::Deny,
                    }
                }
            };
            lock_or_recover(&services.pending_approvals, "pending_approvals").remove(&call.call_id);
            note_write(
                "agent_run_resume_running",
                storage.update_agent_run(
                    run_id.to_owned(),
                    AgentRunUpdate {
                        status: Some(RunStatus::Running),
                        ..AgentRunUpdate::default()
                    },
                ),
            );
            match decision {
                ToolApprovalDecision::ApproveOnce => {
                    if let Ok(p) = services
                        .broker
                        .approve(thread_id, &call.name, &parsed_args)
                        .and_then(|id| services.broker.take_approved(&id))
                    {
                        p
                    } else {
                        parent_id = commit_tool_result_node(
                            storage,
                            events_tx,
                            thread_id,
                            run_id,
                            &parent_id,
                            call,
                            risk,
                            "Tool approval permit could not be issued.",
                            true,
                            Vec::new(),
                            None,
                            None,
                            0,
                        );
                        continue;
                    }
                }
                ToolApprovalDecision::ApproveForThread => {
                    lock_or_recover(&services.thread_auto_approvals, "thread_auto_approvals")
                        .insert((thread_id.to_owned(), call.name.clone()));
                    services.broker.issue(thread_id, &call.name, &parsed_args)
                }
                ToolApprovalDecision::Deny => {
                    let msg = if cancelled {
                        "Cancelled by user while awaiting approval."
                    } else {
                        "Tool execution denied by user."
                    };
                    parent_id = commit_tool_result_node(
                        storage,
                        events_tx,
                        thread_id,
                        run_id,
                        &parent_id,
                        call,
                        risk,
                        msg,
                        true,
                        Vec::new(),
                        None,
                        None,
                        0,
                    );
                    continue;
                }
            }
        };

        // Claim the one-use, argument-bound permit immediately before dispatch.
        if let Err(err) = services
            .broker
            .claim(&permit, thread_id, &call.name, &parsed_args)
        {
            parent_id = commit_tool_result_node(
                storage,
                events_tx,
                thread_id,
                run_id,
                &parent_id,
                call,
                risk,
                &format!("Approval permit rejected: {err}"),
                true,
                Vec::new(),
                None,
                None,
                0,
            );
            continue;
        }

        // Emit live running status to the UI ToolTimelineView.
        emit(
            events_tx,
            EngineEvent::ToolExecutionUpdated {
                thread_id: thread_id.to_owned(),
                run_id: run_id.to_owned(),
                call_id: call.call_id.clone(),
                tool_name: call.name.clone(),
                risk_tier: risk,
                status: "running".to_owned(),
                summary: format!("Running {}", call.name),
                output_text: String::new(),
                diff_text: None,
                checkpoint_id: None,
                duration_ms: 0,
            },
        );
        let step_rec = note_write(
            "run_step_tool_call",
            storage.record_run_step(
                run_id.to_owned(),
                *step_index,
                RunStepKind::ToolCall,
                call.name.clone(),
                risk,
                format!("{run_id}:tool:{}", call.call_id),
                "running".to_owned(),
                call.arguments_json.clone(),
                "{}".to_owned(),
                0,
                None,
            ),
        );

        let started = Instant::now();
        // Run pre-tool lifecycle hooks if a workspace is bound.
        if let Some(ws) = &catalog.workspace_root {
            let _hook_reports =
                crate::hooks::run_lifecycle_hooks(ws, HookEventKind::PreToolUse, Some(&call.name))
                    .await;
        }

        let exec_res = tokio::select! {
            biased;
            () = crate::providers::until_cancelled(cancel_flag) => {
                cancelled = true;
                Err(BistreError::with_detail(DiagnosticKey::ProviderStreamInterrupted, "cancelled"))
            }
            r = dispatch_single_tool(
                storage,
                services,
                catalog,
                thread_id,
                run_id,
                &call.name,
                &parsed_args,
            ) => r,
        };
        let duration_ms = i64::try_from(started.elapsed().as_millis()).unwrap_or(0);

        match exec_res {
            Ok(out) => {
                let spilled =
                    spill_large_output(&services.data_dir, &call.call_id, &out.output_text);
                if out.ok {
                    any_succeeded = true;
                    all_failed = false;
                }
                if let Some(ws) = &catalog.workspace_root {
                    let _post = crate::hooks::run_lifecycle_hooks(
                        ws,
                        HookEventKind::PostToolUse,
                        Some(&call.name),
                    )
                    .await;
                }
                if let Some(ref st) = step_rec {
                    note_write(
                        "run_step_tool_complete",
                        storage.complete_run_step(
                            st.id.clone(),
                            if out.ok { "completed" } else { "failed" }.to_owned(),
                            json!({ "summary": out.summary, "ok": out.ok }).to_string(),
                            duration_ms,
                        ),
                    );
                }
                emit(
                    events_tx,
                    EngineEvent::ToolExecutionUpdated {
                        thread_id: thread_id.to_owned(),
                        run_id: run_id.to_owned(),
                        call_id: call.call_id.clone(),
                        tool_name: call.name.clone(),
                        risk_tier: out.risk_tier,
                        status: if out.ok { "completed" } else { "failed" }.to_owned(),
                        summary: out.summary.clone(),
                        output_text: spilled.clone(),
                        diff_text: out.diff_text.clone(),
                        checkpoint_id: out.checkpoint_id.clone(),
                        duration_ms,
                    },
                );
                parent_id = commit_tool_result_node(
                    storage,
                    events_tx,
                    thread_id,
                    run_id,
                    &parent_id,
                    call,
                    out.risk_tier,
                    &spilled,
                    !out.ok,
                    out.media_attachments,
                    out.diff_text,
                    out.checkpoint_id,
                    duration_ms,
                );
            }
            Err(err) => {
                let err_text = format!("Tool `{}` failed: {err}", call.name);
                if let Some(ref st) = step_rec {
                    note_write(
                        "run_step_tool_failed",
                        storage.complete_run_step(
                            st.id.clone(),
                            "failed".to_owned(),
                            json!({ "error": err.key.as_key(), "detail": err.detail_code })
                                .to_string(),
                            duration_ms,
                        ),
                    );
                }
                emit(
                    events_tx,
                    EngineEvent::ToolExecutionUpdated {
                        thread_id: thread_id.to_owned(),
                        run_id: run_id.to_owned(),
                        call_id: call.call_id.clone(),
                        tool_name: call.name.clone(),
                        risk_tier: risk,
                        status: "failed".to_owned(),
                        summary: err_text.clone(),
                        output_text: err_text.clone(),
                        diff_text: None,
                        checkpoint_id: None,
                        duration_ms,
                    },
                );
                parent_id = commit_tool_result_node(
                    storage,
                    events_tx,
                    thread_id,
                    run_id,
                    &parent_id,
                    call,
                    risk,
                    &err_text,
                    true,
                    Vec::new(),
                    None,
                    None,
                    duration_ms,
                );
            }
        }
    }

    ToolBatchOutcome {
        last_node_id: parent_id,
        any_succeeded,
        all_failed: !calls.is_empty() && all_failed,
        cancelled,
    }
}

#[expect(
    clippy::too_many_lines,
    reason = "Single flat tool-name router dispatching mcp_schema, MCP tools, web tools, and workspace tools."
)]
async fn dispatch_single_tool(
    storage: &Arc<StorageHandle>,
    services: &StreamServices,
    catalog: &ActiveToolCatalog,
    thread_id: &str,
    run_id: &str,
    tool_name: &str,
    args: &Value,
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
        let bearer = match services.vault.get(&format!("mcp_bearer:{}", srv.id)) {
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
            tool_web_search(&services.web, query, max_results).await
        }
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
        "read" | "edit" | "grep" | "glob" | "shell" => {
            let ws = catalog.workspace_root.as_ref().ok_or_else(|| {
                BistreError::with_detail(DiagnosticKey::StorageNotFound, "no_workspace")
            })?;
            dispatch_workspace_builtin(
                storage,
                &services.read_ledger,
                ws,
                thread_id,
                Some(run_id),
                tool_name,
                args,
            )
            .await
        }
        _ => Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "unknown_tool",
        )),
    }
}

async fn dispatch_workspace_builtin(
    storage: &StorageHandle,
    read_ledger: &ReadLedger,
    root_path: &Path,
    thread_id: &str,
    run_id: Option<&str>,
    tool_name: &str,
    args: &Value,
) -> BistreResult<ToolExecutionOutput> {
    match tool_name {
        "read" => {
            let rel = args
                .get("path")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let start = args
                .get("start_line")
                .and_then(Value::as_u64)
                .and_then(|v| usize::try_from(v).ok());
            let end = args
                .get("end_line")
                .and_then(Value::as_u64)
                .and_then(|v| usize::try_from(v).ok());
            let out = tool_read(root_path, rel, start, end)?;
            if let Ok(digest) = file_digest(root_path, rel) {
                read_ledger.record(thread_id, rel, &digest);
            }
            Ok(out)
        }
        "edit" => {
            let rel = args
                .get("path")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let target = args
                .get("target")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let replacement = args
                .get("replacement")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let expected_hash = args.get("expected_hash").and_then(Value::as_str);
            let current = file_digest(root_path, rel)?;
            read_ledger.check_fresh(thread_id, rel, &current)?;
            let out = tool_edit(
                storage,
                root_path,
                thread_id,
                run_id,
                rel,
                target,
                replacement,
                expected_hash,
            )?;
            if let Ok(digest) = file_digest(root_path, rel) {
                read_ledger.record(thread_id, rel, &digest);
            }
            Ok(out)
        }
        "grep" => {
            let pattern = args
                .get("pattern")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let subpath = args.get("subpath").and_then(Value::as_str);
            tool_grep(root_path, pattern, subpath)
        }
        "glob" => {
            let pattern = args
                .get("pattern")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            tool_glob(root_path, pattern)
        }
        "shell" => {
            let cmd = args
                .get("command")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let timeout_secs = args
                .get("timeout_secs")
                .and_then(Value::as_u64)
                .unwrap_or(60);
            tool_shell(root_path, cmd, timeout_secs).await
        }
        _ => Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "unknown_tool",
        )),
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "Commits one structured paired NodeRole::Tool record with optional diff/checkpoint/media metadata."
)]
fn commit_tool_result_node(
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
        serde_json::to_value(&media_attachments).ok()
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
    storage: &StorageHandle,
    web: &crate::ssrf::PublicWebTransport,
    read_ledger: &ReadLedger,
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
            tool_web_search(web, query, max_results).await
        }
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
            dispatch_workspace_builtin(
                storage,
                read_ledger,
                &root_path,
                thread_id,
                None,
                tool_name,
                args,
            )
            .await
        }
    }
}

/// Ensures `broker` is invalidated whenever workspace or tool permissions change.
pub fn invalidate_broker_on_policy_change(broker: &ToolApprovalBroker, key: &str) {
    if matches!(
        key,
        "agent.workspace_root" | "agent.tool_permissions" | "agent.mcp_servers"
    ) {
        broker.invalidate();
    }
}

/// Returns `true` if `history` ends with a `NodeRole::Tool` node (meaning we are mid-tool-loop).
pub fn is_continuing_tool_turn(history: &[NodeRecord]) -> bool {
    history.last().is_some_and(|n| n.role == NodeRole::Tool)
}

#[cfg(test)]
#[path = "agent_tools_tests.rs"]
mod tests;
