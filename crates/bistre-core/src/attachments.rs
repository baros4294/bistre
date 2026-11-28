//! Native multimodal, PDF, Office (`.docx`/`.xlsx`/`.pptx`/`.odt`/`.ods`/`.odp`), audio, video,
//! and plain-text attachment ingestion, pure-Rust Office XML extraction, and Gemini Files API upload.
//!
//! All reads are size-bounded, UNC paths are rejected fail-closed, and blobs are stored
//! content-addressed under `<data_dir>/attachments/<blake3_hex>.<ext>` using atomic temp → sync →
//! rename.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use base64::Engine as _;
use bistre_protocol::{
    AttachmentInput, BistreError, BistreResult, DiagnosticKey, StoredAttachment, lock_or_recover,
};
use serde_json::Value;
use uuid::Uuid;

pub use crate::attachment_upload::{
    UploadedAttachmentRefs, delete_remote_file, gemini_upload_file,
    preupload_attachments_for_dialect, upload_provider_file_api,
};
use crate::import_policy::is_windows_unc_path;
pub use crate::office_text::extract_office_text;
use crate::tokenizer::count_tokens;

/// Hard upload limit per attachment (`50 MiB`).
pub const MAX_ATTACHMENT_BYTES: u64 = 50 * 1024 * 1024;
/// Maximum file size sent inline as base64 (`16 MiB`); larger files use Files API where available.
pub const MAX_INLINE_BYTES: usize = 16 * 1024 * 1024;
/// Maximum extracted text size for text/code or Office XML fallback (`512 KiB`).
pub(crate) const MAX_EXTRACTED_TEXT_BYTES: usize = 512 * 1024;
/// Maximum decompressed bytes read from any single Office ZIP archive (zip-bomb guard).
pub(crate) const MAX_OFFICE_ZIP_BYTES: usize = 4 * 1024 * 1024;
/// Maximum number of ZIP entries inspected per Office archive.
pub(crate) const MAX_OFFICE_ZIP_ENTRIES: usize = 256;
/// Gemini Files API retains uploads for 48 hours; reuse cached URIs for 40 hours.
pub(crate) const GEMINI_URI_TTL_MS: u64 = 40 * 3_600 * 1_000;
/// `OpenAI` & Anthropic Files API cache reuse window (24 hours when `store: true`).
pub(crate) const REMOTE_FILE_TTL_MS: u64 = 24 * 3_600 * 1_000;
/// Max time spent polling Gemini `PROCESSING -> ACTIVE` per file.
pub(crate) const GEMINI_POLL_MAX_WAIT: Duration = Duration::from_secs(60);
/// Format version for `<data_dir>/remote_files_cache.json`.
const REMOTE_CACHE_VERSION: u32 = 1;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct CachedRemoteRef {
    reference: String,
    expires_at_ms: u64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct PersistedRemoteCache {
    version: u32,
    entries: HashMap<String, CachedRemoteRef>,
}

static REMOTE_FILE_CACHE: LazyLock<Mutex<HashMap<String, CachedRemoteRef>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn now_epoch_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .and_then(|d| u64::try_from(d.as_millis()).ok())
        .unwrap_or(0)
}

/// Computes an API-key-isolated cache key so multi-key failover never leaks Key A's `file_uri`
/// or `file_id` under Key B (eliminating cross-key 403/404 errors).
pub fn remote_file_cache_key(
    dialect: bistre_protocol::ProviderDialect,
    base: &str,
    api_key: &str,
    blake3_hex: &str,
) -> String {
    let key_hash = crate::replay_policy::blake3_short_hash(api_key);
    format!(
        "{}::{}::{}::{}",
        dialect.as_str(),
        base.trim_end_matches('/'),
        key_hash,
        blake3_hex
    )
}

fn cache_file_path(data_dir: &Path) -> PathBuf {
    data_dir.join("remote_files_cache.json")
}

pub(crate) fn lookup_remote_cache(data_dir: &Path, key: &str) -> Option<String> {
    let now = now_epoch_ms();
    {
        let cache = lock_or_recover(&REMOTE_FILE_CACHE, "remote_file_cache");
        if let Some(entry) = cache.get(key)
            && entry.expires_at_ms > now
        {
            return Some(entry.reference.clone());
        }
    }
    // Hydrate from disk cache if present and matching `REMOTE_CACHE_VERSION`.
    let path = cache_file_path(data_dir);
    let raw = std::fs::read_to_string(&path).ok()?;
    let disk: PersistedRemoteCache = serde_json::from_str(&raw).ok()?;
    if disk.version != REMOTE_CACHE_VERSION {
        return None;
    }
    let found = disk
        .entries
        .get(key)
        .filter(|e| e.expires_at_ms > now)
        .map(|e| e.reference.clone());
    if let Some(ref reference) = found {
        let mut cache = lock_or_recover(&REMOTE_FILE_CACHE, "remote_file_cache");
        for (k, v) in disk.entries {
            if v.expires_at_ms > now {
                cache.insert(k, v);
            }
        }
        return Some(reference.clone());
    }
    None
}

pub(crate) fn store_remote_cache(data_dir: &Path, key: String, reference: String, ttl_ms: u64) {
    let now = now_epoch_ms();
    let entry = CachedRemoteRef {
        reference,
        expires_at_ms: now.saturating_add(ttl_ms),
    };
    let snapshot = {
        let mut cache = lock_or_recover(&REMOTE_FILE_CACHE, "remote_file_cache");
        cache.retain(|_, v| v.expires_at_ms > now);
        cache.insert(key, entry);
        PersistedRemoteCache {
            version: REMOTE_CACHE_VERSION,
            entries: cache.clone(),
        }
    };
    let encoded = serde_json::to_vec(&snapshot);
    if let Err(err) = &encoded {
        tracing::warn!(%err, "remote file cache not encoded; it is rebuilt from uploads");
    }
    if let Ok(bytes) = encoded {
        let path = cache_file_path(data_dir);
        let tmp = data_dir.join(format!(
            ".tmp-remote-cache-{}.json",
            Uuid::now_v7().simple()
        ));
        if std::fs::write(&tmp, &bytes).is_ok()
            && std::fs::rename(&tmp, &path).is_err()
            && let Err(err) = std::fs::remove_file(&tmp)
        {
            tracing::debug!(error = %err, "cleanup temp remote cache failed");
        }
    }
}

/// Evicts cached remote file references for `(dialect, base, api_key)` (e.g. after an expired URI 404).
pub fn evict_remote_file_cache(
    data_dir: Option<&Path>,
    dialect: bistre_protocol::ProviderDialect,
    base: &str,
    api_key: &str,
) {
    let prefix = format!(
        "{}::{}::{}::",
        dialect.as_str(),
        base.trim_end_matches('/'),
        crate::replay_policy::blake3_short_hash(api_key)
    );
    let snapshot = {
        let mut cache = lock_or_recover(&REMOTE_FILE_CACHE, "remote_file_cache");
        cache.retain(|k, _| !k.starts_with(&prefix));
        PersistedRemoteCache {
            version: REMOTE_CACHE_VERSION,
            entries: cache.clone(),
        }
    };
    if let Some(dir) = data_dir
        && let Ok(bytes) = serde_json::to_vec(&snapshot)
    {
        let path = cache_file_path(dir);
        let tmp = dir.join(format!(
            ".tmp-remote-cache-{}.json",
            Uuid::now_v7().simple()
        ));
        if std::fs::write(&tmp, &bytes).is_ok()
            && std::fs::rename(&tmp, &path).is_err()
            && let Err(err) = std::fs::remove_file(&tmp)
        {
            tracing::debug!(error = %err, "cleanup temp remote cache failed");
        }
    }
}

/// Canonical MIME type: the caller's specific type, else the extension's, else the file's
/// leading bytes (`head`): a signature, or `text/plain` only when the bytes read as text,
/// else `application/octet-stream` (binary is never sent as text).
pub fn infer_mime_type(file_name: &str, supplied: &str, head: &[u8]) -> String {
    let clean_supplied = supplied.trim().to_ascii_lowercase();
    if !clean_supplied.is_empty() && clean_supplied != "application/octet-stream" {
        return clean_supplied;
    }
    let ext = Path::new(file_name)
        .extension()
        .and_then(|e| e.to_str())
        .map_or_default(str::to_ascii_lowercase);
    match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "gif" => "image/gif",
        "pdf" => "application/pdf",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "dotx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.template",
        "doc" => "application/msword",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "xls" => "application/vnd.ms-excel",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "ppt" => "application/vnd.ms-powerpoint",
        "odt" => "application/vnd.oasis.opendocument.text",
        "ods" => "application/vnd.oasis.opendocument.spreadsheet",
        "odp" => "application/vnd.oasis.opendocument.presentation",
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "ogg" => "audio/ogg",
        "m4a" => "audio/mp4",
        "flac" => "audio/flac",
        "aac" => "audio/aac",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "mov" => "video/quicktime",
        "csv" => "text/csv",
        "tsv" => "text/tab-separated-values",
        "md" | "markdown" => "text/markdown",
        "json" => "application/json",
        "xml" => "application/xml",
        "html" | "htm" => "text/html",
        "css" => "text/css",
        "yaml" | "yml" => "text/yaml",
        "txt" | "log" | "ini" | "toml" | "rs" | "py" | "js" | "ts" | "dart" | "sh" => "text/plain",
        "zip" => "application/zip",
        "heic" => "image/heic",
        "heif" => "image/heif",
        "avif" => "image/avif",
        _ => {
            let head = &head[..head.len().min(crate::mime_sniff::SNIFF_BYTES)];
            return crate::mime_sniff::sniff(head)
                .unwrap_or(if crate::mime_sniff::looks_like_text(head) {
                    "text/plain"
                } else {
                    "application/octet-stream"
                })
                .to_owned();
        }
    }
    .to_owned()
}

/// The note sent to the model in place of an attachment it cannot get (never a silent
/// drop). Written to the model, not the UI.
pub fn attachment_not_sent_note(att: &StoredAttachment) -> String {
    format!(
        "[Attachment {} ({}) could not be sent: the file is missing or too large]",
        att.name, att.mime_type
    )
}

/// Names of the attachments in `history` that cannot be sent (missing, or too large to send
/// inline without an uploaded reference), so the run can say so.
pub fn unsent_attachment_names(
    data_dir: &Path,
    history: &[bistre_protocol::NodeRecord],
) -> Vec<String> {
    unsent_attachment_names_with_refs(data_dir, history, &HashMap::<String, String>::new())
}

/// [`unsent_attachment_names`], counting attachments uploaded for this request as sent.
pub fn unsent_attachment_names_with_refs<S: std::hash::BuildHasher>(
    data_dir: &Path,
    history: &[bistre_protocol::NodeRecord],
    refs: &HashMap<String, String, S>,
) -> Vec<String> {
    let inline_limit = u64::try_from(MAX_INLINE_BYTES).unwrap_or(u64::MAX);
    let mut names = Vec::new();
    for node in history {
        if node.role != bistre_protocol::NodeRole::User {
            continue;
        }
        for att in parse_node_attachments(node.provider_meta_json.as_deref()) {
            if refs.contains_key(&att.blake3_hex) {
                continue;
            }
            let size = resolve_blob_path(data_dir, &att)
                .and_then(|p| std::fs::metadata(p).ok())
                .filter(std::fs::Metadata::is_file)
                .map(|m| m.len());
            let too_large = size.is_some_and(|s| s > inline_limit)
                && !is_text_like(&att.mime_type, &att.name)
                && !is_office_document(&att.mime_type, &att.name);
            if (size.is_none() || too_large) && !names.contains(&att.name) {
                names.push(att.name.clone());
            }
        }
    }
    names
}

/// Whether Gemini gets this attachment through its Files API. Office files never do (Gemini
/// rejects Office types; they go as extracted text).
pub fn gemini_needs_files_api(att: &StoredAttachment) -> bool {
    !is_office_document(&att.mime_type, &att.name)
        && (att.mime_type == "application/pdf"
            || att.mime_type.starts_with("audio/")
            || att.mime_type.starts_with("video/")
            || att.mime_type.starts_with("image/") && att.size_bytes > 4 * 1024 * 1024)
}

/// Safe ASCII extension for content-addressed blob storage.
fn safe_extension(file_name: &str) -> String {
    let ext = Path::new(file_name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("bin");
    let clean: String = ext
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(12)
        .collect();
    if clean.is_empty() {
        "bin".to_owned()
    } else {
        clean.to_ascii_lowercase()
    }
}

/// Returns `true` when the MIME type or filename represents an Office / `OpenDocument` file.
pub fn is_office_document(mime: &str, name: &str) -> bool {
    let m = mime.to_ascii_lowercase();
    if m.contains("officedocument")
        || m.contains("opendocument")
        || m == "application/msword"
        || m == "application/vnd.ms-excel"
        || m == "application/vnd.ms-powerpoint"
    {
        return true;
    }
    matches!(
        safe_extension(name).as_str(),
        "docx" | "dotx" | "doc" | "xlsx" | "xls" | "pptx" | "ppt" | "odt" | "ods" | "odp"
    )
}

/// Returns `true` when the MIME type or extension is a UTF-8 text/code/tabular format.
pub fn is_text_like(mime: &str, name: &str) -> bool {
    let m = mime.to_ascii_lowercase();
    if m.starts_with("text/")
        || m == "application/json"
        || m == "application/xml"
        || m == "application/javascript"
    {
        return true;
    }
    matches!(
        safe_extension(name).as_str(),
        "txt"
            | "md"
            | "markdown"
            | "csv"
            | "tsv"
            | "json"
            | "xml"
            | "yaml"
            | "yml"
            | "toml"
            | "html"
            | "htm"
            | "css"
            | "js"
            | "ts"
            | "tsx"
            | "jsx"
            | "py"
            | "rs"
            | "dart"
            | "go"
            | "java"
            | "kt"
            | "c"
            | "cpp"
            | "h"
            | "hpp"
            | "sh"
            | "ps1"
            | "sql"
            | "log"
            | "ini"
            | "cfg"
    )
}

/// Copies a user-selected local file into `<data_dir>/attachments/<blake3>.<ext>` atomically.
pub fn ingest_attachment(
    data_dir: &Path,
    input: &AttachmentInput,
) -> BistreResult<StoredAttachment> {
    let local = input.local_path.trim();
    if local.is_empty() || is_windows_unc_path(local) {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "attachment_path_rejected",
        ));
    }
    let src_path = Path::new(local);
    let meta = std::fs::metadata(src_path).map_err(|_| {
        BistreError::with_detail(DiagnosticKey::StorageNotFound, "attachment_missing")
    })?;
    if !meta.is_file() {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "attachment_not_file",
        ));
    }
    if meta.len() > MAX_ATTACHMENT_BYTES {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "attachment_too_large",
        ));
    }

    let bytes = std::fs::read(src_path)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "attachment_read"))?;
    let name = if input.name.trim().is_empty() {
        src_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("attachment")
            .to_owned()
    } else {
        input.name.trim().to_owned()
    };
    let mime_type = infer_mime_type(&name, &input.mime_type, &bytes);
    store_attachment_bytes(data_dir, name, mime_type, &bytes)
}

/// Writes `bytes` to `<data_dir>/attachments/<blake3>.<ext>` atomically (once per content)
/// and returns its record; the extension comes from `name`.
pub fn store_attachment_bytes(
    data_dir: &Path,
    name: String,
    mime_type: String,
    bytes: &[u8],
) -> BistreResult<StoredAttachment> {
    let blake3_hex = blake3::hash(bytes).to_hex().to_string();
    let ext = safe_extension(&name);
    let rel_path = format!("attachments/{blake3_hex}.{ext}");
    let dest_dir = data_dir.join("attachments");
    std::fs::create_dir_all(&dest_dir)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "attachment_dir"))?;
    let dest_path = dest_dir.join(format!("{blake3_hex}.{ext}"));
    if !dest_path.exists() {
        let tmp_path = dest_dir.join(format!(".tmp-{}-{blake3_hex}", Uuid::now_v7()));
        let write_res = (|| -> std::io::Result<()> {
            let mut file = std::fs::File::create(&tmp_path)?;
            std::io::Write::write_all(&mut file, bytes)?;
            file.sync_all()?;
            std::fs::rename(&tmp_path, &dest_path)?;
            Ok(())
        })();
        if write_res.is_err() {
            if let Err(err) = std::fs::remove_file(&tmp_path) {
                tracing::debug!(error = %err, "cleanup temp attachment failed");
            }
            return Err(BistreError::with_detail(
                DiagnosticKey::InternalError,
                "attachment_store",
            ));
        }
    }

    Ok(StoredAttachment {
        id: format!("att_{}", Uuid::now_v7()),
        name,
        mime_type,
        blob_rel_path: rel_path,
        size_bytes: u64::try_from(bytes.len()).unwrap_or(u64::MAX),
        blake3_hex,
    })
}

/// Resolves a stored attachment's relative blob path safely inside `<data_dir>/attachments/`.
pub fn resolve_blob_path(data_dir: &Path, att: &StoredAttachment) -> Option<PathBuf> {
    let clean = att.blob_rel_path.replace('\\', "/");
    let rest = clean.strip_prefix("attachments/")?;
    if rest.is_empty() || rest.contains('/') || rest.contains("..") || rest.contains(':') {
        return None;
    }
    Some(data_dir.join("attachments").join(rest))
}

/// Reads bounded attachment bytes from `<data_dir>/attachments/`.
pub fn read_attachment_bytes(
    data_dir: &Path,
    att: &StoredAttachment,
    max_bytes: usize,
) -> Option<Vec<u8>> {
    let path = resolve_blob_path(data_dir, att)?;
    let read = std::fs::metadata(&path).and_then(|meta| {
        if meta.len() > u64::try_from(max_bytes).unwrap_or(u64::MAX) {
            return Ok(None);
        }
        std::fs::read(&path).map(Some)
    });
    match read {
        Ok(bytes) => bytes,
        Err(err) => {
            // The message goes without this file; the log says which and why.
            tracing::warn!(
                key = DiagnosticKey::StorageIoError.as_key(),
                attachment = %att.id,
                %err,
                "attachment file unreadable"
            );
            None
        }
    }
}

/// Parses `StoredAttachment` entries persisted inside a node's `provider_meta_json`.
pub fn parse_node_attachments(provider_meta_json: Option<&str>) -> Vec<StoredAttachment> {
    let Some(raw) = provider_meta_json else {
        return Vec::new();
    };
    let Ok(val) = serde_json::from_str::<Value>(raw) else {
        return Vec::new();
    };
    val.get("attachments")
        .and_then(|v| serde_json::from_value::<Vec<StoredAttachment>>(v.clone()).ok())
        .unwrap_or_default()
}

/// Estimates prompt tokens contributed by a stored attachment for the 7-category context gauge.
pub fn estimate_attachment_tokens(data_dir: &Path, att: &StoredAttachment) -> u64 {
    if att.mime_type.starts_with("image/") {
        // Typical tile-budget estimate for a standard vision image.
        return 768;
    }
    if att.mime_type.starts_with("audio/") || att.mime_type.starts_with("video/") {
        return (att.size_bytes / 16_000).clamp(256, 8_192);
    }
    if is_text_like(&att.mime_type, &att.name)
        && let Some(bytes) = read_attachment_bytes(data_dir, att, MAX_EXTRACTED_TEXT_BYTES)
        && let Ok(text) = String::from_utf8(bytes)
    {
        return count_tokens(&text);
    }
    if is_office_document(&att.mime_type, &att.name)
        && let Some(bytes) = read_attachment_bytes(data_dir, att, MAX_INLINE_BYTES)
        && let Some(text) = extract_office_text(&bytes, &safe_extension(&att.name))
    {
        return count_tokens(&text);
    }
    // PDF or binary fallback: approximate from byte size.
    (att.size_bytes / 64).clamp(256, 16_384)
}

/// Encodes a stored attachment's bytes as standard base64 when within `MAX_INLINE_BYTES`.
pub fn read_attachment_base64(data_dir: &Path, att: &StoredAttachment) -> Option<String> {
    let bytes = read_attachment_bytes(data_dir, att, MAX_INLINE_BYTES)?;
    Some(base64::engine::general_purpose::STANDARD.encode(bytes))
}

/// Formats a plain-text or extracted Office attachment as a clean markdown text block.
pub fn read_attachment_as_text_block(data_dir: &Path, att: &StoredAttachment) -> Option<String> {
    if is_text_like(&att.mime_type, &att.name) {
        let bytes = read_attachment_bytes(data_dir, att, MAX_EXTRACTED_TEXT_BYTES)?;
        let text = String::from_utf8_lossy(&bytes);
        return Some(format!(
            "[Attached file: {} ({})]\n```\n{}\n```",
            att.name, att.mime_type, text
        ));
    }
    if is_office_document(&att.mime_type, &att.name) {
        let bytes = read_attachment_bytes(data_dir, att, MAX_INLINE_BYTES)?;
        let extracted = extract_office_text(&bytes, &safe_extension(&att.name))?;
        return Some(format!(
            "[Attached document: {} ({})]\n{}",
            att.name, att.mime_type, extracted
        ));
    }
    None
}

/// Builds `OpenAI` Responses API (`v1/responses`) input items with native `input_image` and
/// `input_file` (`.pdf`, `.docx`, `.xlsx`, `.pptx`, `.csv`, `.tsv`, `.txt`, code).
pub fn build_openai_responses_input(
    history: &[bistre_protocol::NodeRecord],
    data_dir: Option<&Path>,
) -> Vec<Value> {
    crate::wire_history::build_openai_responses_input_with_ctx(history, data_dir, None)
}

/// Builds Google Gemini Interactions API (`/v1beta/interactions`) input turns with Files API URIs
/// and inline multimodal parts.
pub fn build_gemini_interactions_input<S: std::hash::BuildHasher>(
    history: &[bistre_protocol::NodeRecord],
    data_dir: Option<&Path>,
    gemini_uris: &HashMap<String, String, S>,
) -> Vec<Value> {
    crate::wire_history::build_gemini_interactions_input_with_ctx(
        history,
        data_dir,
        gemini_uris,
        None,
        0,
    )
}

/// Builds Anthropic Messages API (`messages`) with native `image`, native PDF `document`, and
/// pure-Rust extracted Office/text blocks.
pub fn build_anthropic_messages(
    history: &[bistre_protocol::NodeRecord],
    data_dir: Option<&Path>,
) -> Vec<Value> {
    crate::wire_history::build_anthropic_messages_with_ctx(history, data_dir, None)
}

#[cfg(test)]
#[path = "attachments_tests.rs"]
mod tests;
