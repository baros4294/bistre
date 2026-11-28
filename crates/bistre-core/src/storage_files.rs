//! Data-directory Storage & File Manager plus safe Export/Import for chats and settings.
//!
//! Invariants:
//! - Every path stays strictly inside `data_dir` (zero path traversal, zero UNC paths).
//! - Live SQLite files (`bistre.db*`) and vault key material (`vault*`) are marked non-deletable.
//! - Imported settings pass through fail-closed sanitization (never smuggling workspace/shell/MCP
//!   or UNC paths from untrusted exports).

use std::collections::HashSet;
use std::path::Path;
use std::time::UNIX_EPOCH;

use bistre_protocol::{
    AppSettings, BistreError, BistreResult, DiagnosticKey, NodeRole, StorageFileEntry, ThreadMode,
    ThreadPatch,
};
use bistre_storage::StorageHandle;
use serde::{Deserialize, Serialize};

use crate::attachments::parse_node_attachments;
use crate::import_policy::is_windows_unc_path;

/// Maximum files listed in the Storage File Manager to keep UI snappy.
const MAX_LISTED_FILES: usize = 512;
/// Maximum JSON size accepted when importing chats or settings (`32 MiB`).
const MAX_IMPORT_JSON_BYTES: usize = 32 * 1024 * 1024;

fn is_protected_file(rel_path: &str) -> bool {
    let lower = rel_path.to_ascii_lowercase();
    lower == "bistre.sqlite"
        || lower == "bistre.sqlite-wal"
        || lower == "bistre.sqlite-shm"
        || lower == "bistre.sqlite-journal"
        || lower == "bistre.db"
        || lower == "bistre.db-wal"
        || lower == "bistre.db-shm"
        || lower.starts_with("vault")
        || Path::new(&lower)
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("lock"))
}

fn categorize_rel_path(rel_path: &str) -> &'static str {
    let lower = rel_path.to_ascii_lowercase();
    if lower.starts_with("bistre.sqlite")
        || lower.starts_with("bistre.db")
        || lower.starts_with("vault")
    {
        "database"
    } else if lower.starts_with("attachments/") {
        "attachments"
    } else if lower.starts_with("media/") {
        "media"
    } else if lower.starts_with("updates/") || lower.starts_with("ota") {
        "updates"
    } else if lower.contains("cache")
        || lower.starts_with("tmp")
        || Path::new(&lower)
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("tmp"))
    {
        "cache"
    } else {
        "other"
    }
}

/// Walks `data_dir` (bounded depth <= 3, <= 512 entries) and returns file entries sorted by size desc.
pub fn list_storage_files(data_dir: &Path) -> BistreResult<Vec<StorageFileEntry>> {
    let mut entries = Vec::new();
    walk_bounded(data_dir, data_dir, 0, &mut entries);
    entries.sort_by(|a, b| {
        b.size_bytes
            .cmp(&a.size_bytes)
            .then_with(|| a.rel_path.cmp(&b.rel_path))
    });
    Ok(entries)
}

fn walk_bounded(root: &Path, dir: &Path, depth: u8, out: &mut Vec<StorageFileEntry>) {
    if depth > 3 || out.len() >= MAX_LISTED_FILES {
        return;
    }
    let Ok(read_dir) = std::fs::read_dir(dir) else {
        return;
    };
    for item in read_dir.flatten() {
        if out.len() >= MAX_LISTED_FILES {
            break;
        }
        let path = item.path();
        let Ok(meta) = item.metadata() else {
            continue;
        };
        if meta.is_dir() {
            walk_bounded(root, &path, depth + 1, out);
            continue;
        }
        if !meta.is_file() {
            continue;
        }
        let Ok(rel) = path.strip_prefix(root) else {
            continue;
        };
        let rel_str = rel.to_string_lossy().replace('\\', "/");
        let modified_ms = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX));
        out.push(StorageFileEntry {
            category: categorize_rel_path(&rel_str).to_owned(),
            deletable: !is_protected_file(&rel_str),
            rel_path: rel_str,
            size_bytes: meta.len(),
            modified_ms,
        });
    }
}

/// Deletes a single non-protected file strictly inside `data_dir`.
pub fn delete_storage_file(data_dir: &Path, rel_path: &str) -> BistreResult<bool> {
    let clean = rel_path.trim().replace('\\', "/");
    if clean.is_empty()
        || clean.starts_with('/')
        || clean.contains("..")
        || clean.contains(':')
        || is_windows_unc_path(&clean)
        || is_protected_file(&clean)
    {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "storage_file_protected",
        ));
    }
    let full = data_dir.join(&clean);
    if !full.is_file() {
        return Ok(false);
    }
    std::fs::remove_file(&full).map_err(|_| {
        BistreError::with_detail(DiagnosticKey::InternalError, "storage_delete_file")
    })?;
    Ok(true)
}

/// An update slot (`ota_staging/<version>/`) is stale only once that version is no
/// longer newer than the running one; a staged, newer update is kept for install.
fn is_stale_update(rel_path: &str) -> bool {
    let mut parts = rel_path.split('/');
    match (parts.next(), parts.next(), parts.next()) {
        (Some("ota_staging"), Some(version), Some(_)) => {
            !crate::ota::is_semver_newer(version, crate::CORE_VERSION)
        }
        _ => false,
    }
}

/// Removes unreferenced attachment blobs and stale temporary/staged files, returning bytes freed.
pub fn clean_unused_storage_files(data_dir: &Path, storage: &StorageHandle) -> BistreResult<u64> {
    let mut referenced_attachments: HashSet<String> = HashSet::new();
    let threads = storage.list_threads(None)?;
    for thread in threads {
        let nodes = storage.list_nodes(&thread.id)?;
        for node in nodes {
            for att in parse_node_attachments(node.provider_meta_json.as_deref()) {
                referenced_attachments.insert(att.blob_rel_path.replace('\\', "/"));
            }
        }
    }

    let mut freed = 0_u64;
    let files = list_storage_files(data_dir)?;
    for entry in files {
        if !entry.deletable {
            continue;
        }
        let is_orphan_attachment =
            entry.category == "attachments" && !referenced_attachments.contains(&entry.rel_path);
        let is_temp = Path::new(&entry.rel_path).extension().is_some_and(|ext| {
            ext.eq_ignore_ascii_case("tmp") || ext.eq_ignore_ascii_case("partial")
        }) || entry.rel_path.contains("/.tmp-");
        if is_orphan_attachment || is_temp || is_stale_update(&entry.rel_path) {
            let full = data_dir.join(&entry.rel_path);
            if std::fs::remove_file(&full).is_ok() {
                freed = freed.saturating_add(entry.size_bytes);
            }
        }
    }
    storage.reclaim_storage()?;
    Ok(freed)
}

#[derive(Debug, Serialize, Deserialize)]
struct ChatArchiveBundle {
    format_version: u32,
    exported_at_ms: i64,
    threads: Vec<ExportedThreadBundle>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ExportedThreadBundle {
    title: String,
    mode: ThreadMode,
    topic: String,
    is_pinned: bool,
    nodes: Vec<ExportedNodeBundle>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ExportedNodeBundle {
    id: String,
    parent_id: Option<String>,
    role: NodeRole,
    content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    provider_meta_json: Option<String>,
}

/// Strips volatile/provider-opaque keys (cryptographic signatures, server response IDs, encrypted
/// blobs) from `provider_meta_json` while keeping portable thinking text, attachments, and usage.
fn sanitize_portable_meta(raw: Option<&str>) -> Option<String> {
    let text = raw?;
    let mut val = serde_json::from_str::<serde_json::Value>(text).ok()?;
    if let Some(obj) = val.as_object_mut() {
        for volatile in [
            "server_state",
            "reasoning_blocks",
            "signature",
            "encrypted_content",
            "thought_signature",
            "redacted_thinking",
            "response_id",
            "interaction_id",
        ] {
            obj.remove(volatile);
        }
        // A Gemini signature also rides on each stored tool call.
        if let Some(serde_json::Value::Array(calls)) = obj.get_mut("tool_calls") {
            for call in calls
                .iter_mut()
                .filter_map(serde_json::Value::as_object_mut)
            {
                call.remove("thought_signature");
            }
        }
        if obj.is_empty() {
            return None;
        }
    }
    serde_json::to_string(&val).ok()
}

/// Exports every thread and its message tree as a portable JSON archive.
pub fn export_all_threads_json(storage: &StorageHandle) -> BistreResult<String> {
    let threads = storage.list_threads(None)?;
    let mut exported = Vec::with_capacity(threads.len());
    for thread in threads {
        let nodes = storage.list_nodes(&thread.id)?;
        exported.push(ExportedThreadBundle {
            title: thread.title,
            mode: thread.mode,
            topic: thread.topic,
            is_pinned: thread.is_pinned,
            nodes: nodes
                .into_iter()
                .map(|n| ExportedNodeBundle {
                    id: n.id,
                    parent_id: n.parent_id,
                    role: n.role,
                    content: n.content,
                    provider_meta_json: sanitize_portable_meta(n.provider_meta_json.as_deref()),
                })
                .collect(),
        });
    }
    let now_ms = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX));
    let bundle = ChatArchiveBundle {
        format_version: 2,
        exported_at_ms: now_ms,
        threads: exported,
    };
    serde_json::to_string_pretty(&bundle)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "export_threads_json"))
}

/// Imports threads from either a `ChatArchiveBundle` JSON (all chats) or a single-thread export JSON.
pub fn import_threads_json(storage: &StorageHandle, raw_json: &str) -> BistreResult<u32> {
    if raw_json.len() > MAX_IMPORT_JSON_BYTES {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "import_too_large",
        ));
    }
    let bundles: Vec<ExportedThreadBundle> =
        if let Ok(multi) = serde_json::from_str::<ChatArchiveBundle>(raw_json) {
            multi.threads
        } else if let Ok(single) = serde_json::from_str::<ExportedThreadBundle>(raw_json) {
            vec![single]
        } else {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "import_threads_invalid_json",
            ));
        };

    let mut imported_count = 0_u32;
    for bundle in bundles.into_iter().take(500) {
        let title = if bundle.title.trim().is_empty() {
            "Imported chat".to_owned()
        } else {
            bundle.title
        };
        let created = storage.create_thread(
            None,
            &title,
            bundle.mode,
            if bundle.topic.trim().is_empty() {
                None
            } else {
                Some(bundle.topic.as_str())
            },
            None,
        )?;
        if bundle.is_pinned {
            storage.update_thread(
                created.id.clone(),
                ThreadPatch {
                    is_pinned: Some(true),
                    ..ThreadPatch::default()
                },
            )?;
        }
        let mut id_map: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        for node in bundle.nodes.into_iter().take(2_000) {
            let mapped_parent = node
                .parent_id
                .as_ref()
                .and_then(|old| id_map.get(old))
                .cloned();
            let saved = storage.append_node(
                created.id.clone(),
                mapped_parent,
                node.role,
                node.content,
                sanitize_portable_meta(node.provider_meta_json.as_deref()),
            )?;
            id_map.insert(node.id, saved.id);
        }
        imported_count = imported_count.saturating_add(1);
    }
    Ok(imported_count)
}

/// Exports user settings (excluding vault secrets) as pretty JSON.
pub fn export_settings_json(storage: &StorageHandle) -> BistreResult<String> {
    let settings = storage.load_settings()?;
    serde_json::to_string_pretty(&settings)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "export_settings_json"))
}

/// Imports user settings JSON safely.
///
/// - Only known settings fields are accepted (an unknown field is refused, so a file from a
///   different build cannot smuggle in values this build does not show).
/// - A file that would loosen safety (a more permissive trust preset, or a higher or removed
///   daily spending limit) is refused with `diag.import.loosens_safety` unless
///   `allow_loosening` says the user confirmed it; an unreadable current settings row counts
///   as "would loosen".
/// - UNC paths are cleared. The engine revokes outstanding tool permits after every import.
pub fn import_settings_json(
    storage: &StorageHandle,
    raw_json: &str,
    allow_loosening: bool,
) -> BistreResult<AppSettings> {
    if raw_json.len() > MAX_IMPORT_JSON_BYTES {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "import_too_large",
        ));
    }
    let invalid =
        || BistreError::with_detail(DiagnosticKey::InvalidInput, "import_settings_invalid_json");
    let value: serde_json::Value = serde_json::from_str(raw_json).map_err(|_| invalid())?;
    let known = serde_json::to_value(AppSettings::default()).map_err(|_| invalid())?;
    let (Some(fields), Some(known_fields)) = (value.as_object(), known.as_object()) else {
        return Err(invalid());
    };
    if fields.keys().any(|k| !known_fields.contains_key(k)) {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "import_unknown_field",
        ));
    }
    let mut incoming: AppSettings = serde_json::from_value(value).map_err(|_| invalid())?;
    let loosens = storage
        .load_settings()
        .map_or(true, |current| loosens_safety(&current, &incoming));
    if loosens && !allow_loosening {
        return Err(BistreError::new(DiagnosticKey::ImportLoosensSafety));
    }
    if is_windows_unc_path(&incoming.prose_font_path) {
        incoming.prose_font_path.clear();
    }
    if is_windows_unc_path(&incoming.mono_font_path) {
        incoming.mono_font_path.clear();
    }
    if is_windows_unc_path(&incoming.ota_feed_url) {
        incoming.ota_feed_url.clear();
    }
    storage.save_settings(incoming)
}

/// How much a trust preset lets tools run without asking (higher is looser).
const fn trust_looseness(preset: bistre_protocol::TrustPreset) -> u8 {
    match preset {
        bistre_protocol::TrustPreset::Off => 0,
        bistre_protocol::TrustPreset::Strict => 1,
        bistre_protocol::TrustPreset::GuidedCraft => 2,
        bistre_protocol::TrustPreset::UnchainedSandbox => 3,
    }
}

/// Whether `incoming` allows more than `current`: a looser trust preset, or a removed or
/// higher daily spending limit.
fn loosens_safety(current: &AppSettings, incoming: &AppSettings) -> bool {
    let looser_trust =
        trust_looseness(incoming.trust_preset) > trust_looseness(current.trust_preset);
    let looser_cap = match (
        current.wallet_daily_ceiling_micros,
        incoming.wallet_daily_ceiling_micros,
    ) {
        (Some(_), None) => true,
        (Some(cur), Some(new)) => new > cur,
        (None, _) => false,
    };
    looser_trust || looser_cap
}
#[cfg(test)]
mod tests {
    use super::*;

    /// Cleaning never deletes an update that is staged to install; it removes only
    /// unfinished downloads and slots for versions already installed.
    #[test]
    fn cleaning_keeps_a_staged_update() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("bistre.sqlite"))?;
        let staged = dir.path().join("ota_staging").join("999.0.0");
        std::fs::create_dir_all(&staged)?;
        std::fs::write(staged.join("payload.bin"), b"signed payload")?;
        std::fs::write(staged.join("payload.bin.partial"), b"half")?;
        let old = dir.path().join("ota_staging").join("0.0.1");
        std::fs::create_dir_all(&old)?;
        std::fs::write(old.join("payload.bin"), b"installed long ago")?;
        clean_unused_storage_files(dir.path(), &storage)?;
        assert!(
            staged.join("payload.bin").exists(),
            "the staged update stays"
        );
        assert!(!staged.join("payload.bin.partial").exists());
        assert!(
            !old.join("payload.bin").exists(),
            "an installed version's slot goes"
        );
        Ok(())
    }

    #[test]
    fn live_sqlite_db_is_never_deletable() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        std::fs::write(dir.path().join("bistre.sqlite"), b"sqlite")?;
        std::fs::write(dir.path().join("bistre.sqlite-wal"), b"wal")?;
        std::fs::write(dir.path().join("bistre.sqlite-shm"), b"shm")?;
        std::fs::write(dir.path().join("vault.bin"), b"secret")?;
        std::fs::write(dir.path().join("cache.tmp"), b"temp")?;

        let files = list_storage_files(dir.path())?;
        for protected in [
            "bistre.sqlite",
            "bistre.sqlite-wal",
            "bistre.sqlite-shm",
            "vault.bin",
        ] {
            let entry = files
                .iter()
                .find(|f| f.rel_path == protected)
                .ok_or("missing entry")?;
            assert!(!entry.deletable, "{protected} must NOT be deletable");
            assert!(delete_storage_file(dir.path(), protected).is_err());
        }
        let tmp = files
            .iter()
            .find(|f| f.rel_path == "cache.tmp")
            .ok_or("missing tmp")?;
        assert!(tmp.deletable);
        Ok(())
    }

    #[test]
    fn export_import_preserves_sanitized_metadata() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("bistre.sqlite"))?;
        let thread = storage.create_thread(None, "Meta", ThreadMode::Chat, None, None)?;
        let meta = serde_json::json!({
            "thinking_text": "step 1",
            "signature": "opaque_sig_must_not_export",
            "encrypted_content": "enc_must_not_export",
            "input_tokens": 42,
            "tool_calls": [{ "call_id": "c1", "name": "read", "arguments_json": "{}", "thought_signature": "call_sig_must_not_export" }]
        })
        .to_string();
        storage.append_node(
            thread.id.clone(),
            None,
            NodeRole::Assistant,
            "Answer".to_owned(),
            Some(meta),
        )?;
        let exported = export_all_threads_json(&storage)?;
        assert!(exported.contains("thinking_text"));
        assert!(!exported.contains("opaque_sig_must_not_export"));
        assert!(!exported.contains("enc_must_not_export"));
        assert!(!exported.contains("call_sig_must_not_export"), "{exported}");
        assert!(exported.contains("call_id"), "the call itself stays");

        let imported_count = import_threads_json(&storage, &exported)?;
        assert_eq!(imported_count, 1);
        let all = storage.list_threads(None)?;
        let imported = all
            .iter()
            .find(|t| t.id != thread.id)
            .ok_or("no imported")?;
        let nodes = storage.list_nodes(&imported.id)?;
        let restored_meta = nodes[0].provider_meta_json.as_deref().unwrap_or("");
        assert!(restored_meta.contains("thinking_text"));
        Ok(())
    }

    fn engine_storage()
    -> Result<(tempfile::TempDir, std::sync::Arc<StorageHandle>), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("s.sqlite"))?;
        Ok((dir, storage))
    }

    /// An imported settings file can never loosen trust or the spending limit unless the
    /// user confirms, and unknown fields are refused.
    #[test]
    fn settings_import_never_loosens_safety_without_confirmation()
    -> Result<(), Box<dyn std::error::Error>> {
        let (_dir, storage) = engine_storage()?;
        let mut current = storage.load_settings()?;
        current.trust_preset = bistre_protocol::TrustPreset::Strict;
        current.wallet_daily_ceiling_micros =
            Some(bistre_protocol::MoneyMicros::from_micros(1_000_000));
        storage.save_settings(current.clone())?;

        let mut looser = current.clone();
        looser.trust_preset = bistre_protocol::TrustPreset::UnchainedSandbox;
        let raw = serde_json::to_string(&looser)?;
        assert_eq!(
            import_settings_json(&storage, &raw, false)
                .err()
                .map(|e| e.key),
            Some(DiagnosticKey::ImportLoosensSafety)
        );
        assert_eq!(
            storage.load_settings()?.trust_preset,
            bistre_protocol::TrustPreset::Strict
        );

        let mut uncapped = current.clone();
        uncapped.wallet_daily_ceiling_micros = None;
        let raw_uncapped = serde_json::to_string(&uncapped)?;
        assert!(import_settings_json(&storage, &raw_uncapped, false).is_err());

        let mut stricter = current.clone();
        stricter.trust_preset = bistre_protocol::TrustPreset::Off;
        assert!(import_settings_json(&storage, &serde_json::to_string(&stricter)?, false).is_ok());

        assert!(
            import_settings_json(&storage, &raw, true).is_ok(),
            "confirmed import applies"
        );
        assert_eq!(
            storage.load_settings()?.trust_preset,
            bistre_protocol::TrustPreset::UnchainedSandbox
        );

        let mut extra: serde_json::Value = serde_json::to_value(&current)?;
        if let Some(obj) = extra.as_object_mut() {
            obj.insert("unknown_switch".to_owned(), serde_json::Value::Bool(true));
        }
        assert_eq!(
            import_settings_json(&storage, &extra.to_string(), true)
                .err()
                .and_then(|e| e.detail_code),
            Some("import_unknown_field".to_owned())
        );
        Ok(())
    }
}
