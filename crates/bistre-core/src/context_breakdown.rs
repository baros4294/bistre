//! What fills the next request (A-SE, the composer's context breakdown), counted with the same
//! builders a run uses: the system prompt and its Write-mode story or workspace instructions
//! from the turn-context builder, the tool catalog schema by schema, the projected history
//! (tool calls and reasoning included, R26), attachments, and the unsent draft. Deferred MCP
//! schemas are listed but not sent. Core owns every number; the app maps each closed
//! [`ContextCategoryKind`] to its own words.

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, ThreadMode};
use bistre_storage::StorageHandle;
use serde_json::Value;

use crate::compaction;

/// Longest per-server and per-tool lists in a breakdown.
const MAX_SERVERS: usize = 64;
const MAX_TOOLS: usize = 512;

/// A row of the breakdown, in display order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContextCategoryKind {
    Messages,
    BuiltInTools,
    McpTools,
    SystemPrompt,
    WorkspaceInstructions,
    Story,
    Attachments,
    Draft,
    /// Deferred MCP schemas: loaded on demand, never part of the total.
    DeferredMcpTools,
}

impl ContextCategoryKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Messages => "messages",
            Self::BuiltInTools => "built_in_tools",
            Self::McpTools => "mcp_tools",
            Self::SystemPrompt => "system_prompt",
            Self::WorkspaceInstructions => "workspace_instructions",
            Self::Story => "story",
            Self::Attachments => "attachments",
            Self::Draft => "draft",
            Self::DeferredMcpTools => "deferred_mcp_tools",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextCategory {
    pub kind: ContextCategoryKind,
    pub tokens: u64,
    /// Turns, attachments, or tools, where a count means something.
    pub count: Option<u32>,
    /// Part of the next request (deferred schemas are not).
    pub sent: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpToolUsage {
    pub name: String,
    pub tokens: u64,
    pub deferred: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpServerUsage {
    pub server_id: String,
    pub label: String,
    pub tools: Vec<McpToolUsage>,
}

/// The whole breakdown; rows with 0 tokens are left out.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ContextBreakdown {
    pub categories: Vec<ContextCategory>,
    /// The model's context window, when known.
    pub limit_tokens: Option<u64>,
    /// The share of the window kept free before an automatic shorten.
    pub reserve_tokens: u64,
    pub mcp: Vec<McpServerUsage>,
    /// More servers or tools existed than the lists hold.
    pub mcp_truncated: bool,
}

impl ContextBreakdown {
    /// Everything the next request sends (draft included, deferred schemas not).
    #[must_use]
    pub fn total_sent(&self) -> u64 {
        self.categories
            .iter()
            .filter(|c| c.sent)
            .fold(0_u64, |acc, c| acc.saturating_add(c.tokens))
    }

    /// Tokens of one category (0 when the row is absent).
    #[must_use]
    pub fn tokens_of(&self, kind: ContextCategoryKind) -> u64 {
        self.categories
            .iter()
            .find(|c| c.kind == kind)
            .map_or(0, |c| c.tokens)
    }
}

/// Tokens one tool schema adds to a request.
pub(crate) fn tool_schema_tokens(schema: &Value, model: Option<&str>) -> u64 {
    compaction::estimate_tokens_for_model(&schema.to_string(), model)
}

fn schema_name(schema: &Value) -> &str {
    schema.get("name").and_then(Value::as_str).unwrap_or("")
}

/// The model a thread's next turn uses: its override, else its assistant's default, else the
/// active model from Settings.
fn model_for(
    thread: &bistre_protocol::ThreadSummary,
    assistant: Option<&bistre_protocol::AssistantRecord>,
    settings: &bistre_protocol::AppSettings,
    global_model: &str,
) -> Option<String> {
    thread
        .model_id_override
        .clone()
        .filter(|m| !m.trim().is_empty())
        .or_else(|| {
            assistant
                .map(|a| a.default_model_id.clone())
                .filter(|m| !m.trim().is_empty())
        })
        // Settings > Default models before the last pick, as the run resolves it.
        .or_else(|| (!global_model.trim().is_empty()).then(|| global_model.trim().to_owned()))
        .or_else(|| {
            let m = settings.active_model_id.clone();
            (!m.trim().is_empty()).then_some(m)
        })
}

/// [`model_for`] read from storage (the story inspector sizes its budget with it).
pub(crate) fn thread_model_id(
    storage: &StorageHandle,
    thread: &bistre_protocol::ThreadSummary,
) -> BistreResult<Option<String>> {
    let settings = storage.load_settings()?;
    let assistant = storage
        .list_assistants()?
        .into_iter()
        .find(|a| a.id == thread.assistant_id);
    let global = crate::provider_prefs::load_default_models(storage).global_model_id;
    Ok(model_for(thread, assistant.as_ref(), &settings, &global))
}

/// Builds the breakdown for the branch ending at `leaf_id`. `limit_for` resolves the model's
/// context window (core's price registry).
pub(crate) fn branch_context_breakdown(
    storage: &StorageHandle,
    data_dir: Option<&std::path::Path>,
    thread_id: &str,
    leaf_id: &str,
    draft: &str,
    limit_for: &dyn Fn(&str) -> Option<u64>,
) -> BistreResult<ContextBreakdown> {
    let thread = storage
        .get_thread(thread_id)?
        .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
    let settings = storage.load_settings()?;
    let assistant = storage
        .list_assistants()?
        .into_iter()
        .find(|a| a.id == thread.assistant_id);
    let base_prompt = match thread.system_prompt_override.clone() {
        Some(prompt) => prompt,
        None => assistant
            .as_ref()
            .map_or_else(String::new, |a| a.system_prompt.clone()),
    };
    let global = crate::provider_prefs::load_default_models(storage).global_model_id;
    let model = model_for(&thread, assistant.as_ref(), &settings, &global);
    let model_ref = model.as_deref();
    let base_prompt =
        crate::engine_runs::with_user_name(base_prompt, &settings.user_display_name, thread.mode);
    // The same builder the run uses: projected history and the effective system prompt.
    let (history, mode, effective_prompt) = crate::engine_runs::load_turn_context(
        storage,
        thread_id,
        leaf_id,
        &base_prompt,
        model_ref.and_then(limit_for),
    )?;
    let system_tokens = compaction::estimate_tokens_for_model(&base_prompt, model_ref);
    let extra_prompt = compaction::estimate_tokens_for_model(&effective_prompt, model_ref)
        .saturating_sub(system_tokens);
    let (story_tokens, workspace_tokens) = match mode {
        ThreadMode::Write => (extra_prompt, 0),
        ThreadMode::Code | ThreadMode::Plan => (0, extra_prompt),
        _ => (0, 0),
    };

    let tools = tool_rows(storage, thread.mode, model_ref)?;
    let (built_in, mcp_sent, deferred) = (tools.built_in, tools.mcp_sent, tools.deferred);

    let mut attachments = (0_u64, 0_u32);
    for node in &history {
        for att in crate::attachments::parse_node_attachments(node.provider_meta_json.as_deref()) {
            let est = data_dir.map_or(512, |dir| {
                crate::attachments::estimate_attachment_tokens(dir, &att)
            });
            attachments = (
                attachments.0.saturating_add(est),
                attachments.1.saturating_add(1),
            );
        }
    }
    let messages = compaction::estimate_branch_tokens_for_model("", &history, model_ref);
    let turns = u32::try_from(history.len()).unwrap_or(u32::MAX);
    let draft_tokens = compaction::estimate_tokens_for_model(draft.trim(), model_ref);

    let rows = [
        (ContextCategoryKind::Messages, messages, Some(turns), true),
        (
            ContextCategoryKind::BuiltInTools,
            built_in.0,
            Some(built_in.1),
            true,
        ),
        (
            ContextCategoryKind::McpTools,
            mcp_sent.0,
            Some(mcp_sent.1),
            true,
        ),
        (ContextCategoryKind::SystemPrompt, system_tokens, None, true),
        (
            ContextCategoryKind::WorkspaceInstructions,
            workspace_tokens,
            None,
            true,
        ),
        (ContextCategoryKind::Story, story_tokens, None, true),
        (
            ContextCategoryKind::Attachments,
            attachments.0,
            Some(attachments.1),
            true,
        ),
        (ContextCategoryKind::Draft, draft_tokens, None, true),
        (
            ContextCategoryKind::DeferredMcpTools,
            deferred.0,
            Some(deferred.1),
            false,
        ),
    ];
    let categories = rows
        .into_iter()
        .filter(|(_, tokens, _, _)| *tokens > 0)
        .map(|(kind, tokens, count, sent)| ContextCategory {
            kind,
            tokens,
            count,
            sent,
        })
        .collect();
    let limit_tokens = model_ref.and_then(limit_for);
    let reserve_tokens = limit_tokens.map_or(0, |limit| {
        limit.saturating_mul(u64::from(compaction::AUTO_COMPACT_RESERVE_PERCENT)) / 100
    });
    Ok(ContextBreakdown {
        categories,
        limit_tokens,
        reserve_tokens,
        mcp: tools.servers,
        mcp_truncated: tools.truncated,
    })
}

/// Token sums (and counts) of the tool rows, plus the per-server MCP list.
struct ToolRows {
    built_in: (u64, u32),
    mcp_sent: (u64, u32),
    deferred: (u64, u32),
    servers: Vec<McpServerUsage>,
    truncated: bool,
}

/// Tools, schema by schema, exactly as the catalog sends them; deferred MCP schemas apart.
fn tool_rows(
    storage: &StorageHandle,
    mode: ThreadMode,
    model: Option<&str>,
) -> BistreResult<ToolRows> {
    let catalog = crate::agent_tools::resolve_active_tool_catalog(storage, mode)?;
    let mut rows = ToolRows {
        built_in: (0, 0),
        mcp_sent: (0, 0),
        deferred: (0, 0),
        servers: Vec::new(),
        truncated: false,
    };
    let mut listed = 0_usize;
    let mut add = |rows: &mut ToolRows, exposed: &str, tokens: u64, deferred: bool| {
        let Some((srv, remote)) = catalog.mcp_dispatch.get(exposed) else {
            return;
        };
        if listed >= MAX_TOOLS {
            rows.truncated = true;
            return;
        }
        let idx = if let Some(i) = rows.servers.iter().position(|s| s.server_id == srv.id) {
            i
        } else {
            if rows.servers.len() >= MAX_SERVERS {
                rows.truncated = true;
                return;
            }
            rows.servers.push(McpServerUsage {
                server_id: srv.id.clone(),
                label: srv.name.clone(),
                tools: Vec::new(),
            });
            rows.servers.len() - 1
        };
        rows.servers[idx].tools.push(McpToolUsage {
            name: remote.clone(),
            tokens,
            deferred,
        });
        listed += 1;
    };
    let bump =
        |acc: (u64, u32), tokens: u64| (acc.0.saturating_add(tokens), acc.1.saturating_add(1));
    for schema in &catalog.canonical_schemas {
        let name = schema_name(schema);
        let tokens = tool_schema_tokens(schema, model);
        if name.starts_with("mcp__") || name == "mcp_schema" {
            rows.mcp_sent = bump(rows.mcp_sent, tokens);
            add(&mut rows, name, tokens, false);
        } else {
            rows.built_in = bump(rows.built_in, tokens);
        }
    }
    let mut deferred_names: Vec<&String> = catalog.deferred_mcp_schemas.keys().collect();
    deferred_names.sort();
    for exposed in deferred_names {
        let tokens = catalog
            .deferred_mcp_schemas
            .get(exposed)
            .map_or(0, |s| tool_schema_tokens(s, model));
        rows.deferred = bump(rows.deferred, tokens);
        add(&mut rows, exposed, tokens, true);
    }
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;
    use bistre_protocol::NodeRole;

    /// The tool rows add up to exactly what a run counts for the same catalog.
    #[test]
    fn tool_rows_sum_to_the_tokens_a_run_sends() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("b.sqlite"))?;
        let ws = dir.path().join("ws");
        std::fs::create_dir_all(&ws)?;
        storage.set_kv_meta(
            "agent.workspace_root".to_owned(),
            ws.to_string_lossy().into_owned(),
        )?;
        let thread = storage.create_thread(None, "t", ThreadMode::Code, None, None)?;
        let user = storage.append_node(
            thread.id.clone(),
            None,
            NodeRole::User,
            "hi".to_owned(),
            None,
        )?;
        let b = branch_context_breakdown(&storage, None, &thread.id, &user.id, "", &|_| None)?;
        let tools = b.tokens_of(ContextCategoryKind::BuiltInTools)
            + b.tokens_of(ContextCategoryKind::McpTools);
        assert!(tools > 0, "a bound workspace exposes the file tools");
        assert_eq!(
            tools,
            crate::agent_tools::exact_active_tools_tokens(&storage, ThreadMode::Code, None)?
        );
        assert_eq!(b.reserve_tokens, 0, "no window known, nothing reserved");
        Ok(())
    }
}
