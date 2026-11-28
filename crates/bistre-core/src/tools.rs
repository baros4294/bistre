//! Zero-fork in-process Rust workspace tools, capability-scoped edits with `blake3` hash anchors,
//! `imara-diff` unified diffs, pre-image SQLite checkpoints for 1-click Rewind, guarded shell
//! execution, web fetch/search, and malformed tool-call self-healing (Spec 04 & 06).

use bistre_protocol::lock_or_recover;
use std::collections::VecDeque;
use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, ToolRiskTier};
use bistre_storage::StorageHandle;
use cap_std::ambient_authority;
use cap_std::fs::Dir;
use globset::Glob;
use grep_regex::RegexMatcherBuilder;
use grep_searcher::Searcher;
use grep_searcher::sinks::UTF8;
use ignore::WalkBuilder;
use imara_diff::{Algorithm, BasicLineDiffPrinter, Diff, InternedInput, UnifiedDiffConfig};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::process_util::{ShellKind, decode_clixml, preferred_shell, shell_command};
pub use crate::tool_call_ids::{
    MAX_TOOL_CALL_ID_LEN, heal_and_dedup_tool_calls, sanitize_tool_call_id,
};
use crate::web_tools::truncate_utf8_in_place;
pub use crate::web_tools::{tool_web_fetch, tool_web_search, tool_web_search_with_endpoint};

pub(crate) const MAX_READ_FILE_BYTES: u64 = 2 * 1024 * 1024;
const MAX_TOOL_OUTPUT_BYTES: usize = 256 * 1024;
const MAX_GREP_MATCHES: usize = 100;
const MAX_GLOB_RESULTS: usize = 250;
/// Maximum wall-clock duration and directory entries visited per `grep`/`glob` walk.
const MAX_WALK_DURATION: Duration = Duration::from_secs(10);
const MAX_WALK_ENTRIES: usize = 50_000;
/// Maximum `(scope, path)` read fingerprints kept by [`ReadLedger`].
const MAX_READ_LEDGER_ENTRIES: usize = 512;

/// Footer appended whenever a read is cut short, so models never rewrite a file from a partial view.
pub const TRUNCATED_READ_FOOTER: &str = "[truncated read: never rewrite or overwrite this whole file from this view; read the remaining lines first]";

/// Run-scoped record of what each scope (thread/run) last read, keyed by workspace path.
///
/// An edit is rejected with `ToolStaleRead` when the file changed on disk after this scope read
/// it (another process, formatter, or the user edited it in between).
#[derive(Debug, Default)]
pub struct ReadLedger {
    entries: Mutex<VecDeque<(String, String, String)>>,
}

impl ReadLedger {
    /// Records the digest a scope observed for `rel_path` (bounded, oldest evicted).
    pub fn record(&self, scope: &str, rel_path: &str, digest: &str) {
        let mut entries = lock_or_recover(&self.entries, "read_ledger");
        let key = normalize_rel(rel_path);
        entries.retain(|(s, p, _)| !(s == scope && *p == key));
        if entries.len() >= MAX_READ_LEDGER_ENTRIES {
            entries.pop_front();
        }
        entries.push_back((scope.to_owned(), key, digest.to_owned()));
    }

    /// `Err(ToolStaleRead)` when this scope read `rel_path` and the file has changed since.
    pub fn check_fresh(
        &self,
        scope: &str,
        rel_path: &str,
        current_digest: &str,
    ) -> BistreResult<()> {
        let key = normalize_rel(rel_path);
        let stale = lock_or_recover(&self.entries, "read_ledger")
            .iter()
            .any(|(s, p, d)| s == scope && *p == key && d != current_digest);
        if stale {
            Err(BistreError::with_detail(
                DiagnosticKey::ToolStaleRead,
                "file_changed_since_read",
            ))
        } else {
            Ok(())
        }
    }

    /// Whether this scope has read `rel_path` (a whole-file overwrite requires it).
    pub fn has_read(&self, scope: &str, rel_path: &str) -> bool {
        let key = normalize_rel(rel_path);
        lock_or_recover(&self.entries, "read_ledger")
            .iter()
            .any(|(s, p, _)| s == scope && *p == key)
    }

    /// Removes cached read fingerprints for `rel_path` across scopes (e.g., after checkpoint rewind).
    pub fn invalidate_path(&self, rel_path: &str) {
        let key = normalize_rel(rel_path);
        lock_or_recover(&self.entries, "read_ledger").retain(|(_, p, _)| *p != key);
    }
}

fn normalize_rel(rel_path: &str) -> String {
    rel_path
        .trim()
        .replace('\\', "/")
        .trim_start_matches("./")
        .to_owned()
}

/// Full `blake3` digest of a workspace file (capability-scoped).
pub fn file_digest(workspace_root: &Path, rel_path: &str) -> BistreResult<String> {
    if is_forbidden_secret_path(rel_path) {
        return Err(BistreError::with_detail(
            DiagnosticKey::ToolTierBlocked,
            "tier3_secret_path_blocked",
        ));
    }
    let dir = Dir::open_ambient_dir(workspace_root, ambient_authority())
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "workspace_open"))?;
    let bytes = dir
        .read(rel_path)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "read_io"))?;
    Ok(bytes_blake3(&bytes))
}

/// 1-based line of the closest match for the first non-empty line of `target`
/// (whitespace-insensitive), used as a near-miss hint when an edit target is not found.
pub fn near_miss_line(haystack: &str, target: &str) -> Option<usize> {
    let needle: String = target
        .lines()
        .find(|l| !l.trim().is_empty())?
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if needle.is_empty() {
        return None;
    }
    haystack
        .lines()
        .position(|line| {
            let squashed = line.split_whitespace().collect::<Vec<_>>().join(" ");
            squashed == needle || (needle.len() >= 8 && squashed.contains(&needle))
        })
        .map(|idx| idx + 1)
}

/// Structured tool invocation parsed from native provider deltas or healed from leaked XML/JSON.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParsedToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
    pub healed_from_text: bool,
}

/// Result returned by executing a built-in workspace, web, or MCP tool.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolExecutionOutput {
    pub tool_name: String,
    pub risk_tier: ToolRiskTier,
    pub ok: bool,
    pub summary: String,
    pub output_text: String,
    pub diff_text: Option<String>,
    pub checkpoint_id: Option<String>,
    pub duration_ms: i64,
    /// Optional rich media attachments (e.g. screenshots or audio returned by MCP tools).
    #[serde(default)]
    pub media_attachments: Vec<bistre_protocol::StoredAttachment>,
}

/// Statically + dynamically classifies a tool call into Risk Tiers 0..=3 (Spec 06).
pub fn classify_tool_risk(tool_name: &str, args: &Value) -> ToolRiskTier {
    if tool_name != "skill_load"
        && ["path", "file_path", "from", "to"]
            .iter()
            .filter_map(|key| args.get(key).and_then(Value::as_str))
            .any(is_forbidden_secret_path)
    {
        return ToolRiskTier::Tier3Blocked;
    }

    match tool_name {
        "read" | "grep" | "glob" | "fs_list" | "diff" | "web_fetch" | "web_search"
        | "skill_load" | "agent_delegate" | "ask_user" | "history_search" | "history_open"
        | "goal_complete" => ToolRiskTier::Tier0ReadOnly,
        "agent_memory" => {
            if args.get("action").and_then(Value::as_str) == Some("list") {
                ToolRiskTier::Tier0ReadOnly
            } else {
                ToolRiskTier::Tier1ReversibleEdit
            }
        }
        "edit" | "fs_write" | "fs_multi_edit" | "fs_move" | "fs_delete" => {
            ToolRiskTier::Tier1ReversibleEdit
        }
        "shell" => {
            if let Some(cmd) = args.get("command").and_then(Value::as_str) {
                let lower = cmd.to_ascii_lowercase();
                if lower.contains("vault.bin")
                    || lower.contains("id_rsa")
                    || lower.contains("cryptunprotectdata")
                {
                    return ToolRiskTier::Tier3Blocked;
                }
            }
            ToolRiskTier::Tier2ExternalSideEffect
        }
        _ => ToolRiskTier::Tier2ExternalSideEffect,
    }
}

/// Whether `tool_name` works on the workspace folder it is given, so a worktree copy takes
/// its changes: the file tools are confined to the folder handle, and the shell starts in
/// the folder (a command can still reach outside it; Sandbox auto accepts that).
pub fn works_in_workspace(tool_name: &str) -> bool {
    matches!(
        tool_name,
        "edit" | "fs_write" | "fs_multi_edit" | "fs_move" | "fs_delete" | "shell"
    )
}

/// Returns `true` when a relative path attempts symlink/parent traversal or targets OS secrets (Tier 3).
pub fn is_forbidden_secret_path(raw: &str) -> bool {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return false;
    }
    let path = Path::new(trimmed);
    if path.is_absolute() {
        return true;
    }
    for comp in path.components() {
        if matches!(
            comp,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        ) {
            return true;
        }
    }
    let lower = trimmed.replace('\\', "/").to_ascii_lowercase();
    let base = Path::new(&lower)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    base == ".env"
        || base.starts_with(".env.")
        || base == "vault.bin"
        || base == "id_rsa"
        || base == "id_ed25519"
        || lower.contains("/.ssh/")
        || lower.starts_with(".ssh/")
        || Path::new(&lower)
            .extension()
            .is_some_and(|e| e.eq_ignore_ascii_case("pem") || e.eq_ignore_ascii_case("key"))
}

/// Computes an 8-character lowercase `blake3` hex anchor hash for a line slice.
pub fn line_range_blake3(slice: &str) -> String {
    let hex = blake3::hash(slice.as_bytes()).to_hex();
    hex.as_str()[..8].to_owned()
}

/// Computes the full lowercase `blake3` hex digest for arbitrary bytes.
pub fn bytes_blake3(bytes: &[u8]) -> String {
    blake3::hash(bytes).to_hex().as_str().to_owned()
}

/// Deterministically sorted JSON tool schemas (alphabetical by name) for LLM prompt-cache stability.
pub fn builtin_tool_schemas(include_write_tools: bool) -> Vec<Value> {
    let mut tools = vec![
        json!({
            "name": "diff",
            "description": "Compute a unified diff between two text snippets.",
            "parameters": {
                "type": "object",
                "properties": {
                    "before": { "type": "string" },
                    "after": { "type": "string" }
                },
                "required": ["before", "after"]
            }
        }),
        json!({
            "name": "glob",
            "description": "Find workspace files matching a glob pattern respecting .gitignore.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": { "type": "string" }
                },
                "required": ["pattern"]
            }
        }),
        json!({
            "name": "grep",
            "description": "Search workspace text files using ripgrep regex engine respecting .gitignore.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": { "type": "string" },
                    "subpath": { "type": "string" }
                },
                "required": ["pattern"]
            }
        }),
        json!({
            "name": "read",
            "description": "Read a workspace UTF-8 file with line numbers and blake3 line-hash anchors.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": { "type": "string" },
                    "start_line": { "type": "integer" },
                    "end_line": { "type": "integer" }
                },
                "required": ["path"]
            }
        }),
        json!({
            "name": "web_fetch",
            "description": "Fetch a public HTTP/HTTPS URL and extract clean readable text.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": { "type": "string" }
                },
                "required": ["url"]
            }
        }),
        json!({
            "name": "web_search",
            "description": "Search the public web for up-to-date information and return ranked results with titles, URLs, and snippets.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": { "type": "string" },
                    "max_results": { "type": "integer" }
                },
                "required": ["query"]
            }
        }),
    ];

    if include_write_tools {
        tools.push(json!({
            "name": "edit",
            "description": "Capability-scoped workspace file edit verified by blake3 anchor hash with automatic rewind checkpoint.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": { "type": "string" },
                    "target": { "type": "string" },
                    "replacement": { "type": "string" },
                    "expected_hash": { "type": "string" }
                },
                "required": ["path", "target", "replacement"]
            }
        }));
        tools.push(json!({
            "name": "shell",
            "description": "Run a bounded shell command inside the bound workspace directory.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": { "type": "string" },
                    "timeout_secs": { "type": "integer" }
                },
                "required": ["command"]
            }
        }));
    }

    tools.extend(crate::fs_tools::schemas(include_write_tools));
    tools.sort_by(|a, b| {
        let an = a.get("name").and_then(Value::as_str).unwrap_or("");
        let bn = b.get("name").and_then(Value::as_str).unwrap_or("");
        an.cmp(bn)
    });
    tools
}

/// Appends one formatted line; formatting into a `String` cannot fail.
fn push_line(out: &mut String, line: std::fmt::Arguments<'_>) {
    out.push_str(&line.to_string());
    out.push('\n');
}

/// Capability-scoped line-ranged UTF-8 reader returning `LINE#HASH: content` anchors.
pub fn tool_read(
    workspace_root: &Path,
    rel_path: &str,
    start_line: Option<usize>,
    end_line: Option<usize>,
) -> BistreResult<ToolExecutionOutput> {
    let started = Instant::now();
    if is_forbidden_secret_path(rel_path) {
        return Err(BistreError::with_detail(
            DiagnosticKey::ToolTierBlocked,
            "tier3_secret_path_blocked",
        ));
    }

    let dir = Dir::open_ambient_dir(workspace_root, ambient_authority())
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "workspace_open"))?;
    let meta = dir
        .metadata(rel_path)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "read_not_found"))?;
    if meta.len() > MAX_READ_FILE_BYTES {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "file_too_large",
        ));
    }

    let raw = dir
        .read(rel_path)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "read_io"))?;
    if raw.contains(&0) {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "binary_file_rejected",
        ));
    }
    let text = String::from_utf8(raw)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "invalid_utf8"))?;
    let lines: Vec<&str> = text.lines().collect();
    let total = lines.len();
    let from = start_line.unwrap_or(1).max(1);
    let to = end_line
        .unwrap_or(total.min(from.saturating_add(249)))
        .min(total);

    let mut out = String::new();
    let slice_text = if from <= to && !lines.is_empty() {
        lines[(from - 1)..to].join("\n")
    } else {
        String::new()
    };
    let range_hash = line_range_blake3(&slice_text);
    push_line(
        &mut out,
        format_args!("# {rel_path} (lines {from}..={to} of {total}, range_hash={range_hash})"),
    );

    if from <= to && !lines.is_empty() {
        for (offset, line) in lines[(from - 1)..to].iter().enumerate() {
            let line_no = from + offset;
            let h = line_range_blake3(line);
            push_line(&mut out, format_args!("{line_no}#{h}: {line}"));
            if out.len() >= MAX_TOOL_OUTPUT_BYTES {
                push_line(
                    &mut out,
                    format_args!("{TRUNCATED_READ_FOOTER} (stopped at line {line_no} of {total})"),
                );
                break;
            }
        }
        if to < total && out.len() < MAX_TOOL_OUTPUT_BYTES {
            push_line(
                &mut out,
                format_args!(
                    "{TRUNCATED_READ_FOOTER} (lines {}..={total} not shown; read with start_line={})",
                    to + 1,
                    to + 1
                ),
            );
        }
    }

    Ok(ToolExecutionOutput {
        tool_name: "read".to_owned(),
        risk_tier: ToolRiskTier::Tier0ReadOnly,
        ok: true,
        summary: format!("read {rel_path} ({from}..={to}/{total})"),
        output_text: out,
        diff_text: None,
        checkpoint_id: None,
        duration_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(0),
        media_attachments: Vec::new(),
    })
}

/// Capability-scoped hash-anchored workspace file edit with pre-image SQLite checkpoint & unified diff.
#[expect(
    clippy::too_many_arguments,
    reason = "Explicit immutable parameters for capability-scoped edit, hash check, and checkpoint persistence."
)]
pub fn tool_edit(
    storage: &StorageHandle,
    workspace_root: &Path,
    thread_id: &str,
    run_id: Option<&str>,
    rel_path: &str,
    target_text: &str,
    replacement_text: &str,
    expected_hash: Option<&str>,
) -> BistreResult<ToolExecutionOutput> {
    let started = Instant::now();
    if is_forbidden_secret_path(rel_path) {
        return Err(BistreError::with_detail(
            DiagnosticKey::ToolTierBlocked,
            "tier3_secret_path_blocked",
        ));
    }

    let dir = Dir::open_ambient_dir(workspace_root, ambient_authority())
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "workspace_open"))?;
    let pre_bytes = dir
        .read(rel_path)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "edit_not_found"))?;
    let before_text = String::from_utf8(pre_bytes.clone())
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "invalid_utf8"))?;

    if let Some(exp) = expected_hash.map(str::trim).filter(|s| !s.is_empty()) {
        let target_hash = line_range_blake3(target_text);
        let full_hash = bytes_blake3(&pre_bytes);
        if !full_hash.starts_with(exp) && target_hash != exp {
            return Err(BistreError::with_detail(
                DiagnosticKey::ToolEditHashMismatch,
                format!("expected={exp},actual_target={target_hash}"),
            ));
        }
    }

    let after_text = apply_replacement(&before_text, target_text, replacement_text)?;
    let before_digest = bytes_blake3(&pre_bytes);
    let after_digest = bytes_blake3(after_text.as_bytes());
    let unified = compute_unified_diff(&before_text, &after_text);

    // Persist pre-image snapshot BEFORE mutating disk so 1-click Rewind is guaranteed crash-safe.
    let cp = storage.save_workspace_checkpoint(
        thread_id.to_owned(),
        run_id.map(str::to_owned),
        None,
        rel_path.to_owned(),
        before_digest,
        after_digest,
        pre_bytes,
    )?;

    atomic_write_in_dir(&dir, rel_path, after_text.as_bytes())?;

    Ok(ToolExecutionOutput {
        tool_name: "edit".to_owned(),
        risk_tier: ToolRiskTier::Tier1ReversibleEdit,
        ok: true,
        summary: format!("edited {rel_path}"),
        output_text: format!("Edited {rel_path} (checkpoint {})", cp.id),
        diff_text: Some(unified),
        checkpoint_id: Some(cp.id),
        duration_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(0),
        media_attachments: Vec::new(),
    })
}

/// Replaces the first `target_text` in `before_text`, keeping a CRLF file CRLF (models usually
/// send LF-only targets and replacements). A missing target names the nearest line.
pub(crate) fn apply_replacement(
    before_text: &str,
    target_text: &str,
    replacement_text: &str,
) -> BistreResult<String> {
    let crlf_file = before_text.contains("\r\n");
    let (target_owned, replacement_owned);
    let (target_text, replacement_text) = if crlf_file && !target_text.contains('\r') {
        target_owned = target_text.replace('\n', "\r\n");
        replacement_owned = replacement_text.replace("\r\n", "\n").replace('\n', "\r\n");
        (target_owned.as_str(), replacement_owned.as_str())
    } else {
        (target_text, replacement_text)
    };
    if target_text.is_empty() || !before_text.contains(target_text) {
        let detail = near_miss_line(before_text, target_text).map_or_else(
            || "target_not_found".to_owned(),
            |line| format!("target_not_found;near_line={line}"),
        );
        return Err(BistreError::with_detail(
            DiagnosticKey::ToolEditHashMismatch,
            detail,
        ));
    }
    Ok(before_text.replacen(target_text, replacement_text, 1))
}

/// Restores a workspace file from a saved `workspace_checkpoints` pre-image snapshot (1-click Rewind).
/// A checkpoint of a file that did not exist before removes the file again, but only while it
/// still holds what the tool wrote, so a later change is never lost.
pub fn tool_rewind_checkpoint(
    storage: &StorageHandle,
    workspace_root: &Path,
    checkpoint_id: &str,
) -> BistreResult<String> {
    let cp = storage
        .get_workspace_checkpoint(checkpoint_id)?
        .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
    if is_forbidden_secret_path(&cp.file_path) {
        return Err(BistreError::with_detail(
            DiagnosticKey::ToolTierBlocked,
            "tier3_secret_path_blocked",
        ));
    }
    let dir = Dir::open_ambient_dir(workspace_root, ambient_authority())
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "workspace_open"))?;
    if cp.before_blake3 == crate::fs_tools::ABSENT_FILE_DIGEST {
        let current = dir.read(&cp.file_path).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::StorageNotFound, "rewind_file_gone")
        })?;
        if bytes_blake3(&current) != cp.after_blake3 {
            return Err(BistreError::with_detail(
                DiagnosticKey::ToolStaleRead,
                "file_changed_since_tool",
            ));
        }
        dir.remove_file(&cp.file_path).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InternalError, "rewind_remove_failed")
        })?;
        return Ok(cp.file_path);
    }
    if let Some(parent) = Path::new(&cp.file_path)
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
    {
        dir.create_dir_all(parent).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InternalError, "rewind_parent_create")
        })?;
    }
    atomic_write_in_dir(&dir, &cp.file_path, &cp.pre_image_blob)?;
    Ok(cp.file_path)
}

/// Atomic temp-file write + rename inside a `cap_std::fs::Dir` with 3-step Windows AV sharing backoff.
pub(crate) fn atomic_write_in_dir(dir: &Dir, rel_path: &str, bytes: &[u8]) -> BistreResult<()> {
    let target = Path::new(rel_path);
    let parent = target.parent().unwrap_or_else(|| Path::new(""));
    let file_name = target
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
    let tmp_rel = if parent.as_os_str().is_empty() {
        PathBuf::from(format!(".{file_name}.bistre.tmp"))
    } else {
        parent.join(format!(".{file_name}.bistre.tmp"))
    };

    let mut tmp = dir
        .create(&tmp_rel)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "temp_create"))?;
    tmp.write_all(bytes)
        .and_then(|()| tmp.sync_all())
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "temp_write"))?;
    drop(tmp);

    for attempt in 0..3_u64 {
        match dir.rename(&tmp_rel, dir, target) {
            Ok(()) => return Ok(()),
            Err(_) if attempt < 2 => {
                #[expect(
                    clippy::disallowed_methods,
                    reason = "bounded Windows sharing-violation retry (at most 75 ms in total) inside a synchronous file write"
                )]
                std::thread::sleep(Duration::from_millis(25 * (attempt + 1)));
            }
            Err(_) => {
                if dir.remove_file(&tmp_rel).is_err() {
                    tracing::debug!("atomic edit temp file was already gone");
                }
                return Err(BistreError::with_detail(
                    DiagnosticKey::InternalError,
                    "atomic_rename_failed",
                ));
            }
        }
    }
    Ok(())
}

/// Zero-fork in-process ripgrep search across workspace files honoring `.gitignore`.
pub fn tool_grep(
    workspace_root: &Path,
    pattern: &str,
    subpath: Option<&str>,
) -> BistreResult<ToolExecutionOutput> {
    let started = Instant::now();
    if let Some(sub) = subpath
        && is_forbidden_secret_path(sub)
    {
        return Err(BistreError::with_detail(
            DiagnosticKey::ToolTierBlocked,
            "tier3_secret_path_blocked",
        ));
    }

    let search_root = subpath.map_or_else(
        || workspace_root.to_path_buf(),
        |sub| workspace_root.join(sub),
    );
    let matcher = RegexMatcherBuilder::new()
        .line_terminator(Some(b'\n'))
        .build(pattern)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "invalid_grep_regex"))?;

    let mut searcher = Searcher::new();
    let mut hits = Vec::new();
    let mut total_bytes: usize = 0;
    let mut visited_entries: usize = 0;
    let mut timed_out = false;

    for entry in WalkBuilder::new(&search_root)
        .hidden(true)
        .build()
        .flatten()
    {
        visited_entries = visited_entries.saturating_add(1);
        if visited_entries > MAX_WALK_ENTRIES || started.elapsed() >= MAX_WALK_DURATION {
            timed_out = true;
            break;
        }
        if hits.len() >= MAX_GREP_MATCHES || total_bytes >= MAX_TOOL_OUTPUT_BYTES {
            break;
        }
        if !entry.file_type().is_some_and(|ft| ft.is_file()) {
            continue;
        }
        let path = entry.path();
        let rel = path
            .strip_prefix(workspace_root)
            .unwrap_or(path)
            .to_string_lossy()
            .replace('\\', "/");
        if is_forbidden_secret_path(&rel) {
            continue;
        }
        if let Err(err) = searcher.search_path(
            &matcher,
            path,
            UTF8(|line_num, line| {
                if hits.len() < MAX_GREP_MATCHES && total_bytes < MAX_TOOL_OUTPUT_BYTES {
                    let formatted = format!("{rel}:{line_num}: {}", line.trim_end());
                    total_bytes = total_bytes.saturating_add(formatted.len());
                    hits.push(formatted);
                }
                Ok(hits.len() < MAX_GREP_MATCHES)
            }),
        ) {
            tracing::debug!(%err, path = %rel, "grep skipped an unreadable file");
        }
    }

    let count = hits.len();
    let mut output_text = if hits.is_empty() {
        "No matches found.".to_owned()
    } else {
        hits.join("\n")
    };
    if timed_out {
        output_text
            .push_str("\n[search bounded by workspace walk limit; narrow the path or pattern]");
    }
    Ok(ToolExecutionOutput {
        tool_name: "grep".to_owned(),
        risk_tier: ToolRiskTier::Tier0ReadOnly,
        ok: true,
        summary: format!("grep `{pattern}` ({count} matches)"),
        output_text,
        diff_text: None,
        checkpoint_id: None,
        duration_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(0),
        media_attachments: Vec::new(),
    })
}

/// Zero-fork in-process workspace glob matcher honoring `.gitignore`.
pub fn tool_glob(workspace_root: &Path, pattern: &str) -> BistreResult<ToolExecutionOutput> {
    let started = Instant::now();
    let matcher = Glob::new(pattern)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "invalid_glob"))?
        .compile_matcher();

    let mut files = Vec::new();
    let mut visited_entries: usize = 0;
    let mut bounded = false;
    for entry in WalkBuilder::new(workspace_root)
        .hidden(true)
        .build()
        .flatten()
    {
        visited_entries = visited_entries.saturating_add(1);
        if visited_entries > MAX_WALK_ENTRIES || started.elapsed() >= MAX_WALK_DURATION {
            bounded = true;
            break;
        }
        if !entry.file_type().is_some_and(|ft| ft.is_file()) {
            continue;
        }
        let rel = entry
            .path()
            .strip_prefix(workspace_root)
            .unwrap_or_else(|_| entry.path())
            .to_string_lossy()
            .replace('\\', "/");
        if is_forbidden_secret_path(&rel) {
            continue;
        }
        if matcher.is_match(&rel) {
            files.push(rel);
            if files.len() >= MAX_GLOB_RESULTS {
                break;
            }
        }
    }
    files.sort();

    let count = files.len();
    let mut output_text = files.join("\n");
    if bounded {
        if !output_text.is_empty() {
            output_text.push('\n');
        }
        output_text.push_str("[glob bounded by workspace walk limit; narrow the pattern]");
    }
    Ok(ToolExecutionOutput {
        tool_name: "glob".to_owned(),
        risk_tier: ToolRiskTier::Tier0ReadOnly,
        ok: true,
        summary: format!("glob `{pattern}` ({count} files)"),
        output_text,
        diff_text: None,
        checkpoint_id: None,
        duration_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(0),
        media_attachments: Vec::new(),
    })
}

/// Computes a pure-Rust unified diff via `imara-diff 0.2`.
pub fn compute_unified_diff(before: &str, after: &str) -> String {
    let input = InternedInput::new(before, after);
    let mut diff = Diff::compute(Algorithm::Histogram, &input);
    diff.postprocess_lines(&input);
    let printer = BasicLineDiffPrinter(&input.interner);
    diff.unified_diff(&printer, UnifiedDiffConfig::default(), &input)
        .to_string()
}

/// Runs a bounded workspace shell command (no console window, whole-tree kill on timeout).
pub async fn tool_shell(
    workspace_root: &Path,
    command_str: &str,
    timeout_secs: u64,
) -> BistreResult<ToolExecutionOutput> {
    tool_shell_with_progress(workspace_root, command_str, timeout_secs, None).await
}

/// [`tool_shell`], sending output pieces to `progress` while the command runs.
pub async fn tool_shell_with_progress(
    workspace_root: &Path,
    command_str: &str,
    timeout_secs: u64,
    progress: Option<tokio::sync::mpsc::Sender<Vec<u8>>>,
) -> BistreResult<ToolExecutionOutput> {
    let started = Instant::now();
    if classify_tool_risk("shell", &json!({ "command": command_str })) == ToolRiskTier::Tier3Blocked
    {
        return Err(BistreError::with_detail(
            DiagnosticKey::ToolTierBlocked,
            "tier3_shell_blocked",
        ));
    }

    let clamped_timeout = Duration::from_secs(timeout_secs.clamp(1, 300));
    let shell = preferred_shell();
    let output = crate::process_util::run_bounded_with_progress(
        shell_command(shell, command_str, workspace_root),
        clamped_timeout,
        progress,
    )
    .await
    .map_err(|err| {
        if err.detail_code.as_deref() == Some("process_timeout") {
            BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "shell_timeout")
        } else {
            BistreError::with_detail(DiagnosticKey::InternalError, "shell_spawn")
        }
    })?;

    let mut combined = String::new();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let raw_stderr = String::from_utf8_lossy(&output.stderr);
    let stderr = if shell == ShellKind::Pwsh {
        decode_clixml(&raw_stderr)
    } else {
        raw_stderr.into_owned()
    };
    if !stdout.is_empty() {
        combined.push_str(&stdout);
    }
    if !stderr.is_empty() {
        if !combined.is_empty() {
            combined.push('\n');
        }
        combined.push_str("[stderr]\n");
        combined.push_str(&stderr);
    }
    if combined.len() > MAX_TOOL_OUTPUT_BYTES {
        truncate_utf8_in_place(&mut combined, MAX_TOOL_OUTPUT_BYTES);
        combined.push_str("\n...[truncated]");
    }

    let ok = output.status.success();
    let code = output.status.code().unwrap_or(-1);
    Ok(ToolExecutionOutput {
        tool_name: "shell".to_owned(),
        risk_tier: ToolRiskTier::Tier2ExternalSideEffect,
        ok,
        summary: format!("shell exit {code}"),
        output_text: combined,
        diff_text: None,
        checkpoint_id: None,
        duration_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(0),
        media_attachments: Vec::new(),
    })
}

#[cfg(test)]
#[expect(
    clippy::disallowed_methods,
    reason = "tests map errors to empty values that the following assertions reject"
)]
#[path = "tools_tests.rs"]
mod tests;
