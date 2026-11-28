//! Provider file uploads for attachments (split out of `attachments.rs`).

use crate::attachments::{
    GEMINI_POLL_MAX_WAIT, GEMINI_URI_TTL_MS, MAX_ATTACHMENT_BYTES, MAX_INLINE_BYTES,
    REMOTE_FILE_TTL_MS, gemini_needs_files_api, lookup_remote_cache, parse_node_attachments,
    read_attachment_bytes, remote_file_cache_key, store_remote_cache,
};
use crate::credentials::apply_auth_header;
use bistre_protocol::StoredAttachment;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::Path;
use std::time::{Duration, Instant};
use uuid::Uuid;

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

    let bytes = crate::off_worker::in_place(|| {
        read_attachment_bytes(
            data_dir,
            att,
            usize::try_from(MAX_ATTACHMENT_BYTES).unwrap_or(usize::MAX),
        )
    })?;
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
            .map_err(|err| tracing::warn!(%err, "gemini upload header invalid; falling back"))
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
        .map_err(|err| tracing::warn!(%err, "gemini files api upload not sent; falling back"))
        .ok()?;
    if !resp.status().is_success() {
        tracing::warn!(
            status = resp.status().as_u16(),
            name = %att.name,
            "gemini files api upload failed; falling back to inline/text"
        );
        return None;
    }
    let parsed: Value = resp
        .json()
        .await
        .map_err(|err| tracing::warn!(%err, "gemini files api reply unreadable; falling back"))
        .ok()?;
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

pub(crate) async fn poll_gemini_file_active(
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

    let bytes = crate::off_worker::in_place(|| {
        read_attachment_bytes(
            data_dir,
            att,
            usize::try_from(MAX_ATTACHMENT_BYTES).unwrap_or(usize::MAX),
        )
    })?;
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
    .map_err(|err| tracing::warn!(%err, "files api upload header invalid; falling back"))
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
        .map_err(|err| tracing::warn!(%err, "provider files api upload not sent"))
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
    let parsed: Value = resp
        .json()
        .await
        .map_err(|err| tracing::warn!(%err, "provider files api reply unreadable"))
        .ok()?;
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
