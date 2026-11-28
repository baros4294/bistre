//! Unit tests for `tools.rs`.

use super::*;
use std::collections::HashSet;
use tempfile::tempdir;

pub(crate) type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn capability_scoped_read_edit_diff_rewind_and_tier3_secret_blocks() -> TestResult {
    let dir = tempdir()?;
    let workspace = dir.path().join("ws");
    assert!(std::fs::create_dir_all(&workspace).is_ok());
    let file = workspace.join("hello.rs");
    assert!(std::fs::write(&file, "fn main() {\n    let x = 1;\n}\n").is_ok());

    // Tier-3 secret/traversal paths are hard-blocked.
    assert_eq!(
        classify_tool_risk("read", &json!({"path": "../etc/passwd"})),
        ToolRiskTier::Tier3Blocked
    );
    assert_eq!(
        classify_tool_risk("read", &json!({"path": ".env"})),
        ToolRiskTier::Tier3Blocked
    );
    assert!(tool_read(&workspace, ".env", None, None).is_err());

    // Read produces blake3 line-hash anchors.
    let read_out = Some(tool_read(&workspace, "hello.rs", Some(1), Some(3))?);
    assert!(
        read_out
            .as_ref()
            .is_some_and(|r| r.output_text.contains("2#"))
    );

    // Edit verifies hash, saves pre-image checkpoint, writes atomically, produces unified diff.
    let storage = StorageHandle::open(dir.path().join("tools.sqlite"))?;
    let thread =
        storage.create_thread(None, "Tools", bistre_protocol::ThreadMode::Code, None, None)?;

    let target = "    let x = 1;";
    let bad_edit = tool_edit(
        &storage,
        &workspace,
        &thread.id,
        None,
        "hello.rs",
        target,
        "    let x = 42;",
        Some("deadbeef"),
    );
    assert_eq!(
        bad_edit.err().map(|e| e.key),
        Some(DiagnosticKey::ToolEditHashMismatch)
    );

    let anchor = line_range_blake3(target);
    let edit_out = tool_edit(
        &storage,
        &workspace,
        &thread.id,
        None,
        "hello.rs",
        target,
        "    let x = 42;",
        Some(&anchor),
    )?;
    assert!(edit_out.ok && edit_out.diff_text.is_some());
    assert_eq!(
        std::fs::read_to_string(&file)?,
        "fn main() {\n    let x = 42;\n}\n"
    );

    // 1-click Rewind restores exact original bytes!
    let cp_id = edit_out.checkpoint_id.ok_or("edit made no checkpoint")?;
    assert!(tool_rewind_checkpoint(&storage, &workspace, &cp_id).is_ok());
    assert_eq!(
        std::fs::read_to_string(&file)?,
        "fn main() {\n    let x = 1;\n}\n"
    );

    // Grep & Glob run zero-fork in-process.
    let g = Some(tool_grep(&workspace, "let x = 1", None)?);
    assert!(
        g.as_ref()
            .is_some_and(|r| r.output_text.contains("hello.rs:2:"))
    );
    let gl = Some(tool_glob(&workspace, "*.rs")?);
    assert!(
        gl.as_ref()
            .is_some_and(|r| r.output_text.contains("hello.rs"))
    );
    Ok(())
}

#[test]
fn self_healing_tool_parser_recovers_xml_leaks_and_deduplicates() {
    let raw = "Sure!\n<tool_call>{\"name\":\"read\",\"arguments\":{\"path\":\"a.rs\"}}</tool_call>\n<tool_call>{\"name\":\"read\",\"arguments\":{\"path\":\"a.rs\"}}</tool_call>";
    let (calls, cleaned) = heal_and_dedup_tool_calls(Vec::new(), raw);
    assert_eq!(calls.len(), 1);
    assert!(calls[0].healed_from_text);
    assert_eq!(calls[0].name, "read");
    assert_eq!(cleaned, "Sure!");
}

#[test]
fn stale_read_guard_near_miss_hints_crlf_edits_and_truncation_footer() -> TestResult {
    let dir = tempdir()?;
    let ws = dir.path().join("ws");
    assert!(std::fs::create_dir_all(&ws).is_ok());
    assert!(std::fs::write(ws.join("win.txt"), "alpha\r\n    beta  gamma\r\nomega\r\n").is_ok());
    let storage = StorageHandle::open(dir.path().join("t.sqlite"))?;
    let thread = storage.create_thread(
        None,
        "Harness",
        bistre_protocol::ThreadMode::Code,
        None,
        None,
    )?;
    let tid = thread.id.as_str();

    // Run-scoped stale-read guard.
    let ledger = ReadLedger::default();
    let d1 = file_digest(&ws, "win.txt").unwrap_or_default();
    ledger.record("thread-a", "win.txt", &d1);
    assert!(ledger.check_fresh("thread-a", "./win.txt", &d1).is_ok());
    assert!(std::fs::write(ws.join("win.txt"), "alpha\r\n    beta  gamma\r\nomega!\r\n").is_ok());
    let d2 = file_digest(&ws, "win.txt").unwrap_or_default();
    assert_eq!(
        ledger
            .check_fresh("thread-a", "win.txt", &d2)
            .err()
            .map(|e| e.key),
        Some(DiagnosticKey::ToolStaleRead)
    );
    assert!(
        ledger.check_fresh("thread-b", "win.txt", &d2).is_ok(),
        "other scopes unaffected"
    );

    // CRLF is preserved when the model sends LF text.
    let edited = tool_edit(
        &storage,
        &ws,
        tid,
        None,
        "win.txt",
        "alpha\n    beta  gamma",
        "alpha\nBETA",
        None,
    );
    assert!(edited.is_ok());
    let after = std::fs::read_to_string(ws.join("win.txt")).unwrap_or_default();
    assert_eq!(after, "alpha\r\nBETA\r\nomega!\r\n");

    // Near-miss hint points at the closest line.
    let miss = tool_edit(
        &storage,
        &ws,
        tid,
        None,
        "win.txt",
        "omega!  \nnot here",
        "x",
        None,
    );
    assert_eq!(
        miss.err().and_then(|e| e.detail_code),
        Some("target_not_found;near_line=3".to_owned())
    );

    // Partial reads end with the truncation footer.
    let mut lines = String::new();
    for i in 0..300 {
        push_line(&mut lines, format_args!("line {i}"));
    }
    assert!(std::fs::write(ws.join("long.txt"), lines).is_ok());
    let read =
        tool_read(&ws, "long.txt", None, None).map_or_else(|_| String::new(), |o| o.output_text);
    assert!(read.contains(TRUNCATED_READ_FOOTER));
    assert!(read.contains("start_line=251"));
    Ok(())
}

#[test]
fn replayed_tool_call_ids_are_sanitized_bounded_and_unique() {
    let mut seen = HashSet::new();
    assert_eq!(
        sanitize_tool_call_id("call:abc/1", &mut seen, 1),
        "callabc1"
    );
    assert_eq!(
        sanitize_tool_call_id("callabc1", &mut seen, 2),
        "callabc1_2"
    );
    assert_eq!(sanitize_tool_call_id("%%%", &mut seen, 3), "call_3");
    let long = "x".repeat(200);
    let a = sanitize_tool_call_id(&long, &mut seen, 4);
    let b = sanitize_tool_call_id(&long, &mut seen, 5);
    assert_eq!(a.len(), MAX_TOOL_CALL_ID_LEN);
    assert!(b.len() <= MAX_TOOL_CALL_ID_LEN && a != b);
}
