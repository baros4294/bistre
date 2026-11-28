//! Agent workspace context injection (`AGENTS.md` / `CLAUDE.md`, skills index, saved memory),
//! multiple workspace roots, web-search endpoint resolution, and harness tools (`skill_load`,
//! `agent_memory`).

use std::path::{Path, PathBuf};

use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, ThreadMode, ToolRiskTier, TrustPreset,
};
use bistre_storage::StorageHandle;
use serde_json::{Value, json};

use crate::skills;
use crate::tools::{
    ReadLedger, ToolExecutionOutput, file_digest, tool_edit, tool_glob, tool_grep, tool_read,
};

const MAX_WORKSPACE_INSTRUCTIONS_BYTES: usize = 16 * 1024;
const MAX_SKILLS_INDEX_BYTES: usize = 4 * 1024;
const MAX_SAVED_MEMORY_BYTES: usize = 8 * 1024;

/// Loads all configured workspace roots (`agent.workspace_folders`, ensuring `agent.workspace_root`
/// is first when set). Deduplicates by path string.
pub(crate) fn load_workspace_roots(storage: &StorageHandle) -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = Vec::new();
    let mut push_unique = |raw: &str| {
        let clean = raw.trim();
        if clean.is_empty() {
            return;
        }
        let pb = PathBuf::from(clean);
        if !roots.iter().any(|r| r == &pb) {
            roots.push(pb);
        }
    };
    if let Ok(Some(primary)) = storage.get_kv_meta("agent.workspace_root") {
        push_unique(&primary);
    }
    if let Ok(Some(raw_list)) = storage.get_kv_meta("agent.workspace_folders")
        && let Ok(Value::Array(items)) = serde_json::from_str::<Value>(&raw_list)
    {
        for item in items {
            if let Some(s) = item.as_str() {
                push_unique(s);
            }
        }
    }
    roots
}

/// Resolves the target workspace root and relative path for a workspace file tool when
/// multiple folders are mounted. If `rel_path` starts with `<root_name>/` matching a secondary
/// root's folder name, routes inside that root; otherwise uses the primary root.
pub(crate) fn resolve_root_and_path<'a>(
    roots: &'a [PathBuf],
    raw_path: &'a str,
) -> Option<(&'a Path, &'a str)> {
    let primary = roots.first()?;
    let trimmed = raw_path.trim().trim_start_matches("./");
    if roots.len() > 1
        && let Some((head, tail)) = trimmed.split_once(['/', '\\'])
        && !tail.is_empty()
    {
        for root in &roots[1..] {
            if root
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|name| name == head)
            {
                return Some((root.as_path(), tail));
            }
        }
    }
    Some((primary.as_path(), raw_path))
}

/// Resolves the active web-search setting from `kv_meta["agent.web_search"]`.
/// Returns `None` when web search is explicitly turned off (`""`), or `Some(endpoint)`
/// (`"duckduckgo"` or a custom `http(s)` URL).
pub(crate) fn resolve_web_search_endpoint(storage: &StorageHandle) -> BistreResult<Option<String>> {
    if let Some(raw) = storage.get_kv_meta("agent.web_search")? {
        let clean = raw.trim();
        return Ok((!clean.is_empty()).then(|| clean.to_owned()));
    }
    // Legacy key fallback when `agent.web_search` has never been saved.
    let legacy = storage
        .get_kv_meta("agent.web_tools_enabled")?
        .is_some_and(|v| v == "true" || v == "1");
    Ok(legacy.then(|| "duckduckgo".to_owned()))
}

/// Builds the full search URL for `endpoint` (`"duckduckgo"` or custom `http(s)` URL) with
/// percent-encoded `encoded_query`.
pub(crate) fn build_web_search_url(endpoint: &str, encoded_query: &str) -> BistreResult<String> {
    let clean = endpoint.trim();
    if clean.is_empty() || clean.eq_ignore_ascii_case("duckduckgo") {
        return Ok(format!(
            "https://html.duckduckgo.com/html/?q={encoded_query}"
        ));
    }
    let parsed = reqwest::Url::parse(clean).map_err(|_| {
        BistreError::with_detail(DiagnosticKey::InvalidInput, "invalid_search_endpoint")
    })?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "invalid_search_endpoint",
        ));
    }
    if clean.contains("{query}") {
        return Ok(clean.replace("{query}", encoded_query));
    }
    let sep = if clean.contains('?') { '&' } else { '?' };
    Ok(format!("{clean}{sep}q={encoded_query}"))
}

fn truncate_utf8(mut text: String, max_bytes: usize) -> String {
    if text.len() <= max_bytes {
        return text;
    }
    let cut = text.floor_char_boundary(max_bytes);
    text.truncate(cut);
    text.push_str("\n[...truncated...]");
    text
}

/// Appends workspace instructions (`AGENTS.md` + `CLAUDE.md`), workspace skills index, and
/// saved memory entries to `prompt` for non-Write chats.
pub(crate) fn append_agent_prompt_context(
    storage: &StorageHandle,
    thread_id: &str,
    mode: ThreadMode,
    prompt: &mut String,
) {
    if mode == ThreadMode::Write {
        return;
    }
    let tools_on = storage
        .load_settings()
        .is_ok_and(|s| s.trust_preset != TrustPreset::Off);

    if tools_on {
        let roots = match crate::projects::workspace_roots_for(storage, Some(thread_id)) {
            Ok(roots) => roots,
            Err(err) => {
                tracing::warn!(
                    key = err.key.as_key(),
                    "chat folders unreadable; no workspace instructions or skills sent"
                );
                Vec::new()
            }
        };
        let mut instr = String::new();
        for root in &roots {
            for (path, text) in skills::discover_workspace_instructions(root) {
                let fname = path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("AGENTS.md");
                if !instr.is_empty() {
                    instr.push_str("\n\n");
                }
                instr.push_str("[Workspace instructions from ");
                instr.push_str(fname);
                instr.push_str("]\n");
                instr.push_str(&text);
            }
        }
        if !instr.is_empty() {
            let bounded = truncate_utf8(instr, MAX_WORKSPACE_INSTRUCTIONS_BYTES);
            if !prompt.trim().is_empty() {
                prompt.push_str("\n\n");
            }
            prompt.push_str(&bounded);
        }

        let mut skill_lines = String::new();
        // Workspace skills first, then Bistre's own (`skill_install`).
        let app_skills = crate::skill_install::app_skills_dir(storage)
            .map_or_else(Vec::new, |dir| skills::discover_skills_in(&dir));
        let workspace_skills = roots
            .iter()
            .flat_map(|r| skills::discover_workspace_skills(r));
        for sk in workspace_skills.chain(app_skills) {
            skill_lines.push_str("- ");
            skill_lines.push_str(&sk.name);
            if !sk.description.is_empty() {
                skill_lines.push_str(": ");
                skill_lines.push_str(&sk.description);
            }
            skill_lines.push_str(" (path: ");
            skill_lines.push_str(&sk.path);
            skill_lines.push_str(
                ")
",
            );
        }
        if !skill_lines.is_empty() {
            let bounded = truncate_utf8(
                format!(
                    "[Skills: call `skill_load` with a skill's path to read its full instructions]\n{skill_lines}"
                ),
                MAX_SKILLS_INDEX_BYTES,
            );
            if !prompt.trim().is_empty() {
                prompt.push_str("\n\n");
            }
            prompt.push_str(&bounded);
        }
    }

    match storage.list_memory_entries(None) {
        Ok(entries) => {
            let mut mem = String::new();
            for e in entries
                .iter()
                .filter(|e| e.scope == "global" || e.scope_id == thread_id || e.pinned)
            {
                mem.push_str("- ");
                mem.push_str(&e.key);
                mem.push_str(": ");
                mem.push_str(e.content.trim());
                mem.push('\n');
            }
            if !mem.is_empty() {
                let bounded =
                    truncate_utf8(format!("[Saved memory]\n{mem}"), MAX_SAVED_MEMORY_BYTES);
                if !prompt.trim().is_empty() {
                    prompt.push_str("\n\n");
                }
                prompt.push_str(&bounded);
            }
        }
        Err(err) => {
            tracing::warn!(
                key = err.key.as_key(),
                "saved memory entries unavailable for prompt context"
            );
        }
    }
}

/// JSON schema for the `skill_load` built-in tool.
pub(crate) fn skill_load_schema() -> Value {
    json!({
        "name": "skill_load",
        "description": "Load the full instructions of an indexed workspace SKILL.md file.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": { "type": "string" }
            },
            "required": ["path"]
        }
    })
}

/// JSON schema for the `agent_memory` built-in tool.
pub(crate) fn agent_memory_schema() -> Value {
    json!({
        "name": "agent_memory",
        "description": "List, save, or delete persistent cross-chat memory notes.",
        "parameters": {
            "type": "object",
            "properties": {
                "action": { "type": "string", "enum": ["list", "save", "delete"] },
                "key": { "type": "string" },
                "content": { "type": "string" },
                "id": { "type": "string" },
                "pinned": { "type": "boolean" }
            },
            "required": ["action"]
        }
    })
}

/// Executes `skill_load` against any bound workspace root (fail closed on path escape).
pub(crate) fn run_skill_load(roots: &[PathBuf], args: &Value) -> BistreResult<ToolExecutionOutput> {
    let raw_path = args
        .get("path")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
    if roots.is_empty() {
        return Err(BistreError::with_detail(
            DiagnosticKey::StorageNotFound,
            "no_workspace",
        ));
    }
    let mut last_err =
        BistreError::with_detail(DiagnosticKey::ToolPathDenied, "skill_outside_workspace");
    for root in roots {
        let candidate = Path::new(raw_path);
        let full = if candidate.is_absolute() {
            candidate.to_path_buf()
        } else {
            root.join(candidate)
        };
        match skills::load_skill_body(root, &full) {
            Ok(body) => {
                return Ok(ToolExecutionOutput {
                    tool_name: "skill_load".to_owned(),
                    risk_tier: ToolRiskTier::Tier0ReadOnly,
                    ok: true,
                    summary: format!("Loaded skill {raw_path}"),
                    output_text: body,
                    diff_text: None,
                    checkpoint_id: None,
                    duration_ms: 0,
                    media_attachments: Vec::new(),
                });
            }
            Err(err) => last_err = err,
        }
    }
    Err(last_err)
}

/// Executes `agent_memory` (`list`, `save`, or `delete`) against SQLite `memory_entries`.
pub(crate) fn run_agent_memory(
    storage: &StorageHandle,
    thread_id: &str,
    args: &Value,
) -> BistreResult<ToolExecutionOutput> {
    let action = args
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or("list")
        .trim();
    match action {
        "list" => {
            let items = storage.list_memory_entries(None)?;
            let lines: Vec<String> = items
                .iter()
                .map(|m| format!("[{}] {}: {}", m.id, m.key, m.content))
                .collect();
            Ok(ToolExecutionOutput {
                tool_name: "agent_memory".to_owned(),
                risk_tier: ToolRiskTier::Tier0ReadOnly,
                ok: true,
                summary: format!("Listed {} memory entries", items.len()),
                output_text: if lines.is_empty() {
                    "(no saved memory entries)".to_owned()
                } else {
                    lines.join("\n")
                },
                diff_text: None,
                checkpoint_id: None,
                duration_ms: 0,
                media_attachments: Vec::new(),
            })
        }
        "save" => {
            let key = args
                .get("key")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let content = args
                .get("content")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let id = args.get("id").and_then(Value::as_str).map(str::to_owned);
            let pinned = args.get("pinned").and_then(Value::as_bool).unwrap_or(false);
            let saved = storage.upsert_memory_entry(
                id,
                "global".to_owned(),
                "default".to_owned(),
                key.to_owned(),
                content.to_owned(),
                Some(thread_id.to_owned()),
                pinned,
            )?;
            Ok(ToolExecutionOutput {
                tool_name: "agent_memory".to_owned(),
                risk_tier: ToolRiskTier::Tier1ReversibleEdit,
                ok: true,
                summary: format!("Saved memory `{}`", saved.key),
                output_text: format!("Saved memory entry {} ({}).", saved.id, saved.key),
                diff_text: None,
                checkpoint_id: None,
                duration_ms: 0,
                media_attachments: Vec::new(),
            })
        }
        "delete" => {
            let id = args
                .get("id")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            storage.delete_memory_entry(id.to_owned())?;
            Ok(ToolExecutionOutput {
                tool_name: "agent_memory".to_owned(),
                risk_tier: ToolRiskTier::Tier1ReversibleEdit,
                ok: true,
                summary: format!("Deleted memory `{id}`"),
                output_text: format!("Deleted memory entry {id}."),
                diff_text: None,
                checkpoint_id: None,
                duration_ms: 0,
                media_attachments: Vec::new(),
            })
        }
        _ => Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "invalid_memory_action",
        )),
    }
}

/// Executes workspace file tools (`read`, `edit`, `grep`, `glob`) across one or more mounted
/// workspace roots (`agent.workspace_folders`), preserving `cap-std` confinement per root.
pub(crate) fn run_workspace_file_tool(
    storage: &StorageHandle,
    read_ledger: &ReadLedger,
    roots: &[PathBuf],
    thread_id: &str,
    run_id: Option<&str>,
    tool_name: &str,
    args: &Value,
) -> BistreResult<ToolExecutionOutput> {
    let primary = roots
        .first()
        .ok_or_else(|| BistreError::with_detail(DiagnosticKey::StorageNotFound, "no_workspace"))?;
    match tool_name {
        "read" => {
            let raw_rel = args
                .get("path")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let (root, rel) = resolve_root_and_path(roots, raw_rel).unwrap_or((primary, raw_rel));
            let start = args
                .get("start_line")
                .and_then(Value::as_u64)
                .and_then(|v| usize::try_from(v).ok());
            let end = args
                .get("end_line")
                .and_then(Value::as_u64)
                .and_then(|v| usize::try_from(v).ok());
            let out = tool_read(root, rel, start, end)?;
            if let Ok(digest) = file_digest(root, rel) {
                read_ledger.record(thread_id, raw_rel, &digest);
            }
            Ok(out)
        }
        "edit" => {
            let raw_rel = args
                .get("path")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let (root, rel) = resolve_root_and_path(roots, raw_rel).unwrap_or((primary, raw_rel));
            let target = args
                .get("target")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let replacement = args
                .get("replacement")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let expected_hash = args.get("expected_hash").and_then(Value::as_str);
            let current = file_digest(root, rel)?;
            read_ledger.check_fresh(thread_id, raw_rel, &current)?;
            let out = tool_edit(
                storage,
                root,
                thread_id,
                run_id,
                rel,
                target,
                replacement,
                expected_hash,
            )?;
            if let Ok(digest) = file_digest(root, rel) {
                read_ledger.record(thread_id, raw_rel, &digest);
            }
            Ok(out)
        }
        "grep" => {
            let pattern = args
                .get("pattern")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let raw_sub = args.get("subpath").and_then(Value::as_str);
            if let Some(sub) = raw_sub {
                let (root, rel) = resolve_root_and_path(roots, sub).unwrap_or((primary, sub));
                tool_grep(root, pattern, Some(rel))
            } else {
                tool_grep(primary, pattern, None)
            }
        }
        "glob" => {
            let pattern = args
                .get("pattern")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let (root, pat) = resolve_root_and_path(roots, pattern).unwrap_or((primary, pattern));
            tool_glob(root, pat)
        }
        name if crate::fs_tools::FS_TOOL_NAMES.contains(&name) => {
            crate::fs_tools::run(storage, read_ledger, roots, thread_id, run_id, name, args)
        }
        _ => Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "unknown_tool",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::build_web_search_url;

    #[test]
    fn build_web_search_url_supports_ddg_and_custom_templates()
    -> Result<(), Box<dyn std::error::Error>> {
        assert_eq!(
            build_web_search_url("duckduckgo", "rust+sqlite")?,
            "https://html.duckduckgo.com/html/?q=rust+sqlite"
        );
        assert_eq!(
            build_web_search_url("https://search.example/api?fmt=json", "rust")?,
            "https://search.example/api?fmt=json&q=rust"
        );
        assert_eq!(
            build_web_search_url("https://search.example/q/{query}/json", "rust")?,
            "https://search.example/q/rust/json"
        );
        assert!(build_web_search_url("file:///etc/passwd", "x").is_err());
        Ok(())
    }
}
