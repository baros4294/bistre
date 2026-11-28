//! Lossless recall after compaction: a summary stands in for earlier messages in the prompt,
//! but every message stays saved. Two read-only tools let the model search the condensed
//! messages (`history_search`) and open any saved message of the branch in full
//! (`history_open`), so nothing a summary left out is lost (Spec 04, ADR-0005).

use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, NodeRecord, NodeRole, ToolRiskTier, TrustPreset,
};
use bistre_storage::StorageHandle;
use serde_json::{Value, json};

use crate::agent_tools::{ActiveToolCatalog, ToolPermission};
use crate::tools::ToolExecutionOutput;

/// Searches the messages the latest summary condensed.
pub const SEARCH: &str = "history_search";
/// Opens one saved message of the branch in full, in parts.
pub const OPEN: &str = "history_open";

const MAX_QUERY_CHARS: usize = 200;
const MAX_MATCHES: usize = 20;
const SNIPPET_CHARS: usize = 240;
const MAX_OPEN_CHARS: usize = 8_000;
const MAX_STEP_LABEL_CHARS: usize = 80;

/// Adds both tools, in name order, when the history about to be sent opens with a summary and
/// tools are on. A tool the user turned off stays out.
pub fn offer(catalog: &mut ActiveToolCatalog, history: &[NodeRecord]) {
    if catalog.trust_preset == TrustPreset::Off
        || !crate::compaction::history_opens_with_summary(history)
    {
        return;
    }
    for (name, schema) in [(OPEN, open_schema()), (SEARCH, search_schema())] {
        if catalog.permissions.get(name) == Some(&ToolPermission::Off) {
            continue;
        }
        let at = catalog
            .canonical_schemas
            .partition_point(|s| s.get("name").and_then(Value::as_str) < Some(name));
        catalog.canonical_schemas.insert(at, schema);
    }
}

fn search_schema() -> Value {
    json!({
        "name": SEARCH,
        "description": format!("Search the earlier messages of this chat that a summary condensed; their full text is still saved. Every word of the query must appear (any case). Returns up to {MAX_MATCHES} matches with message ids for {OPEN}."),
        "parameters": {
            "type": "object",
            "properties": {
                "query": { "type": "string", "description": "Words to find." }
            },
            "required": ["query"]
        }
    })
}

fn open_schema() -> Value {
    json!({
        "name": OPEN,
        "description": format!("Open one saved message of this chat in full by its id (from {SEARCH}). Long messages come in parts of {MAX_OPEN_CHARS} characters; pass the offset the last part names to read on."),
        "parameters": {
            "type": "object",
            "properties": {
                "id": { "type": "string" },
                "offset": { "type": "integer", "minimum": 0 }
            },
            "required": ["id"]
        }
    })
}

/// Runs `history_search` or `history_open` on the chat's active branch.
pub fn dispatch(
    storage: &StorageHandle,
    thread_id: &str,
    tool_name: &str,
    args: &Value,
) -> BistreResult<ToolExecutionOutput> {
    let (branch, pin) = active_branch(storage, thread_id)?;
    let (summary, output_text) = match tool_name {
        SEARCH => search(&branch, pin.as_deref(), args)?,
        OPEN => open(&branch, pin.as_deref(), args)?,
        _ => {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "unknown_tool",
            ));
        }
    };
    Ok(ToolExecutionOutput {
        tool_name: tool_name.to_owned(),
        risk_tier: ToolRiskTier::Tier0ReadOnly,
        ok: true,
        summary,
        output_text,
        diff_text: None,
        checkpoint_id: None,
        duration_ms: 0,
        media_attachments: Vec::new(),
    })
}

/// The branch ending at the chat's active head (a run's tool results extend it), and the
/// context-start pin; nothing before the pin is ever shown to the model.
fn active_branch(
    storage: &StorageHandle,
    thread_id: &str,
) -> BistreResult<(Vec<NodeRecord>, Option<String>)> {
    let head = storage
        .get_thread(thread_id)?
        .and_then(|t| t.active_head_node_id)
        .ok_or_else(|| BistreError::with_detail(DiagnosticKey::StorageNotFound, "no_messages"))?;
    let branch = storage.list_branch(thread_id, &head)?;
    let pin = storage.get_kv_meta(&format!("thread_context_start:{thread_id}"))?;
    Ok((branch, pin))
}

fn search(
    branch: &[NodeRecord],
    pin: Option<&str>,
    args: &Value,
) -> BistreResult<(String, String)> {
    let query: String = args
        .get("query")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .chars()
        .take(MAX_QUERY_CHARS)
        .collect();
    let words: Vec<String> = query.split_whitespace().map(str::to_lowercase).collect();
    let Some(first_word) = words.first() else {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "empty_query",
        ));
    };
    let mut matches = Vec::new();
    let mut more = false;
    for node in crate::compaction::condensed_messages(branch, pin) {
        let lower = node.content.to_lowercase();
        if !words.iter().all(|w| lower.contains(w.as_str())) {
            continue;
        }
        if matches.len() == MAX_MATCHES {
            more = true;
            break;
        }
        let at = lower
            .find(first_word.as_str())
            .map_or(0, |byte| lower[..byte].chars().count());
        matches.push(json!({
            "id": node.id,
            "role": node.role.as_str(),
            "text": snippet(&node.content, at),
        }));
    }
    let label = query.trim().chars().take(MAX_STEP_LABEL_CHARS).collect();
    Ok((
        label,
        json!({ "matches": matches, "more": more }).to_string(),
    ))
}

/// About [`SNIPPET_CHARS`] characters around character `at`, whitespace folded.
fn snippet(text: &str, at: usize) -> String {
    let start = at.saturating_sub(SNIPPET_CHARS / 3);
    let piece: String = text.chars().skip(start).take(SNIPPET_CHARS).collect();
    piece.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn open(branch: &[NodeRecord], pin: Option<&str>, args: &Value) -> BistreResult<(String, String)> {
    let id = args
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
    let start = pin
        .and_then(|p| branch.iter().position(|n| n.id == p))
        .unwrap_or(0);
    let node = branch[start..]
        .iter()
        .find(|n| n.id == id && n.role != NodeRole::CompactionSummary)
        .ok_or_else(|| BistreError::with_detail(DiagnosticKey::StorageNotFound, "not_in_chat"))?;
    let offset = match args.get("offset") {
        None | Some(Value::Null) => 0,
        Some(v) => v
            .as_u64()
            .and_then(|o| usize::try_from(o).ok())
            .ok_or_else(|| BistreError::with_detail(DiagnosticKey::InvalidInput, "bad_offset"))?,
    };
    let total = node.content.chars().count();
    if offset > total || (offset == total && offset > 0) {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "offset_past_end",
        ));
    }
    let mut part: String = node
        .content
        .chars()
        .skip(offset)
        .take(MAX_OPEN_CHARS)
        .collect();
    let next = offset.saturating_add(MAX_OPEN_CHARS);
    if next < total {
        part = format!(
            "{part}\n\n[{} more characters; call {OPEN} with \"offset\": {next}]",
            total - next
        );
    }
    let label = node
        .content
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or_default()
        .chars()
        .take(MAX_STEP_LABEL_CHARS)
        .collect();
    Ok((label, part))
}

#[cfg(test)]
mod tests {
    use super::*;
    use bistre_protocol::{ThreadMode, TrustPreset};

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    /// A chat of `turns` question/answer pairs compacted down to its last four messages.
    fn compacted_chat(
        storage: &StorageHandle,
        turns: usize,
    ) -> Result<(String, Vec<NodeRecord>), Box<dyn std::error::Error>> {
        let thread = storage.create_thread(None, "t", ThreadMode::Chat, None, None)?;
        let mut parent = None;
        for i in 0..turns {
            let q = storage.append_node(
                thread.id.clone(),
                parent,
                NodeRole::User,
                format!("Question {i} about the Parser{i}"),
                None,
            )?;
            let a = storage.append_node(
                thread.id.clone(),
                Some(q.id),
                NodeRole::Assistant,
                format!("Answer {i}: keep parser{i} strict"),
                None,
            )?;
            parent = Some(a.id);
        }
        let branch = storage.list_nodes(&thread.id)?;
        crate::compaction::create_reversible_compaction(storage, &thread.id, &branch, 4, None)?;
        Ok((thread.id, branch))
    }

    fn run(storage: &StorageHandle, thread: &str, tool: &str, args: &Value) -> BistreResult<Value> {
        let out = dispatch(storage, thread, tool, args)?;
        assert!(out.ok);
        assert_eq!(out.risk_tier, ToolRiskTier::Tier0ReadOnly);
        Ok(serde_json::from_str(&out.output_text).unwrap_or(Value::String(out.output_text)))
    }

    #[test]
    fn a_condensed_message_is_found_and_opened_in_full() -> TestResult {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("r.db"))?;
        let (thread, branch) = compacted_chat(&storage, 4)?;

        // Every word must appear, in any case; only condensed messages are searched.
        let found = run(
            &storage,
            &thread,
            SEARCH,
            &json!({ "query": "PARSER1 strict" }),
        )?;
        let matches = found["matches"].as_array().cloned().unwrap_or_default();
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0]["id"], json!(branch[3].id));
        assert_eq!(matches[0]["role"], json!("assistant"));
        assert_eq!(found["more"], json!(false));
        let kept = run(&storage, &thread, SEARCH, &json!({ "query": "parser3" }))?;
        assert_eq!(
            kept["matches"],
            json!([]),
            "a message still in the prompt is not repeated"
        );

        let opened = run(&storage, &thread, OPEN, &json!({ "id": branch[3].id }))?;
        assert_eq!(opened, json!(branch[3].content));
        Ok(())
    }

    #[test]
    fn a_long_message_opens_in_parts() -> TestResult {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("r.db"))?;
        let thread = storage.create_thread(None, "t", ThreadMode::Chat, None, None)?;
        let long = "é".repeat(MAX_OPEN_CHARS + 10);
        let node = storage.append_node(thread.id.clone(), None, NodeRole::Tool, long, None)?;
        let first = dispatch(&storage, &thread.id, OPEN, &json!({ "id": node.id }))?.output_text;
        assert!(first.starts_with(&"é".repeat(MAX_OPEN_CHARS)));
        assert!(first.contains(&format!("\"offset\": {MAX_OPEN_CHARS}")));
        let rest = json!({ "id": node.id, "offset": MAX_OPEN_CHARS });
        let second = dispatch(&storage, &thread.id, OPEN, &rest)?.output_text;
        assert_eq!(second, "é".repeat(10));
        let past = json!({ "id": node.id, "offset": MAX_OPEN_CHARS + 11 });
        assert!(dispatch(&storage, &thread.id, OPEN, &past).is_err());
        Ok(())
    }

    #[test]
    fn matches_are_capped_and_another_chat_stays_closed() -> TestResult {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("r.db"))?;
        let (thread, _) = compacted_chat(&storage, MAX_MATCHES + 4)?;
        let found = run(&storage, &thread, SEARCH, &json!({ "query": "question" }))?;
        assert_eq!(found["matches"].as_array().map(Vec::len), Some(MAX_MATCHES));
        assert_eq!(found["more"], json!(true));

        let (other, other_branch) = compacted_chat(&storage, 4)?;
        assert_ne!(other, thread);
        let foreign = json!({ "id": other_branch[0].id });
        assert!(dispatch(&storage, &thread, OPEN, &foreign).is_err());
        assert!(dispatch(&storage, &thread, SEARCH, &json!({ "query": " " })).is_err());
        Ok(())
    }

    #[test]
    fn the_context_start_pin_hides_what_is_before_it() -> TestResult {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("r.db"))?;
        let (thread, branch) = compacted_chat(&storage, 4)?;
        storage.set_kv_meta(
            format!("thread_context_start:{thread}"),
            branch[2].id.clone(),
        )?;
        let found = run(&storage, &thread, SEARCH, &json!({ "query": "parser0" }))?;
        assert_eq!(found["matches"], json!([]));
        assert!(dispatch(&storage, &thread, OPEN, &json!({ "id": branch[0].id })).is_err());
        Ok(())
    }

    #[test]
    fn the_tools_are_offered_only_once_something_is_condensed() -> TestResult {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("r.db"))?;
        let (thread, _) = compacted_chat(&storage, 4)?;
        let nodes = storage.list_nodes(&thread)?;
        let projected = crate::compaction::project_effective_history(&nodes, None);
        let names = |cat: &ActiveToolCatalog| -> Vec<String> {
            cat.canonical_schemas
                .iter()
                .filter_map(|s| s.get("name").and_then(Value::as_str).map(str::to_owned))
                .collect()
        };
        let on = || ActiveToolCatalog {
            trust_preset: TrustPreset::GuidedCraft,
            canonical_schemas: vec![json!({ "name": "a" }), json!({ "name": "z" })],
            ..ActiveToolCatalog::default()
        };

        let mut plain = on();
        offer(&mut plain, &nodes[..2]);
        assert_eq!(names(&plain), ["a", "z"]);
        let mut offered = on();
        offer(&mut offered, &projected);
        assert_eq!(
            names(&offered),
            ["a", OPEN, SEARCH, "z"],
            "kept in name order"
        );
        let mut off = ActiveToolCatalog::default();
        offer(&mut off, &projected);
        assert!(off.canonical_schemas.is_empty(), "tools off means none");
        let mut denied = on();
        denied
            .permissions
            .insert(SEARCH.to_owned(), ToolPermission::Off);
        offer(&mut denied, &projected);
        assert_eq!(names(&denied), ["a", OPEN, "z"]);

        assert_eq!(
            crate::tools::classify_tool_risk(SEARCH, &json!({})),
            ToolRiskTier::Tier0ReadOnly
        );
        assert_eq!(
            crate::durability::classify_tool_replay_safety(OPEN),
            crate::durability::ToolReplaySafety::ReplaySafe
        );
        Ok(())
    }
}
