//! Workspace file tools beyond `read`/`edit` (Spec 04): `fs_list`, `fs_write`, `fs_multi_edit`,
//! `fs_move`, and `fs_delete`. Every path goes through a `cap_std` `Dir` opened on the workspace
//! root, so no tool reaches outside it. Every change saves a rewind checkpoint before it touches
//! the disk, and a whole-file overwrite needs a fresh read of that file first.

use std::path::{Path, PathBuf};
use std::time::Instant;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, ToolRiskTier};
use bistre_storage::StorageHandle;
use cap_std::ambient_authority;
use cap_std::fs::Dir;
use serde_json::{Value, json};

use crate::tools::{
    MAX_READ_FILE_BYTES, ReadLedger, ToolExecutionOutput, apply_replacement, atomic_write_in_dir,
    bytes_blake3, compute_unified_diff, is_forbidden_secret_path,
};

/// Checkpoint digest for "no file was here": rewinding such a checkpoint removes the file.
pub const ABSENT_FILE_DIGEST: &str = "absent";
const MAX_LIST_ENTRIES: usize = 500;
const MAX_WRITE_BYTES: usize = 2 * 1024 * 1024;
const MAX_MULTI_EDITS: usize = 32;

/// Tool names this module runs.
pub const FS_TOOL_NAMES: [&str; 5] = [
    "fs_delete",
    "fs_list",
    "fs_move",
    "fs_multi_edit",
    "fs_write",
];

/// `fs_list` always; the four writing tools only when writes are allowed.
pub fn schemas(include_write_tools: bool) -> Vec<Value> {
    let mut out = vec![json!({
        "name": "fs_list",
        "description": "List one workspace folder: names, folders marked with a trailing slash, and file sizes.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "Folder relative to the workspace; empty for the top." }
            }
        }
    })];
    if !include_write_tools {
        return out;
    }
    out.push(json!({
        "name": "fs_delete",
        "description": "Delete one workspace file (not a folder). A rewind checkpoint keeps its content.",
        "parameters": {
            "type": "object",
            "properties": { "path": { "type": "string" } },
            "required": ["path"]
        }
    }));
    out.push(json!({
        "name": "fs_move",
        "description": "Move or rename one workspace file. Never replaces an existing file.",
        "parameters": {
            "type": "object",
            "properties": {
                "from": { "type": "string" },
                "to": { "type": "string" }
            },
            "required": ["from", "to"]
        }
    }));
    out.push(json!({
        "name": "fs_multi_edit",
        "description": "Apply several exact text replacements to one workspace file in order; all apply or none do.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": { "type": "string" },
                "edits": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "target": { "type": "string" },
                            "replacement": { "type": "string" }
                        },
                        "required": ["target", "replacement"]
                    }
                }
            },
            "required": ["path", "edits"]
        }
    }));
    out.push(json!({
        "name": "fs_write",
        "description": "Create a workspace file, or replace a whole file you have read in full. Creates missing folders.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": { "type": "string" },
                "content": { "type": "string" }
            },
            "required": ["path", "content"]
        }
    }));
    out
}

/// Runs one `fs_*` tool against the workspace root its path names.
pub(crate) fn run(
    storage: &StorageHandle,
    read_ledger: &ReadLedger,
    roots: &[PathBuf],
    thread_id: &str,
    run_id: Option<&str>,
    tool_name: &str,
    args: &Value,
) -> BistreResult<ToolExecutionOutput> {
    let started = Instant::now();
    let arg = |key: &str| -> BistreResult<&str> {
        args.get(key).and_then(Value::as_str).ok_or_else(|| {
            BistreError::with_detail(DiagnosticKey::InvalidInput, "missing_argument")
        })
    };
    let mut out = match tool_name {
        "fs_list" => {
            let raw = args.get("path").and_then(Value::as_str).unwrap_or("");
            let (root, rel) = resolve(roots, raw)?;
            list(&open_root(&root)?, &rel)?
        }
        "fs_write" => {
            let raw = arg("path")?;
            let (root, rel) = resolve(roots, raw)?;
            let content = arg("content")?;
            if content.len() > MAX_WRITE_BYTES {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "write_too_large",
                ));
            }
            let dir = open_root(&root)?;
            let before = read_existing(&dir, &rel)?;
            if before.is_some() {
                // Overwriting what the model never saw (or saw truncated and then changed) loses
                // text, so a whole-file replace needs this run's own fresh read.
                if !read_ledger.has_read(thread_id, raw) {
                    return Err(BistreError::with_detail(
                        DiagnosticKey::ToolStaleRead,
                        "read_before_overwrite",
                    ));
                }
                fresh(read_ledger, thread_id, raw, &dir, &rel)?;
            }
            let after = write_with_checkpoint(
                storage,
                &dir,
                (thread_id, run_id),
                tool_name,
                &rel,
                before.as_deref(),
                content,
            )?;
            read_ledger.record(thread_id, raw, &bytes_blake3(content.as_bytes()));
            after
        }
        "fs_multi_edit" => {
            let raw = arg("path")?;
            let (root, rel) = resolve(roots, raw)?;
            let edits = args
                .get("edits")
                .and_then(Value::as_array)
                .filter(|e| !e.is_empty() && e.len() <= MAX_MULTI_EDITS)
                .ok_or_else(|| {
                    BistreError::with_detail(DiagnosticKey::InvalidInput, "edits_count")
                })?;
            let dir = open_root(&root)?;
            fresh(read_ledger, thread_id, raw, &dir, &rel)?;
            let before = read_existing(&dir, &rel)?.ok_or_else(|| {
                BistreError::with_detail(DiagnosticKey::StorageNotFound, "edit_not_found")
            })?;
            let text = apply_edits(&before, edits)?;
            let after = write_with_checkpoint(
                storage,
                &dir,
                (thread_id, run_id),
                tool_name,
                &rel,
                Some(&before),
                &text,
            )?;
            read_ledger.record(thread_id, raw, &bytes_blake3(text.as_bytes()));
            after
        }
        "fs_move" => {
            let (raw_from, raw_to) = (arg("from")?, arg("to")?);
            let (root, from) = resolve(roots, raw_from)?;
            let (to_root, to) = resolve(roots, raw_to)?;
            if root != to_root || from.is_empty() || to.is_empty() {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "move_paths",
                ));
            }
            let dir = open_root(&root)?;
            fresh(read_ledger, thread_id, raw_from, &dir, &from)?;
            move_file(storage, &dir, thread_id, run_id, &from, &to)?
        }
        "fs_delete" => {
            let raw = arg("path")?;
            let (root, rel) = resolve(roots, raw)?;
            let dir = open_root(&root)?;
            fresh(read_ledger, thread_id, raw, &dir, &rel)?;
            delete_file(storage, &dir, thread_id, run_id, &rel)?
        }
        _ => {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "unknown_tool",
            ));
        }
    };
    if matches!(tool_name, "fs_move" | "fs_delete") {
        for key in ["path", "from", "to"] {
            if let Some(raw) = args.get(key).and_then(Value::as_str) {
                read_ledger.invalidate_path(raw);
            }
        }
    }
    out.duration_ms = i64::try_from(started.elapsed().as_millis()).unwrap_or(i64::MAX);
    Ok(out)
}

/// The workspace root a path names and the path inside it; secret files are refused.
fn resolve(roots: &[PathBuf], raw: &str) -> BistreResult<(PathBuf, String)> {
    let (root, rel) = crate::agent_context::resolve_root_and_path(roots, raw)
        .ok_or_else(|| BistreError::with_detail(DiagnosticKey::StorageNotFound, "no_workspace"))?;
    let rel = rel.trim().trim_start_matches("./").to_owned();
    if !rel.is_empty() && is_forbidden_secret_path(&rel) {
        return Err(BistreError::with_detail(
            DiagnosticKey::ToolTierBlocked,
            "tier3_secret_path_blocked",
        ));
    }
    Ok((root.to_path_buf(), rel))
}

/// `Err` when `rel` is a file larger than `MAX_READ_FILE_BYTES`, so no tool loads a huge file
/// into memory and its rewind checkpoint. A missing path or folder is left to the read that
/// follows, which reports it.
fn within_read_cap(dir: &Dir, rel: &str) -> BistreResult<()> {
    match dir.metadata(rel) {
        Ok(meta) if meta.is_file() && meta.len() > MAX_READ_FILE_BYTES => Err(
            BistreError::with_detail(DiagnosticKey::InvalidInput, "file_too_large"),
        ),
        _ => Ok(()),
    }
}

fn open_root(root: &Path) -> BistreResult<Dir> {
    Dir::open_ambient_dir(root, ambient_authority())
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "workspace_open"))
}

/// `Err(ToolStaleRead)` when this run read the file and it changed since.
fn fresh(ledger: &ReadLedger, scope: &str, raw: &str, dir: &Dir, rel: &str) -> BistreResult<()> {
    // A missing path or a folder is reported by the tool itself.
    if !dir.symlink_metadata(rel).is_ok_and(|m| m.is_file()) {
        return Ok(());
    }
    within_read_cap(dir, rel)?;
    match dir.read(rel) {
        Ok(bytes) => ledger.check_fresh(scope, raw, &bytes_blake3(&bytes)),
        Err(_) => Err(BistreError::with_detail(
            DiagnosticKey::InternalError,
            "file_read",
        )),
    }
}

/// The file's UTF-8 text, `None` when it does not exist; a folder or binary file is an error.
fn read_existing(dir: &Dir, rel: &str) -> BistreResult<Option<String>> {
    within_read_cap(dir, rel)?;
    match dir.read(rel) {
        Ok(bytes) => String::from_utf8(bytes)
            .map(Some)
            .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "invalid_utf8")),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "not_a_file",
        )),
    }
}

fn output(
    tool_name: &str,
    risk_tier: ToolRiskTier,
    summary: String,
    diff_text: Option<String>,
    checkpoint_id: Option<String>,
) -> ToolExecutionOutput {
    ToolExecutionOutput {
        tool_name: tool_name.to_owned(),
        risk_tier,
        ok: true,
        output_text: summary.clone(),
        summary,
        diff_text,
        checkpoint_id,
        duration_ms: 0,
        media_attachments: Vec::new(),
    }
}

fn list(dir: &Dir, rel: &str) -> BistreResult<ToolExecutionOutput> {
    let entries = if rel.is_empty() || rel == "." {
        dir.entries()
    } else {
        dir.read_dir(rel)
    }
    .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "folder_not_found"))?;
    let mut rows = Vec::new();
    let mut more = 0_usize;
    for entry in entries {
        let Ok(entry) = entry else {
            tracing::debug!("fs_list skipped an unreadable entry");
            continue;
        };
        let name = entry.file_name().to_string_lossy().into_owned();
        let child = if rel.is_empty() || rel == "." {
            name.clone()
        } else {
            format!("{}/{name}", rel.trim_end_matches(['/', '\\']))
        };
        if is_forbidden_secret_path(&child) {
            continue;
        }
        if rows.len() >= MAX_LIST_ENTRIES {
            more = more.saturating_add(1);
            continue;
        }
        let kind = entry
            .file_type()
            .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "entry_type"))?;
        rows.push(if kind.is_dir() {
            format!("{name}/")
        } else if kind.is_file() {
            let size = entry.metadata().map(|m| m.len()).map_err(|_| {
                BistreError::with_detail(DiagnosticKey::InternalError, "entry_metadata")
            })?;
            format!("{name}\t{size} bytes")
        } else {
            format!("{name}\t(link)")
        });
    }
    rows.sort_unstable();
    let shown = rows.len();
    let mut text = rows.join("\n");
    if more > 0 {
        text.extend(["\n[", &more.to_string(), " more entries not shown]"]);
    }
    let label = if rel.is_empty() { "." } else { rel };
    let mut out = output(
        "fs_list",
        ToolRiskTier::Tier0ReadOnly,
        format!("listed {label} ({shown} entries)"),
        None,
        None,
    );
    out.output_text = text;
    Ok(out)
}

fn create_parent(dir: &Dir, rel: &str) -> BistreResult<()> {
    if let Some(parent) = Path::new(rel)
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
    {
        dir.create_dir_all(parent)
            .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "parent_create"))?;
    }
    Ok(())
}

/// Applies every edit in order to an in-memory copy; any failed edit fails them all.
fn apply_edits(before: &str, edits: &[Value]) -> BistreResult<String> {
    let mut text = before.to_owned();
    for (index, edit) in edits.iter().enumerate() {
        let target = edit.get("target").and_then(Value::as_str);
        let replacement = edit.get("replacement").and_then(Value::as_str);
        let (Some(target), Some(replacement)) = (target, replacement) else {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "edit_shape",
            ));
        };
        text = apply_replacement(&text, target, replacement).map_err(|err| {
            let detail = err.detail_code.unwrap_or_default();
            BistreError::with_detail(err.key, format!("edit={index};{detail}"))
        })?;
    }
    Ok(text)
}

fn write_with_checkpoint(
    storage: &StorageHandle,
    dir: &Dir,
    (thread_id, run_id): (&str, Option<&str>),
    tool_name: &str,
    rel: &str,
    before: Option<&str>,
    after: &str,
) -> BistreResult<ToolExecutionOutput> {
    let (before_digest, before_text) = match before {
        Some(text) => (bytes_blake3(text.as_bytes()), text),
        None => (ABSENT_FILE_DIGEST.to_owned(), ""),
    };
    let diff = compute_unified_diff(before_text, after);
    let cp = storage.save_workspace_checkpoint(
        thread_id.to_owned(),
        run_id.map(str::to_owned),
        None,
        rel.to_owned(),
        before_digest,
        bytes_blake3(after.as_bytes()),
        before_text.as_bytes().to_vec(),
    )?;
    create_parent(dir, rel)?;
    atomic_write_in_dir(dir, rel, after.as_bytes())?;
    let verb = if before.is_some() { "wrote" } else { "created" };
    Ok(output(
        tool_name,
        ToolRiskTier::Tier1ReversibleEdit,
        format!("{verb} {rel} (checkpoint {})", cp.id),
        Some(diff),
        Some(cp.id),
    ))
}

fn move_file(
    storage: &StorageHandle,
    dir: &Dir,
    thread_id: &str,
    run_id: Option<&str>,
    from: &str,
    to: &str,
) -> BistreResult<ToolExecutionOutput> {
    within_read_cap(dir, from)?;
    let bytes = dir
        .read(from)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "move_not_a_file"))?;
    match dir.symlink_metadata(to) {
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Ok(_) => {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "move_target_exists",
            ));
        }
        Err(_) => {
            return Err(BistreError::with_detail(
                DiagnosticKey::InternalError,
                "move_target",
            ));
        }
    }
    let digest = bytes_blake3(&bytes);
    // The source checkpoint brings the file back; the target one removes the moved copy.
    let source_cp = storage.save_workspace_checkpoint(
        thread_id.to_owned(),
        run_id.map(str::to_owned),
        None,
        from.to_owned(),
        digest.clone(),
        ABSENT_FILE_DIGEST.to_owned(),
        bytes,
    )?;
    storage.save_workspace_checkpoint(
        thread_id.to_owned(),
        run_id.map(str::to_owned),
        None,
        to.to_owned(),
        ABSENT_FILE_DIGEST.to_owned(),
        digest,
        Vec::new(),
    )?;
    create_parent(dir, to)?;
    dir.rename(from, dir, to)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "move_failed"))?;
    Ok(output(
        "fs_move",
        ToolRiskTier::Tier1ReversibleEdit,
        format!("moved {from} to {to} (checkpoint {})", source_cp.id),
        None,
        Some(source_cp.id),
    ))
}

fn delete_file(
    storage: &StorageHandle,
    dir: &Dir,
    thread_id: &str,
    run_id: Option<&str>,
    rel: &str,
) -> BistreResult<ToolExecutionOutput> {
    let is_file = dir
        .symlink_metadata(rel)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "delete_not_found"))?
        .is_file();
    if !is_file {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "delete_not_a_file",
        ));
    }
    within_read_cap(dir, rel)?;
    let bytes = dir
        .read(rel)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "file_read"))?;
    let cp = storage.save_workspace_checkpoint(
        thread_id.to_owned(),
        run_id.map(str::to_owned),
        None,
        rel.to_owned(),
        bytes_blake3(&bytes),
        ABSENT_FILE_DIGEST.to_owned(),
        bytes,
    )?;
    dir.remove_file(rel)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "delete_failed"))?;
    Ok(output(
        "fs_delete",
        ToolRiskTier::Tier1ReversibleEdit,
        format!("deleted {rel} (checkpoint {})", cp.id),
        None,
        Some(cp.id),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::tool_rewind_checkpoint;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    /// The temp root, its database, the workspace folder, and a thread id.
    type Setup = (
        tempfile::TempDir,
        std::sync::Arc<StorageHandle>,
        PathBuf,
        String,
    );

    fn setup() -> Result<Setup, Box<dyn std::error::Error>> {
        let tmp = tempfile::tempdir()?;
        let storage = StorageHandle::open(tmp.path().join("db.sqlite3"))?;
        let thread =
            storage.create_thread(None, "Files", bistre_protocol::ThreadMode::Code, None, None)?;
        let ws = tmp.path().join("ws");
        std::fs::create_dir_all(ws.join("src"))?;
        std::fs::write(ws.join("src/a.txt"), "one\ntwo\nthree\n")?;
        std::fs::write(ws.join(".env"), "SECRET=1")?;
        Ok((tmp, storage, ws, thread.id))
    }

    fn call(
        storage: &StorageHandle,
        ledger: &ReadLedger,
        ws: &Path,
        thread: &str,
        name: &str,
        args: &Value,
    ) -> BistreResult<ToolExecutionOutput> {
        run(
            storage,
            ledger,
            &[ws.to_path_buf()],
            thread,
            Some("run"),
            name,
            args,
        )
    }

    #[test]
    fn fs_list_shows_folders_and_sizes_and_hides_secrets() -> TestResult {
        let (_tmp, storage, ws, thread) = setup()?;
        let ledger = ReadLedger::default();
        let top = call(&storage, &ledger, &ws, &thread, "fs_list", &json!({}))?;
        assert_eq!(top.output_text, "src/");
        let src = call(
            &storage,
            &ledger,
            &ws,
            &thread,
            "fs_list",
            &json!({ "path": "src" }),
        )?;
        assert_eq!(src.output_text, "a.txt\t14 bytes");
        let escape = call(
            &storage,
            &ledger,
            &ws,
            &thread,
            "fs_list",
            &json!({ "path": ".." }),
        );
        assert!(escape.is_err());
        Ok(())
    }

    /// A file past the read cap is never loaded: deleting or moving it is refused and the
    /// file stays; a multi-edit result carries its own tool name.
    #[test]
    fn fs_tools_refuse_files_past_the_read_cap() -> TestResult {
        let (_tmp, storage, ws, thread) = setup()?;
        let ledger = ReadLedger::default();
        let big = std::fs::File::create(ws.join("big.bin"))?;
        big.set_len(MAX_READ_FILE_BYTES + 1)?;
        drop(big);
        for (name, args) in [
            ("fs_delete", json!({ "path": "big.bin" })),
            ("fs_move", json!({ "from": "big.bin", "to": "moved.bin" })),
        ] {
            let refused = call(&storage, &ledger, &ws, &thread, name, &args);
            assert_eq!(
                refused.err().and_then(|e| e.detail_code).as_deref(),
                Some("file_too_large"),
                "{name}"
            );
        }
        assert!(ws.join("big.bin").exists());
        assert!(!ws.join("moved.bin").exists());

        let edited = call(
            &storage,
            &ledger,
            &ws,
            &thread,
            "fs_multi_edit",
            &json!({ "path": "src/a.txt", "edits": [{ "target": "two", "replacement": "2" }] }),
        )?;
        assert_eq!(edited.tool_name, "fs_multi_edit");
        Ok(())
    }

    #[test]
    fn fs_write_creates_and_rewind_removes_but_overwrite_needs_a_fresh_read() -> TestResult {
        let (_tmp, storage, ws, thread) = setup()?;
        let ledger = ReadLedger::default();
        let made = call(
            &storage,
            &ledger,
            &ws,
            &thread,
            "fs_write",
            &json!({ "path": "new/b.txt", "content": "hello\n" }),
        )?;
        assert_eq!(std::fs::read_to_string(ws.join("new/b.txt"))?, "hello\n");
        let cp = made.checkpoint_id.ok_or("checkpoint")?;
        tool_rewind_checkpoint(&storage, &ws, &cp)?;
        assert!(!ws.join("new/b.txt").exists());

        let blind = call(
            &storage,
            &ledger,
            &ws,
            &thread,
            "fs_write",
            &json!({ "path": "src/a.txt", "content": "gone\n" }),
        );
        assert_eq!(
            blind.err().and_then(|e| e.detail_code).as_deref(),
            Some("read_before_overwrite")
        );
        assert_eq!(
            std::fs::read_to_string(ws.join("src/a.txt"))?,
            "one\ntwo\nthree\n"
        );

        ledger.record(
            &thread,
            "src/a.txt",
            &crate::tools::file_digest(&ws, "src/a.txt")?,
        );
        let replaced = call(
            &storage,
            &ledger,
            &ws,
            &thread,
            "fs_write",
            &json!({ "path": "src/a.txt", "content": "new\n" }),
        )?;
        assert_eq!(std::fs::read_to_string(ws.join("src/a.txt"))?, "new\n");
        tool_rewind_checkpoint(&storage, &ws, &replaced.checkpoint_id.ok_or("checkpoint")?)?;
        assert_eq!(
            std::fs::read_to_string(ws.join("src/a.txt"))?,
            "one\ntwo\nthree\n"
        );

        let secret = call(
            &storage,
            &ledger,
            &ws,
            &thread,
            "fs_write",
            &json!({ "path": ".env", "content": "x" }),
        );
        assert!(secret.is_err());
        Ok(())
    }

    #[test]
    fn fs_multi_edit_applies_all_edits_or_none() -> TestResult {
        let (_tmp, storage, ws, thread) = setup()?;
        let ledger = ReadLedger::default();
        let failed = call(
            &storage,
            &ledger,
            &ws,
            &thread,
            "fs_multi_edit",
            &json!({
                "path": "src/a.txt",
                "edits": [
                    { "target": "one", "replacement": "1" },
                    { "target": "missing", "replacement": "x" }
                ]
            }),
        );
        assert!(
            failed
                .err()
                .and_then(|e| e.detail_code)
                .is_some_and(|d| d.starts_with("edit=1;"))
        );
        assert_eq!(
            std::fs::read_to_string(ws.join("src/a.txt"))?,
            "one\ntwo\nthree\n"
        );
        call(
            &storage,
            &ledger,
            &ws,
            &thread,
            "fs_multi_edit",
            &json!({
                "path": "src/a.txt",
                "edits": [
                    { "target": "one", "replacement": "1" },
                    { "target": "three", "replacement": "3" }
                ]
            }),
        )?;
        assert_eq!(
            std::fs::read_to_string(ws.join("src/a.txt"))?,
            "1\ntwo\n3\n"
        );
        Ok(())
    }

    #[test]
    fn fs_move_never_replaces_and_fs_delete_rewinds() -> TestResult {
        let (_tmp, storage, ws, thread) = setup()?;
        let ledger = ReadLedger::default();
        std::fs::write(ws.join("src/b.txt"), "keep")?;
        let clash = call(
            &storage,
            &ledger,
            &ws,
            &thread,
            "fs_move",
            &json!({ "from": "src/a.txt", "to": "src/b.txt" }),
        );
        assert_eq!(
            clash.err().and_then(|e| e.detail_code).as_deref(),
            Some("move_target_exists")
        );
        assert_eq!(std::fs::read_to_string(ws.join("src/b.txt"))?, "keep");

        let moved = call(
            &storage,
            &ledger,
            &ws,
            &thread,
            "fs_move",
            &json!({ "from": "src/a.txt", "to": "docs/a.txt" }),
        )?;
        assert!(!ws.join("src/a.txt").exists());
        assert_eq!(
            std::fs::read_to_string(ws.join("docs/a.txt"))?,
            "one\ntwo\nthree\n"
        );
        tool_rewind_checkpoint(&storage, &ws, &moved.checkpoint_id.ok_or("checkpoint")?)?;
        assert_eq!(
            std::fs::read_to_string(ws.join("src/a.txt"))?,
            "one\ntwo\nthree\n"
        );

        let folder = call(
            &storage,
            &ledger,
            &ws,
            &thread,
            "fs_delete",
            &json!({ "path": "src" }),
        );
        assert_eq!(
            folder.err().and_then(|e| e.detail_code).as_deref(),
            Some("delete_not_a_file")
        );
        let deleted = call(
            &storage,
            &ledger,
            &ws,
            &thread,
            "fs_delete",
            &json!({ "path": "src/b.txt" }),
        )?;
        assert!(!ws.join("src/b.txt").exists());
        tool_rewind_checkpoint(&storage, &ws, &deleted.checkpoint_id.ok_or("checkpoint")?)?;
        assert_eq!(std::fs::read_to_string(ws.join("src/b.txt"))?, "keep");
        Ok(())
    }

    #[test]
    fn rewinding_a_created_file_keeps_later_changes() -> TestResult {
        let (_tmp, storage, ws, thread) = setup()?;
        let ledger = ReadLedger::default();
        let made = call(
            &storage,
            &ledger,
            &ws,
            &thread,
            "fs_write",
            &json!({ "path": "c.txt", "content": "first" }),
        )?;
        std::fs::write(ws.join("c.txt"), "the user changed this")?;
        let rewind =
            tool_rewind_checkpoint(&storage, &ws, &made.checkpoint_id.ok_or("checkpoint")?);
        assert!(rewind.is_err());
        assert_eq!(
            std::fs::read_to_string(ws.join("c.txt"))?,
            "the user changed this"
        );
        Ok(())
    }
}
