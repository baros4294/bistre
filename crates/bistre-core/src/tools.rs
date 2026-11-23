//! Zero-fork in-process Rust workspace tools, capability-scoped edits with `blake3` hash anchors,
//! `imara-diff` unified diffs, pre-image SQLite checkpoints for 1-click Rewind, guarded shell
//! execution, web fetch/search, and Unsloth-style malformed tool-call self-healing (Spec 04 & 06).

use bistre_protocol::lock_or_recover;
use std::collections::{HashSet, VecDeque};
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
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::process_util::{ShellKind, decode_clixml, preferred_shell, run_bounded, shell_command};

const MAX_READ_FILE_BYTES: u64 = 2 * 1024 * 1024;
const MAX_TOOL_OUTPUT_BYTES: usize = 256 * 1024;
const MAX_GREP_MATCHES: usize = 100;
const MAX_GLOB_RESULTS: usize = 250;
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

/// Result returned by executing a built-in workspace or web tool.
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
}

/// Statically + dynamically classifies a tool call into Risk Tiers 0..=3 (Spec 06).
pub fn classify_tool_risk(tool_name: &str, args: &Value) -> ToolRiskTier {
    if let Some(path_str) = args
        .get("path")
        .or_else(|| args.get("file_path"))
        .and_then(Value::as_str)
        && is_forbidden_secret_path(path_str)
    {
        return ToolRiskTier::Tier3Blocked;
    }

    match tool_name {
        "read" | "grep" | "glob" | "diff" | "web_fetch" | "web_search" => {
            ToolRiskTier::Tier0ReadOnly
        }
        "edit" => ToolRiskTier::Tier1ReversibleEdit,
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
    ];

    if include_write_tools {
        tools.push(json!({
            "name": "edit",
            "description": "Capability-scoped workspace file edit verified by blake3 anchor hash with automatic rewind checkpoint.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": { "type": "string" },
                    "target_text": { "type": "string" },
                    "replacement_text": { "type": "string" },
                    "expected_hash": { "type": "string" }
                },
                "required": ["path", "target_text", "replacement_text"]
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

    // Preserve CRLF files: models usually send LF-only targets/replacements.
    let crlf_file = before_text.contains("\r\n");
    let (target_owned, replacement_owned);
    let (target_text, replacement_text) = if crlf_file && !target_text.contains('\r') {
        target_owned = target_text.replace('\n', "\r\n");
        replacement_owned = replacement_text.replace("\r\n", "\n").replace('\n', "\r\n");
        (target_owned.as_str(), replacement_owned.as_str())
    } else {
        (target_text, replacement_text)
    };

    if !before_text.contains(target_text) {
        let detail = near_miss_line(&before_text, target_text).map_or_else(
            || "target_not_found".to_owned(),
            |line| format!("target_not_found;near_line={line}"),
        );
        return Err(BistreError::with_detail(
            DiagnosticKey::ToolEditHashMismatch,
            detail,
        ));
    }

    let after_text = before_text.replacen(target_text, replacement_text, 1);
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
    })
}

/// Restores a workspace file from a saved `workspace_checkpoints` pre-image snapshot (1-click Rewind).
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
    atomic_write_in_dir(&dir, &cp.file_path, &cp.pre_image_blob)?;
    Ok(cp.file_path)
}

/// Atomic temp-file write + rename inside a `cap_std::fs::Dir` with 3-step Windows AV sharing backoff.
fn atomic_write_in_dir(dir: &Dir, rel_path: &str, bytes: &[u8]) -> BistreResult<()> {
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

    for entry in WalkBuilder::new(&search_root)
        .hidden(true)
        .build()
        .flatten()
    {
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
    Ok(ToolExecutionOutput {
        tool_name: "grep".to_owned(),
        risk_tier: ToolRiskTier::Tier0ReadOnly,
        ok: true,
        summary: format!("grep `{pattern}` ({count} matches)"),
        output_text: if hits.is_empty() {
            "No matches found.".to_owned()
        } else {
            hits.join("\n")
        },
        diff_text: None,
        checkpoint_id: None,
        duration_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(0),
    })
}

/// Zero-fork in-process workspace glob matcher honoring `.gitignore`.
pub fn tool_glob(workspace_root: &Path, pattern: &str) -> BistreResult<ToolExecutionOutput> {
    let started = Instant::now();
    let matcher = Glob::new(pattern)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "invalid_glob"))?
        .compile_matcher();

    let mut files = Vec::new();
    for entry in WalkBuilder::new(workspace_root)
        .hidden(true)
        .build()
        .flatten()
    {
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
    Ok(ToolExecutionOutput {
        tool_name: "glob".to_owned(),
        risk_tier: ToolRiskTier::Tier0ReadOnly,
        ok: true,
        summary: format!("glob `{pattern}` ({count} files)"),
        output_text: files.join("\n"),
        diff_text: None,
        checkpoint_id: None,
        duration_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(0),
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
    let output = run_bounded(
        shell_command(shell, command_str, workspace_root),
        clamped_timeout,
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
    })
}

/// Maximum bytes read from the network for one `web_fetch` (socket-level stream cap).
const MAX_WEB_FETCH_NETWORK_BYTES: usize = 2 * 1024 * 1024;
/// Maximum readable text returned to the model from one `web_fetch`.
const MAX_WEB_FETCH_TEXT_BYTES: usize = 64 * 1024;

/// Fetches a public HTTP(S) URL through `PublicWebTransport` (public-IP pinning, validated
/// redirects, streamed body cap) and returns readable text with HTML tags stripped.
pub async fn tool_web_fetch(
    web: &crate::ssrf::PublicWebTransport,
    url: &str,
) -> BistreResult<ToolExecutionOutput> {
    let started = Instant::now();
    let clean_url = url.trim();
    let fetched = web.get(clean_url, MAX_WEB_FETCH_NETWORK_BYTES).await?;
    let body = String::from_utf8_lossy(&fetched.body);
    let mut capped = strip_html_tags(&body);
    if capped.len() > MAX_WEB_FETCH_TEXT_BYTES || fetched.truncated {
        truncate_utf8_in_place(&mut capped, MAX_WEB_FETCH_TEXT_BYTES);
        capped.push_str("...[truncated]");
    }

    Ok(ToolExecutionOutput {
        tool_name: "web_fetch".to_owned(),
        risk_tier: ToolRiskTier::Tier0ReadOnly,
        ok: (200..300).contains(&fetched.status),
        summary: format!("fetch {} ({})", fetched.final_url, fetched.status),
        output_text: capped,
        diff_text: None,
        checkpoint_id: None,
        duration_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(0),
    })
}

fn truncate_utf8_in_place(text: &mut String, max_bytes: usize) {
    if text.len() <= max_bytes {
        return;
    }
    let mut cut = max_bytes;
    while cut > 0 && !text.is_char_boundary(cut) {
        cut -= 1;
    }
    text.truncate(cut);
}

fn strip_html_tags(raw: &str) -> String {
    let Ok(tag_re) = Regex::new(r"(?is)<(?:script|style)[^>]*>.*?</(?:script|style)>|<[^>]+>")
    else {
        return raw.to_owned();
    };
    let no_tags = tag_re.replace_all(raw, " ");
    no_tags.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Maximum replayed tool-call ID length.
pub const MAX_TOOL_CALL_ID_LEN: usize = 64;

/// `ReplayToolCallIds`: restricts IDs to `[A-Za-z0-9_-]{1,64}` and makes them unique, so a
/// provider never rejects replayed history over a foreign or duplicated call ID.
pub fn sanitize_tool_call_id<S: std::hash::BuildHasher>(
    raw: &str,
    seen: &mut HashSet<String, S>,
    ordinal: usize,
) -> String {
    let mut id: String = raw
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .take(MAX_TOOL_CALL_ID_LEN)
        .collect();
    if id.is_empty() {
        id = format!("call_{ordinal}");
    }
    let base = id.clone();
    let mut n = 1_usize;
    while !seen.insert(id.clone()) {
        n += 1;
        let suffix = format!("_{n}");
        let keep = MAX_TOOL_CALL_ID_LEN
            .saturating_sub(suffix.len())
            .min(base.len());
        id = format!("{}{suffix}", &base[..keep]);
    }
    id
}

/// Unsloth-inspired self-healing tool-call parser: recovers XML-leaked `<tool_call>{...}</tool_call>`
/// calls emitted as plain text by local/open models and deduplicates identical invocations.
pub fn heal_and_dedup_tool_calls(
    native_calls: Vec<ParsedToolCall>,
    assistant_text: &str,
) -> (Vec<ParsedToolCall>, String) {
    let mut out = Vec::new();
    let mut seen: HashSet<(String, String)> = HashSet::new();
    let mut seen_ids: HashSet<String> = HashSet::new();

    for mut call in native_calls {
        let sig = (call.name.clone(), call.arguments.to_string());
        if seen.insert(sig) {
            call.id = sanitize_tool_call_id(&call.id, &mut seen_ids, out.len() + 1);
            out.push(call);
        }
    }

    let Ok(re) = Regex::new(r"(?s)<tool_call>\s*(\{.*?\})\s*</tool_call>") else {
        return (out, assistant_text.to_owned());
    };
    let mut healed_idx: u32 = 0;
    for cap in re.captures_iter(assistant_text) {
        let Some(json_slice) = cap.get(1).map(|m| m.as_str()) else {
            continue;
        };
        if let Ok(val) = serde_json::from_str::<Value>(json_slice)
            && let Some(name) = val.get("name").and_then(Value::as_str)
        {
            let args = val.get("arguments").cloned().unwrap_or_else(|| json!({}));
            let sig = (name.to_owned(), args.to_string());
            if seen.insert(sig) {
                healed_idx = healed_idx.saturating_add(1);
                out.push(ParsedToolCall {
                    id: sanitize_tool_call_id(
                        &format!("healed_call_{healed_idx}"),
                        &mut seen_ids,
                        out.len() + 1,
                    ),
                    name: name.to_owned(),
                    arguments: args,
                    healed_from_text: true,
                });
            }
        }
    }

    let cleaned_text = re.replace_all(assistant_text, "").trim().to_owned();
    (out, cleaned_text)
}

#[cfg(test)]
#[expect(
    clippy::disallowed_methods,
    reason = "tests map errors to empty values that the following assertions reject"
)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

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
        let read_out = tool_read(&workspace, "hello.rs", Some(1), Some(3)).ok();
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
        )
        .ok();
        assert!(
            edit_out
                .as_ref()
                .is_some_and(|e| e.ok && e.diff_text.is_some())
        );
        assert_eq!(
            std::fs::read_to_string(&file).ok().as_deref(),
            Some("fn main() {\n    let x = 42;\n}\n")
        );

        // 1-click Rewind restores exact original bytes!
        let cp_id = edit_out.and_then(|e| e.checkpoint_id).unwrap_or_default();
        assert!(tool_rewind_checkpoint(&storage, &workspace, &cp_id).is_ok());
        assert_eq!(
            std::fs::read_to_string(&file).ok().as_deref(),
            Some("fn main() {\n    let x = 1;\n}\n")
        );

        // Grep & Glob run zero-fork in-process.
        let g = tool_grep(&workspace, "let x = 1", None).ok();
        assert!(
            g.as_ref()
                .is_some_and(|r| r.output_text.contains("hello.rs:2:"))
        );
        let gl = tool_glob(&workspace, "*.rs").ok();
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
        assert!(
            std::fs::write(ws.join("win.txt"), "alpha\r\n    beta  gamma\r\nomega\r\n").is_ok()
        );
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
        assert!(
            std::fs::write(ws.join("win.txt"), "alpha\r\n    beta  gamma\r\nomega!\r\n").is_ok()
        );
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
        let read = tool_read(&ws, "long.txt", None, None)
            .map_or_else(|_| String::new(), |o| o.output_text);
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
}
