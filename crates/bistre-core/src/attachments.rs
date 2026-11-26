//! Native multimodal, PDF, Office (`.docx`/`.xlsx`/`.pptx`/`.odt`/`.ods`/`.odp`), audio, video,
//! and plain-text attachment ingestion, pure-Rust Office XML extraction, and Gemini Files API upload.
//!
//! All reads are size-bounded, UNC paths are rejected fail-closed, and blobs are stored
//! content-addressed under `<data_dir>/attachments/<blake3_hex>.<ext>` using atomic temp → sync →
//! rename.

use std::collections::HashMap;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use base64::Engine as _;
use bistre_protocol::{
    AttachmentInput, BistreError, BistreResult, DiagnosticKey, StoredAttachment, lock_or_recover,
};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::credentials::apply_auth_header;
use crate::import_policy::is_windows_unc_path;
use crate::tokenizer::count_tokens;

/// Hard upload limit per attachment (`50 MiB`).
pub const MAX_ATTACHMENT_BYTES: u64 = 50 * 1024 * 1024;
/// Maximum file size sent inline as base64 (`16 MiB`); larger files use Files API where available.
pub const MAX_INLINE_BYTES: usize = 16 * 1024 * 1024;
/// Maximum extracted text size for text/code or Office XML fallback (`512 KiB`).
const MAX_EXTRACTED_TEXT_BYTES: usize = 512 * 1024;
/// Maximum decompressed bytes read from any single Office ZIP archive (zip-bomb guard).
const MAX_OFFICE_ZIP_BYTES: usize = 4 * 1024 * 1024;
/// Maximum number of ZIP entries inspected per Office archive.
const MAX_OFFICE_ZIP_ENTRIES: usize = 256;
/// Gemini Files API retains uploads for 48 hours; reuse cached URIs for 40 hours.
const GEMINI_URI_TTL_MS: u64 = 40 * 3_600 * 1_000;
/// `OpenAI` & Anthropic Files API cache reuse window (24 hours when `store: true`).
const REMOTE_FILE_TTL_MS: u64 = 24 * 3_600 * 1_000;
/// Max time spent polling Gemini `PROCESSING -> ACTIVE` per file.
const GEMINI_POLL_MAX_WAIT: Duration = Duration::from_secs(60);
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

fn lookup_remote_cache(data_dir: &Path, key: &str) -> Option<String> {
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

fn store_remote_cache(data_dir: &Path, key: String, reference: String, ttl_ms: u64) {
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
    if let Ok(bytes) = serde_json::to_vec(&snapshot) {
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
/// leading bytes (`head`, R23): a signature, or `text/plain` only when the bytes read as text,
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

/// The note sent to the model in place of an attachment it cannot get (R24: never a silent
/// drop). Written to the model, not the UI.
pub fn attachment_not_sent_note(att: &StoredAttachment) -> String {
    format!(
        "[Attachment {} ({}) could not be sent: the file is missing or too large]",
        att.name, att.mime_type
    )
}

/// Names of the attachments in `history` that cannot be sent (missing, or too large to send
/// inline without an uploaded reference), so the run can say so (R24).
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
/// rejects Office types; they go as extracted text, R25).
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
    let blake3_hex = blake3::hash(&bytes).to_hex().to_string();
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
            std::io::Write::write_all(&mut file, &bytes)?;
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
    let meta = std::fs::metadata(&path).ok()?;
    if meta.len() > u64::try_from(max_bytes).unwrap_or(u64::MAX) {
        return None;
    }
    std::fs::read(&path).ok()
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

/// Pure-Rust ZIP+XML text extraction for Office & `OpenDocument` formats (`.docx`, `.dotx`,
/// `.xlsx`, `.pptx`, `.odt`, `.ods`, `.odp`). Zip-bomb bounded (`<= 4 MiB`, `<= 256` entries).
pub fn extract_office_text(bytes: &[u8], ext: &str) -> Option<String> {
    let cursor = std::io::Cursor::new(bytes);
    let mut archive = zip::ZipArchive::new(cursor).ok()?;
    let entry_count = archive.len().min(MAX_OFFICE_ZIP_ENTRIES);
    let mut total_read = 0_usize;

    let mut read_xml =
        |archive: &mut zip::ZipArchive<std::io::Cursor<&[u8]>>, name: &str| -> Option<String> {
            let mut file = archive.by_name(name).ok()?;
            let remaining = MAX_OFFICE_ZIP_BYTES.saturating_sub(total_read);
            if remaining == 0 {
                return None;
            }
            let mut buf = Vec::new();
            let mut limited = (&mut file).take(u64::try_from(remaining).unwrap_or(0));
            limited.read_to_end(&mut buf).ok()?;
            total_read = total_read.saturating_add(buf.len());
            String::from_utf8(buf).ok()
        };

    let mut out = String::new();
    match ext {
        "docx" | "dotx" => {
            if let Some(xml) = read_xml(&mut archive, "word/document.xml") {
                out.push_str(&strip_xml_text(&xml, &["</w:p>", "<w:br", "</w:tr>"]));
            }
        }
        "xlsx" => {
            let shared_strings = read_xml(&mut archive, "xl/sharedStrings.xml")
                .map_or_default(|xml| parse_xlsx_shared_strings(&xml));
            let mut sheet_names: Vec<String> = Vec::new();
            for i in 0..entry_count {
                if let Ok(entry) = archive.by_index(i)
                    && let Ok(n) = entry.name()
                    && n.starts_with("xl/worksheets/sheet")
                    && n.ends_with(".xml")
                {
                    sheet_names.push(n.into_owned());
                }
            }
            sheet_names.sort();
            for (idx, sheet) in sheet_names.iter().enumerate() {
                if let Some(xml) = read_xml(&mut archive, sheet) {
                    if idx > 0 {
                        out.push_str("\n\n");
                    }
                    out.push_str("--- Sheet ");
                    out.push_str(&(idx + 1).to_string());
                    out.push_str(" ---\n");
                    out.push_str(&parse_xlsx_sheet(&xml, &shared_strings));
                }
            }
        }
        "pptx" => {
            let mut slides: Vec<String> = Vec::new();
            for i in 0..entry_count {
                if let Ok(entry) = archive.by_index(i)
                    && let Ok(n) = entry.name()
                    && n.starts_with("ppt/slides/slide")
                    && n.ends_with(".xml")
                {
                    slides.push(n.into_owned());
                }
            }
            slides.sort_by_key(|name| {
                name.trim_start_matches("ppt/slides/slide")
                    .trim_end_matches(".xml")
                    .parse::<u32>()
                    .unwrap_or(u32::MAX)
            });
            for (idx, slide) in slides.iter().enumerate() {
                if let Some(xml) = read_xml(&mut archive, slide) {
                    if idx > 0 {
                        out.push_str("\n\n");
                    }
                    out.push_str("--- Slide ");
                    out.push_str(&(idx + 1).to_string());
                    out.push_str(" ---\n");
                    out.push_str(&strip_xml_text(&xml, &["</a:p>", "</p:txBody>"]));
                }
            }
        }
        "odt" | "ods" | "odp" => {
            if let Some(xml) = read_xml(&mut archive, "content.xml") {
                out.push_str(&strip_xml_text(
                    &xml,
                    &["</text:p>", "</table:table-row>", "<text:line-break"],
                ));
            }
        }
        _ => return None,
    }

    let trimmed = out.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.len() > MAX_EXTRACTED_TEXT_BYTES {
        let mut end = MAX_EXTRACTED_TEXT_BYTES;
        while end > 0 && !trimmed.is_char_boundary(end) {
            end -= 1;
        }
        Some(format!("{}\n[...truncated...]", &trimmed[..end]))
    } else {
        Some(trimmed.to_owned())
    }
}

fn decode_xml_entities(input: &str) -> String {
    input
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
}

fn strip_xml_text(xml: &str, break_tags: &[&str]) -> String {
    let mut out = String::with_capacity(xml.len() / 4);
    let mut rest = xml;
    while let Some(lt) = rest.find('<') {
        let text = &rest[..lt];
        if !text.is_empty() {
            out.push_str(&decode_xml_entities(text));
        }
        let after_lt = &rest[lt..];
        let Some(gt) = after_lt.find('>') else {
            break;
        };
        let tag = &after_lt[..=gt];
        if break_tags.iter().any(|b| tag.starts_with(b)) && !out.ends_with('\n') {
            out.push('\n');
        } else if tag.starts_with("<w:tab") || tag.starts_with("</w:tc>") {
            out.push('\t');
        }
        rest = &after_lt[gt + 1..];
    }
    out
}

fn parse_xlsx_shared_strings(xml: &str) -> Vec<String> {
    let mut strings = Vec::new();
    let mut rest = xml;
    while let Some(start) = rest.find("<si") {
        let after = &rest[start..];
        let Some(end) = after.find("</si>") else {
            break;
        };
        let chunk = &after[..end];
        strings.push(strip_xml_text(chunk, &[]).trim().to_owned());
        rest = &after[end + 5..];
    }
    strings
}

fn parse_xlsx_sheet(xml: &str, shared: &[String]) -> String {
    let mut out = String::new();
    let mut rest = xml;
    while let Some(row_start) = rest.find("<row") {
        let after_row = &rest[row_start..];
        let Some(row_end) = after_row.find("</row>") else {
            break;
        };
        let row_chunk = &after_row[..row_end];
        let mut cells = Vec::new();
        let mut cell_rest = row_chunk;
        while let Some(c_start) = find_xml_open_tag(cell_rest, "c") {
            let after_c = &cell_rest[c_start..];
            let Some(c_end) = after_c.find("</c>") else {
                break;
            };
            let cell_xml = &after_c[..c_end];
            let is_shared = cell_xml.contains("t=\"s\"");
            let val = if let Some(v_start) = cell_xml.find("<v>")
                && let Some(v_end) = cell_xml[v_start + 3..].find("</v>")
            {
                let raw = cell_xml[v_start + 3..v_start + 3 + v_end].trim();
                if is_shared {
                    raw.parse::<usize>()
                        .ok()
                        .and_then(|idx| shared.get(idx))
                        .cloned()
                        .unwrap_or_default()
                } else {
                    decode_xml_entities(raw)
                }
            } else {
                strip_xml_text(cell_xml, &[]).trim().to_owned()
            };
            cells.push(val);
            cell_rest = &after_c[c_end + 4..];
        }
        if !cells.is_empty() {
            out.push_str(&cells.join(", "));
            out.push('\n');
        }
        rest = &after_row[row_end + 6..];
    }
    out
}

fn find_xml_open_tag(haystack: &str, tag: &str) -> Option<usize> {
    let needle = format!("<{tag}");
    let mut offset = 0;
    while let Some(pos) = haystack[offset..].find(&needle) {
        let abs = offset + pos;
        let next_idx = abs + needle.len();
        if let Some(next_ch) = haystack[next_idx..].chars().next()
            && matches!(next_ch, ' ' | '>' | '/' | '\t' | '\n' | '\r')
        {
            return Some(abs);
        }
        offset = next_idx;
    }
    None
}

/// Pre-uploaded remote file references (`blake3_hex -> uri_or_file_id`) plus ephemeral file IDs
/// uploaded solely because an attachment exceeded `MAX_INLINE_BYTES` (`16 MiB`) under `store: false`.
#[derive(Debug, Default, Clone)]
pub struct UploadedAttachmentRefs {
    pub refs: HashMap<String, String>,
    pub ephemeral_ids: Vec<(bistre_protocol::ProviderDialect, String)>,
}

/// Uploads a file via the Google Gemini Files API (`POST {base}/upload/v1beta/files`), polls
/// `GET {base}/v1beta/{file.name}` while `state == "PROCESSING"` until `ACTIVE`, and caches
/// the returned `file.uri` isolated by `(dialect, base, key_hash, blake3_hex)` for 40 hours.
pub async fn gemini_upload_file(
    client: &reqwest::Client,
    base: &str,
    api_key: &str,
    data_dir: &Path,
    att: &StoredAttachment,
) -> Option<String> {
    let cache_key = remote_file_cache_key(
        bistre_protocol::ProviderDialect::GoogleGemini,
        base,
        api_key,
        &att.blake3_hex,
    );
    if let Some(uri) = lookup_remote_cache(data_dir, &cache_key) {
        return Some(uri);
    }

    let bytes = read_attachment_bytes(
        data_dir,
        att,
        usize::try_from(MAX_ATTACHMENT_BYTES).unwrap_or(usize::MAX),
    )?;
    let boundary = format!("bistre_boundary_{}", Uuid::now_v7().simple());
    let metadata_json = json!({
        "file": {
            "display_name": att.name,
            "mime_type": att.mime_type,
        }
    })
    .to_string();

    let mut body = Vec::with_capacity(bytes.len() + metadata_json.len() + 256);
    body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
    body.extend_from_slice(b"Content-Type: application/json; charset=UTF-8\r\n\r\n");
    body.extend_from_slice(metadata_json.as_bytes());
    body.extend_from_slice(format!("\r\n--{boundary}\r\n").as_bytes());
    body.extend_from_slice(format!("Content-Type: {}\r\n\r\n", att.mime_type).as_bytes());
    body.extend_from_slice(&bytes);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());

    let clean_base = bistre_protocol::ProviderDialect::GoogleGemini.api_root(base);
    let upload_url = format!("{clean_base}/upload/v1beta/files?uploadType=multipart");
    let mut headers = reqwest::header::HeaderMap::new();
    let content_type =
        reqwest::header::HeaderValue::from_str(&format!("multipart/related; boundary={boundary}"))
            .ok()?;
    headers.insert(reqwest::header::CONTENT_TYPE, content_type);
    apply_auth_header(
        bistre_protocol::ProviderDialect::GoogleGemini,
        api_key,
        &mut headers,
    );

    let resp = client
        .post(&upload_url)
        .headers(headers)
        .body(body)
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        tracing::warn!(
            status = resp.status().as_u16(),
            name = %att.name,
            "gemini files api upload failed; falling back to inline/text"
        );
        return None;
    }
    let parsed: Value = resp.json().await.ok()?;
    let uri = parsed
        .pointer("/file/uri")
        .or_else(|| parsed.get("uri"))
        .and_then(Value::as_str)
        .map(str::to_owned)?;
    let state = parsed
        .pointer("/file/state")
        .or_else(|| parsed.get("state"))
        .and_then(Value::as_str)
        .unwrap_or("ACTIVE");
    if state.eq_ignore_ascii_case("FAILED") {
        return None;
    }
    if state.eq_ignore_ascii_case("PROCESSING")
        && let Some(file_name) = parsed
            .pointer("/file/name")
            .or_else(|| parsed.get("name"))
            .and_then(Value::as_str)
        && !poll_gemini_file_active(client, clean_base, api_key, file_name).await
    {
        return None;
    }

    store_remote_cache(data_dir, cache_key, uri.clone(), GEMINI_URI_TTL_MS);
    Some(uri)
}

async fn poll_gemini_file_active(
    client: &reqwest::Client,
    clean_base: &str,
    api_key: &str,
    file_name: &str,
) -> bool {
    let clean_name = file_name.trim_start_matches('/');
    let poll_url = format!("{clean_base}/v1beta/{clean_name}");
    let deadline = Instant::now() + GEMINI_POLL_MAX_WAIT;
    let mut delay = Duration::from_millis(250);
    while Instant::now() < deadline {
        tokio::time::sleep(delay).await;
        let mut headers = reqwest::header::HeaderMap::new();
        apply_auth_header(
            bistre_protocol::ProviderDialect::GoogleGemini,
            api_key,
            &mut headers,
        );
        let Ok(resp) = client.get(&poll_url).headers(headers).send().await else {
            return false;
        };
        if !resp.status().is_success() {
            return false;
        }
        let Ok(val) = resp.json::<Value>().await else {
            return false;
        };
        let state = val
            .pointer("/file/state")
            .or_else(|| val.get("state"))
            .and_then(Value::as_str)
            .unwrap_or("ACTIVE");
        if state.eq_ignore_ascii_case("ACTIVE") {
            return true;
        }
        if state.eq_ignore_ascii_case("FAILED") {
            return false;
        }
        delay = (delay * 2).min(Duration::from_secs(2));
    }
    false
}

/// Uploads an oversized (`> 16 MiB`) attachment to `OpenAI` (`/v1/files`, `purpose="user_data"`)
/// or Anthropic (`/v1/files`, `anthropic-beta: files-api-2025-04-14`) returning its `file_id`.
pub async fn upload_provider_file_api(
    client: &reqwest::Client,
    dialect: bistre_protocol::ProviderDialect,
    base: &str,
    api_key: &str,
    data_dir: &Path,
    att: &StoredAttachment,
    use_cache: bool,
) -> Option<String> {
    if !matches!(
        dialect,
        bistre_protocol::ProviderDialect::OpenAi | bistre_protocol::ProviderDialect::Anthropic
    ) {
        return None;
    }
    let cache_key = remote_file_cache_key(dialect, base, api_key, &att.blake3_hex);
    if use_cache && let Some(id) = lookup_remote_cache(data_dir, &cache_key) {
        return Some(id);
    }

    let bytes = read_attachment_bytes(
        data_dir,
        att,
        usize::try_from(MAX_ATTACHMENT_BYTES).unwrap_or(usize::MAX),
    )?;
    let boundary = format!("bistre_form_{}", Uuid::now_v7().simple());
    let safe_name = att.name.replace(['"', '\r', '\n'], "_");
    let mut body = Vec::with_capacity(bytes.len() + 512);
    if dialect == bistre_protocol::ProviderDialect::OpenAi {
        body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
        body.extend_from_slice(
            b"Content-Disposition: form-data; name=\"purpose\"\r\n\r\nuser_data\r\n",
        );
    }
    body.extend_from_slice(format!("--{boundary}\r\n").as_bytes());
    body.extend_from_slice(
        format!(
            "Content-Disposition: form-data; name=\"file\"; filename=\"{safe_name}\"\r\nContent-Type: {}\r\n\r\n",
            att.mime_type
        )
        .as_bytes(),
    );
    body.extend_from_slice(&bytes);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());

    let url = format!("{}/files", base.trim_end_matches('/'));
    let mut headers = reqwest::header::HeaderMap::new();
    let ct = reqwest::header::HeaderValue::from_str(&format!(
        "multipart/form-data; boundary={boundary}"
    ))
    .ok()?;
    headers.insert(reqwest::header::CONTENT_TYPE, ct);
    if dialect == bistre_protocol::ProviderDialect::Anthropic {
        headers.insert(
            "anthropic-version",
            reqwest::header::HeaderValue::from_static(
                bistre_protocol::dialect::ANTHROPIC_API_VERSION,
            ),
        );
        headers.insert(
            "anthropic-beta",
            reqwest::header::HeaderValue::from_static(
                bistre_protocol::dialect::ANTHROPIC_BETA_FILES,
            ),
        );
    }
    apply_auth_header(dialect, api_key, &mut headers);

    let resp = client
        .post(&url)
        .headers(headers)
        .body(body)
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        tracing::warn!(
            status = resp.status().as_u16(),
            dialect = dialect.as_str(),
            name = %att.name,
            "provider files api upload failed"
        );
        return None;
    }
    let parsed: Value = resp.json().await.ok()?;
    let id = parsed
        .get("id")
        .and_then(Value::as_str)
        .map(str::to_owned)?;
    if use_cache {
        store_remote_cache(data_dir, cache_key, id.clone(), REMOTE_FILE_TTL_MS);
    }
    Some(id)
}

/// Best-effort deletion of an ephemeral `OpenAI` / Anthropic `file_id` uploaded under `store: false`.
pub async fn delete_remote_file(
    client: &reqwest::Client,
    dialect: bistre_protocol::ProviderDialect,
    base: &str,
    api_key: &str,
    file_id: &str,
) {
    let url = format!("{}/files/{file_id}", base.trim_end_matches('/'));
    let mut headers = reqwest::header::HeaderMap::new();
    if dialect == bistre_protocol::ProviderDialect::Anthropic {
        headers.insert(
            "anthropic-version",
            reqwest::header::HeaderValue::from_static(
                bistre_protocol::dialect::ANTHROPIC_API_VERSION,
            ),
        );
        headers.insert(
            "anthropic-beta",
            reqwest::header::HeaderValue::from_static(
                bistre_protocol::dialect::ANTHROPIC_BETA_FILES,
            ),
        );
    }
    apply_auth_header(dialect, api_key, &mut headers);
    if let Err(err) = client.delete(&url).headers(headers).send().await {
        tracing::debug!(error = %err, file_id, "ephemeral remote file delete failed");
    }
}

/// Pre-uploads attachments for the active dialect:
/// - Gemini: Office, PDF, audio, video, and `> 4 MiB` via Gemini Files API (with `PROCESSING -> ACTIVE` poll).
/// - `OpenAI` & Anthropic: attachments exceeding `MAX_INLINE_BYTES` (`16 MiB`) via provider Files API.
pub async fn preupload_attachments_for_dialect(
    client: &reqwest::Client,
    dialect: bistre_protocol::ProviderDialect,
    base: &str,
    api_key: &str,
    data_dir: Option<&Path>,
    history: &[bistre_protocol::NodeRecord],
    store_server_state: bool,
) -> UploadedAttachmentRefs {
    let mut out = UploadedAttachmentRefs::default();
    let Some(dir) = data_dir else {
        return out;
    };
    if api_key.trim().is_empty() {
        return out;
    }
    let inline_limit = u64::try_from(MAX_INLINE_BYTES).unwrap_or(u64::MAX);
    for node in history {
        if node.role != bistre_protocol::NodeRole::User {
            continue;
        }
        for att in parse_node_attachments(node.provider_meta_json.as_deref()) {
            if out.refs.contains_key(&att.blake3_hex) {
                continue;
            }
            match dialect {
                bistre_protocol::ProviderDialect::GoogleGemini => {
                    if gemini_needs_files_api(&att)
                        && let Some(uri) =
                            gemini_upload_file(client, base, api_key, dir, &att).await
                    {
                        out.refs.insert(att.blake3_hex.clone(), uri);
                    }
                }
                bistre_protocol::ProviderDialect::OpenAi
                | bistre_protocol::ProviderDialect::Anthropic => {
                    if att.size_bytes > inline_limit
                        && let Some(file_id) = upload_provider_file_api(
                            client,
                            dialect,
                            base,
                            api_key,
                            dir,
                            &att,
                            store_server_state,
                        )
                        .await
                    {
                        out.refs.insert(att.blake3_hex.clone(), file_id.clone());
                        if !store_server_state {
                            out.ephemeral_ids.push((dialect, file_id));
                        }
                    }
                }
                bistre_protocol::ProviderDialect::CustomOpenAi => {}
            }
        }
    }
    out
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

/// Pre-uploads Gemini Office/media/PDF/large attachments via the Gemini Files API, returning a
/// map from `blake3_hex` → uploaded `file.uri`.
pub async fn preupload_gemini_attachments(
    client: &reqwest::Client,
    base: &str,
    api_key: &str,
    data_dir: Option<&Path>,
    history: &[bistre_protocol::NodeRecord],
) -> HashMap<String, String> {
    preupload_attachments_for_dialect(
        client,
        bistre_protocol::ProviderDialect::GoogleGemini,
        base,
        api_key,
        data_dir,
        history,
        true,
    )
    .await
    .refs
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

/// Builds Google Gemini `generateContent` (`contents`) turns with `file_data` / `inline_data`.
pub fn build_gemini_generate_contents<S: std::hash::BuildHasher>(
    history: &[bistre_protocol::NodeRecord],
    data_dir: Option<&Path>,
    gemini_uris: &HashMap<String, String, S>,
) -> Vec<Value> {
    crate::wire_history::build_gemini_generate_contents_with_ctx(
        history,
        data_dir,
        gemini_uris,
        None,
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

/// Builds Custom `OpenAI`-Compatible `/chat/completions` messages with `image_url` and extracted
/// text/Office document blocks.
pub fn build_openai_compat_messages(
    history: &[bistre_protocol::NodeRecord],
    data_dir: Option<&Path>,
) -> Vec<Value> {
    crate::wire_history::build_openai_compat_messages_with_ctx(history, data_dir, None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;

    #[test]
    fn extracts_docx_and_xlsx_text_without_mcp() -> Result<(), Box<dyn std::error::Error>> {
        let mut docx_buf = Vec::new();
        {
            let mut zw = zip::ZipWriter::new(std::io::Cursor::new(&mut docx_buf));
            let opts = zip::write::SimpleFileOptions::default();
            zw.start_file("word/document.xml", opts)?;
            zw.write_all(
                br"<w:document><w:body><w:p><w:r><w:t>Hello &amp; welcome</w:t></w:r></w:p><w:p><w:r><w:t>Second line</w:t></w:r></w:p></w:body></w:document>",
            )?;
            zw.finish()?;
        }
        let docx_text = extract_office_text(&docx_buf, "docx").ok_or("docx extract failed")?;
        assert!(docx_text.contains("Hello & welcome"));
        assert!(docx_text.contains("Second line"));

        let mut xlsx_buf = Vec::new();
        {
            let mut zw = zip::ZipWriter::new(std::io::Cursor::new(&mut xlsx_buf));
            let opts = zip::write::SimpleFileOptions::default();
            zw.start_file("xl/sharedStrings.xml", opts)?;
            zw.write_all(br"<sst><si><t>Quarter</t></si><si><t>Revenue</t></si></sst>")?;
            zw.start_file("xl/worksheets/sheet1.xml", opts)?;
            zw.write_all(
                br#"<worksheet><sheetData><row><c t="s"><v>0</v></c><c t="s"><v>1</v></c></row><row><c><v>1</v></c><c><v>4200</v></c></row></sheetData></worksheet>"#,
            )?;
            zw.finish()?;
        }
        let xlsx_text = extract_office_text(&xlsx_buf, "xlsx").ok_or("xlsx extract failed")?;
        assert!(xlsx_text.contains("Quarter, Revenue"));
        assert!(xlsx_text.contains("1, 4200"));
        Ok(())
    }

    #[test]
    fn encodes_multimodal_attachments_across_big_3() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let png_path = dir.path().join("sample.png");
        std::fs::write(&png_path, [137_u8, 80, 78, 71, 13, 10, 26, 10])?;
        let stored = ingest_attachment(
            dir.path(),
            &AttachmentInput {
                name: "sample.png".to_owned(),
                mime_type: String::new(),
                local_path: png_path.to_string_lossy().into_owned(),
            },
        )?;
        assert_eq!(stored.mime_type, "image/png");

        let node = bistre_protocol::NodeRecord {
            id: "n1".to_owned(),
            thread_id: "t1".to_owned(),
            parent_id: None,
            role: bistre_protocol::NodeRole::User,
            content: "Describe this".to_owned(),
            provider_meta_json: Some(json!({ "attachments": [stored] }).to_string()),
            created_at_ms: 0,
        };

        let oai = build_openai_responses_input(std::slice::from_ref(&node), Some(dir.path()));
        assert_eq!(oai[0]["content"][0]["type"], "input_image");

        let anth = build_anthropic_messages(std::slice::from_ref(&node), Some(dir.path()));
        assert_eq!(anth[0]["content"][0]["type"], "image");

        let gem = build_gemini_interactions_input(
            std::slice::from_ref(&node),
            Some(dir.path()),
            &HashMap::new(),
        );
        assert_eq!(gem[0]["content"][0]["type"], "image");
        Ok(())
    }

    #[test]
    fn multi_key_remote_cache_is_isolated_and_evictable() -> Result<(), Box<dyn std::error::Error>>
    {
        let dir = tempfile::tempdir()?;
        let k_a = remote_file_cache_key(
            bistre_protocol::ProviderDialect::GoogleGemini,
            "https://example.test",
            "key-alpha",
            "hash123",
        );
        let k_b = remote_file_cache_key(
            bistre_protocol::ProviderDialect::GoogleGemini,
            "https://example.test",
            "key-beta",
            "hash123",
        );
        assert_ne!(
            k_a, k_b,
            "different API keys must never share cached remote URIs"
        );

        store_remote_cache(
            dir.path(),
            k_a.clone(),
            "https://files/a".to_owned(),
            60_000,
        );
        assert_eq!(
            lookup_remote_cache(dir.path(), &k_a).as_deref(),
            Some("https://files/a")
        );
        assert_eq!(lookup_remote_cache(dir.path(), &k_b), None);

        evict_remote_file_cache(
            Some(dir.path()),
            bistre_protocol::ProviderDialect::GoogleGemini,
            "https://example.test",
            "key-alpha",
        );
        assert_eq!(lookup_remote_cache(dir.path(), &k_a), None);
        Ok(())
    }

    #[tokio::test]
    async fn gemini_upload_polls_processing_until_active_and_openai_uploads_file_id()
    -> Result<(), Box<dyn std::error::Error>> {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicUsize, Ordering};
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;

        let dir = tempfile::tempdir()?;
        let pdf_path = dir.path().join("doc.pdf");
        std::fs::write(&pdf_path, b"%PDF-1.7 test content")?;
        let stored = ingest_attachment(
            dir.path(),
            &AttachmentInput {
                name: "doc.pdf".to_owned(),
                mime_type: "application/pdf".to_owned(),
                local_path: pdf_path.to_string_lossy().into_owned(),
            },
        )?;

        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let addr = listener.local_addr()?;
        let polls = Arc::new(AtomicUsize::new(0));
        let polls_clone = Arc::clone(&polls);

        let srv = tokio::spawn(async move {
            for _ in 0..4 {
                let Ok((mut sock, _)) = listener.accept().await else {
                    break;
                };
                let mut buf = vec![0_u8; 8192];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]);
                let body = if req.starts_with("POST /upload/v1beta/files") {
                    r#"{"file":{"name":"files/abc123","uri":"https://example.test/files/abc123","state":"PROCESSING"}}"#
                        .to_owned()
                } else if req.starts_with("GET /v1beta/files/abc123") {
                    let count = polls_clone.fetch_add(1, Ordering::SeqCst);
                    if count == 0 {
                        r#"{"name":"files/abc123","state":"PROCESSING"}"#.to_owned()
                    } else {
                        r#"{"name":"files/abc123","state":"ACTIVE"}"#.to_owned()
                    }
                } else if req.starts_with("POST /files") {
                    r#"{"id":"file-openai-999"}"#.to_owned()
                } else {
                    "{}".to_owned()
                };
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                if sock.write_all(resp.as_bytes()).await.is_err() {
                    break;
                }
            }
        });

        let client = crate::providers::build_http_client()?;
        let base = format!("http://{addr}");
        let uri = gemini_upload_file(&client, &base, "gem-key", dir.path(), &stored).await;
        assert_eq!(uri.as_deref(), Some("https://example.test/files/abc123"));
        assert!(polls.load(Ordering::SeqCst) >= 2, "must poll until ACTIVE");

        let oai_id = upload_provider_file_api(
            &client,
            bistre_protocol::ProviderDialect::OpenAi,
            &base,
            "oai-key",
            dir.path(),
            &stored,
            false,
        )
        .await;
        assert_eq!(oai_id.as_deref(), Some("file-openai-999"));
        srv.abort();
        Ok(())
    }
}
