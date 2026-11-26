//! W4.9: the cached prefix of every request (tools, then the system prompt) is pinned by a
//! golden per dialect, and stays byte-identical as the conversation grows (hermes #144442: a
//! volatile value in the hashed prefix collapses the prompt cache). Cache breakpoints are
//! checked on the converted wire body, not on canonical data (`SillyTavern` #5227).
//!
//! To refresh the goldens after an intended change: `BISTRE_UPDATE_GOLDENS=1 cargo nextest run
//! -p bistre-core -E 'test(prompt_surface)'`, then review the diff.

use std::collections::HashMap;
use std::path::PathBuf;

use bistre_protocol::{GenerationParams, NodeRecord, NodeRole, ProviderDialect};
use serde_json::{Value, json};

use crate::agent_tools::ActiveToolCatalog;
use crate::providers::{StreamRequestOptions, build_stream_request_full};

const SYSTEM: &str = "You are Bistre, a careful assistant.";

fn turn(id: &str, role: NodeRole, content: &str) -> NodeRecord {
    NodeRecord {
        id: id.to_owned(),
        thread_id: "t".to_owned(),
        parent_id: None,
        role,
        content: content.to_owned(),
        provider_meta_json: None,
        created_at_ms: 1,
    }
}

fn body(dialect: ProviderDialect, history: &[NodeRecord], catalog: &ActiveToolCatalog) -> Value {
    let tools = catalog.wire_tools_for_dialect(dialect);
    let opts = StreamRequestOptions {
        tools_wire: Some(tools.as_slice()),
        ..StreamRequestOptions::default()
    };
    build_stream_request_full(
        dialect,
        "https://example.invalid/v1",
        "m",
        SYSTEM,
        history,
        GenerationParams::default(),
        false,
        None,
        &HashMap::<String, String>::new(),
        &opts,
    )
    .body
    .unwrap_or_default()
}

/// The cached prefix: tools first, then the system prompt wherever the dialect carries it.
fn prefix(body: &Value) -> Value {
    let first_item = ["input", "messages", "contents"]
        .iter()
        .find_map(|k| {
            body.get(*k)
                .and_then(Value::as_array)
                .and_then(|a| a.first())
        })
        .filter(|item| matches!(item["role"].as_str(), Some("developer" | "system")))
        .cloned();
    json!({
        "tools": body.get("tools"),
        "system": body
            .get("system")
            .or_else(|| body.get("system_instruction"))
            .or_else(|| body.get("systemInstruction"))
            .or_else(|| body.get("instructions")),
        "first_item": first_item,
    })
}

fn golden_path(dialect: ProviderDialect) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("fixtures")
        .join("prompt_surface")
        .join(format!("{}.json", dialect.as_str()))
}

#[test]
fn prompt_surface_prefix_is_pinned_and_stable_per_dialect() -> Result<(), Box<dyn std::error::Error>>
{
    let catalog = ActiveToolCatalog {
        canonical_schemas: crate::tools::builtin_tool_schemas(true),
        ..ActiveToolCatalog::default()
    };
    let short = vec![turn("u1", NodeRole::User, "Hello")];
    let long = vec![
        turn("u1", NodeRole::User, "Hello"),
        turn("a1", NodeRole::Assistant, "Hi there."),
        turn("u2", NodeRole::User, "Tell me more."),
    ];
    let update = std::env::var_os("BISTRE_UPDATE_GOLDENS").is_some();
    for dialect in ProviderDialect::ALL {
        let first = prefix(&body(dialect, &short, &catalog));
        let later = prefix(&body(dialect, &long, &catalog));
        assert_eq!(
            first, later,
            "{dialect:?}: the prefix changed as the chat grew"
        );
        let rendered = format!("{}\n", serde_json::to_string_pretty(&first)?);
        let path = golden_path(dialect);
        if update {
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir)?;
            }
            std::fs::write(&path, &rendered)?;
        }
        let golden = std::fs::read_to_string(&path)?.replace("\r\n", "\n");
        assert_eq!(
            rendered,
            golden,
            "{dialect:?}: prompt surface differs from {}",
            path.display()
        );
    }
    Ok(())
}

/// Anthropic cache breakpoints sit on the converted wire body: the last tool and the system
/// block, so the cached prefix ends where the stable part ends.
#[test]
fn anthropic_cache_breakpoints_are_placed_on_the_wire_body() {
    let catalog = ActiveToolCatalog {
        canonical_schemas: crate::tools::builtin_tool_schemas(true),
        ..ActiveToolCatalog::default()
    };
    let b = body(
        ProviderDialect::Anthropic,
        &[turn("u1", NodeRole::User, "Hello")],
        &catalog,
    );
    let tools = b["tools"].as_array().cloned().unwrap_or_default();
    assert!(tools.len() > 1);
    assert!(
        tools[..tools.len() - 1]
            .iter()
            .all(|t| t.get("cache_control").is_none())
    );
    assert!(
        tools
            .last()
            .is_some_and(|t| t.get("cache_control").is_some())
    );
    assert!(b["system"][0].get("cache_control").is_some(), "{b}");
}
