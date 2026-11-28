//! MCP protocol era handling shared by the stdio and Streamable HTTP clients (MCP
//! `2026-07-28` versioning): per-request `_meta`, the `server/discover` probe verdict,
//! `resultType`, and the per-server HTTP era cache.
//!
//! A modern server (`2026-07-28`) has no handshake: every request carries its version and
//! capabilities in `_meta`. A legacy server (`2025-11-25`) needs `initialize` first. The probe
//! tells them apart; a recognized modern error never falls back to `initialize`.

use std::collections::HashMap;
use std::ops::RangeInclusive;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, lock_or_recover};
use serde_json::{Value, json};

use crate::mcp::{MCP_PROTOCOL_2026, McpServerConfig};

/// How long the stdio probe waits for `server/discover`; silence means a legacy server.
pub const MCP_DISCOVER_PROBE_TIMEOUT: Duration = Duration::from_secs(10);

/// JSON-RPC error codes the MCP spec reserves for itself. One in a probe answer
/// (`UnsupportedProtocolVersion` is `-32022`) identifies a modern server.
const MCP_SPEC_ERROR_CODES: RangeInclusive<i64> = -32099..=-32020;

/// Most HTTP servers whose era (and legacy session) is remembered at once.
const MAX_HTTP_ERAS: usize = 64;

/// The `_meta` every modern request carries.
#[must_use]
pub fn modern_meta() -> Value {
    let tasks = crate::mcp_tasks::TASKS_EXTENSION;
    json!({
        "io.modelcontextprotocol/protocolVersion": MCP_PROTOCOL_2026,
        "io.modelcontextprotocol/clientInfo": { "name": "Bistre", "version": crate::CORE_VERSION },
        "io.modelcontextprotocol/clientCapabilities": { "extensions": { tasks: {} } },
    })
}

/// `params` with the modern `_meta` added; a non-object `params` becomes `{ "_meta": .. }`.
#[must_use]
pub fn with_modern_meta(params: Value) -> Value {
    let mut map = match params {
        Value::Object(map) => map,
        _ => serde_json::Map::new(),
    };
    map.insert("_meta".to_owned(), modern_meta());
    Value::Object(map)
}

/// Which handshake a server needs, decided once per server process (stdio) or origin (HTTP).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeVerdict {
    /// `2026-07-28`: no handshake, `_meta` on every request.
    Modern,
    /// `2025-11-25`: `initialize` first.
    Legacy,
}

/// The JSON-RPC error code inside a `mcp_rpc_error_<code>` detail.
fn rpc_error_code(err: &BistreError) -> Option<i64> {
    let detail = err.detail_code.as_deref()?.strip_prefix("mcp_rpc_error_")?;
    detail.split(';').next()?.parse().ok()
}

/// Classifies the answer to a `server/discover` probe (MCP `2026-07-28` versioning).
/// - A result naming `2026-07-28` in `supportedVersions`: modern.
/// - A result without it, or an MCP-reserved error code: a modern server that does not
///   speak our version; the error is surfaced, never answered with `initialize`.
/// - Any other JSON-RPC error, a probe timeout, or an HTTP `4xx`: legacy.
/// - Anything else (a crash, a `5xx`, a blocked destination) is the error it is.
pub fn probe_verdict(answer: BistreResult<Value>) -> BistreResult<ProbeVerdict> {
    let err = match answer {
        Ok(resp) => {
            let supported = resp
                .pointer("/result/supportedVersions")
                .and_then(Value::as_array)
                .ok_or_else(|| {
                    BistreError::with_detail(
                        DiagnosticKey::ProviderRequestFailed,
                        "mcp_discover_no_versions",
                    )
                })?;
            if supported
                .iter()
                .any(|v| v.as_str() == Some(MCP_PROTOCOL_2026))
            {
                return Ok(ProbeVerdict::Modern);
            }
            let list: Vec<&str> = supported.iter().filter_map(Value::as_str).collect();
            return Err(BistreError::with_detail(
                DiagnosticKey::ProviderRequestFailed,
                format!(
                    "mcp_protocol_unsupported;reason={}",
                    crate::finish::sanitize_reason(&list.join(","))
                ),
            ));
        }
        Err(err) => err,
    };
    if err.key != DiagnosticKey::ProviderRequestFailed {
        return Err(err);
    }
    if let Some(code) = rpc_error_code(&err) {
        return if MCP_SPEC_ERROR_CODES.contains(&code) {
            Err(err)
        } else {
            Ok(ProbeVerdict::Legacy)
        };
    }
    let detail = err.detail_code.as_deref().unwrap_or("");
    if detail == "mcp_stdio_timeout" || detail.starts_with("mcp_http_4") {
        return Ok(ProbeVerdict::Legacy);
    }
    Err(err)
}

/// Most `tools/list` pages read from one server; a server that still offers a `nextCursor`
/// after this many keeps its remaining tools unlisted (logged).
pub const MAX_TOOL_LIST_PAGES: u64 = 20;

/// The `tools/list` params for the page after `cursor` (the first page has none).
pub fn tools_list_params(cursor: Option<&str>) -> Value {
    cursor.map_or_else(
        || serde_json::json!({}),
        |c| serde_json::json!({ "cursor": c }),
    )
}

/// How long a tool list may be cached (`2026-07-28` `CacheableResult`), over every page read:
/// the shortest `ttlMs`, and private when any page's `cacheScope` is `private`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ListCache {
    pub ttl_ms: Option<u64>,
    pub private: bool,
}

impl ListCache {
    fn merge(&mut self, page: &Value) {
        if let Some(ttl) = page.get("ttlMs").and_then(Value::as_u64) {
            self.ttl_ms = Some(self.ttl_ms.map_or(ttl, |t| t.min(ttl)));
        }
        self.private |= page.get("cacheScope").and_then(Value::as_str) == Some("private");
    }
}

/// Adds one `tools/list` page's tools to `tools` and its cache fields to `cache`, and returns
/// the next page's cursor: a non-empty `nextCursor` that differs from `cursor` (a repeated
/// cursor ends the walk).
pub fn take_tools_page(
    page: &Value,
    cursor: Option<&str>,
    tools: &mut Vec<Value>,
    cache: &mut ListCache,
) -> Option<String> {
    if let Some(listed) = page.get("tools").and_then(Value::as_array) {
        tools.extend(listed.iter().cloned());
    }
    cache.merge(page);
    page.get("nextCursor")
        .and_then(Value::as_str)
        .filter(|next| !next.is_empty() && Some(*next) != cursor)
        .map(str::to_owned)
}

/// The `result` of a JSON-RPC answer, accepted only when complete. `2026-07-28` marks an
/// interim multi-round-trip result `input_required`; Bistre answers no server requests, so
/// it fails closed instead of reading as a finished tool result. A result without
/// `resultType` (earlier revisions) is complete.
pub fn complete_result(resp: &Value) -> BistreResult<&Value> {
    let result = resp.get("result").ok_or_else(|| {
        BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "mcp_no_result")
    })?;
    match result.get("resultType").and_then(Value::as_str) {
        None | Some("complete") => Ok(result),
        Some("input_required") => Err(BistreError::with_detail(
            DiagnosticKey::ProviderRequestFailed,
            "mcp_input_required",
        )),
        Some(_) => Err(BistreError::with_detail(
            DiagnosticKey::ProviderRequestFailed,
            "mcp_result_type_unknown",
        )),
    }
}

/// An HTTP server's era, and for a legacy server its open session, reused across calls so a
/// stateful `2025-11-25` server keeps its state between the tool calls of a run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HttpEra {
    Modern,
    Legacy {
        session_id: Option<String>,
        protocol_version: String,
    },
}

static HTTP_ERAS: LazyLock<Mutex<HashMap<String, HttpEra>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// The cache key: an edited URL is a new origin and is probed again.
#[must_use]
pub fn http_era_key(server: &McpServerConfig) -> String {
    json!([server.id, server.url.trim()]).to_string()
}

#[must_use]
pub fn cached_http_era(key: &str) -> Option<HttpEra> {
    lock_or_recover(&HTTP_ERAS, "mcp_http_eras")
        .get(key)
        .cloned()
}

/// Remembers `era` for `key`; a full cache is cleared first (every entry can be re-probed).
pub fn remember_http_era(key: &str, era: HttpEra) {
    let mut map = lock_or_recover(&HTTP_ERAS, "mcp_http_eras");
    if map.len() >= MAX_HTTP_ERAS && !map.contains_key(key) {
        map.clear();
    }
    map.insert(key.to_owned(), era);
}

/// Forgets one server's era after a failed call, so the next call probes again.
pub fn forget_http_era(key: &str) {
    lock_or_recover(&HTTP_ERAS, "mcp_http_eras").remove(key);
}

/// Forgets the eras of servers whose key is not in `kept` (removed, or with an edited URL) and
/// returns them, so their legacy sessions can be closed; `None` forgets every era.
pub fn forget_http_eras_except<S: std::hash::BuildHasher>(
    kept: Option<&std::collections::HashSet<String, S>>,
) -> Vec<(String, HttpEra)> {
    let mut map = lock_or_recover(&HTTP_ERAS, "mcp_http_eras");
    let gone: Vec<String> = map
        .keys()
        .filter(|k| kept.is_none_or(|keep| !keep.contains(*k)))
        .cloned()
        .collect();
    gone.into_iter()
        .filter_map(|k| map.remove(&k).map(|era| (k, era)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rpc_err(code: i64) -> BistreResult<Value> {
        Err(BistreError::with_detail(
            DiagnosticKey::ProviderRequestFailed,
            format!("mcp_rpc_error_{code};reason=x"),
        ))
    }

    fn detail(d: &str) -> BistreResult<Value> {
        Err(BistreError::with_detail(
            DiagnosticKey::ProviderRequestFailed,
            d,
        ))
    }

    #[test]
    fn the_probe_tells_modern_from_legacy_and_never_falls_back_on_a_modern_error() {
        let modern = json!({"result": {"resultType": "complete", "supportedVersions": ["2025-11-25", "2026-07-28"]}});
        assert_eq!(probe_verdict(Ok(modern)).ok(), Some(ProbeVerdict::Modern));
        let other = json!({"result": {"supportedVersions": ["2027-01-01"]}});
        let err = probe_verdict(Ok(other)).err().and_then(|e| e.detail_code);
        assert_eq!(
            err.as_deref(),
            Some("mcp_protocol_unsupported;reason=2027-01-01")
        );
        assert!(
            probe_verdict(rpc_err(-32022)).is_err(),
            "unsupported version"
        );
        assert_eq!(
            probe_verdict(rpc_err(-32601)).ok(),
            Some(ProbeVerdict::Legacy)
        );
        assert_eq!(
            probe_verdict(rpc_err(-32602)).ok(),
            Some(ProbeVerdict::Legacy)
        );
        assert_eq!(
            probe_verdict(detail("mcp_stdio_timeout")).ok(),
            Some(ProbeVerdict::Legacy)
        );
        assert_eq!(
            probe_verdict(detail("mcp_http_404")).ok(),
            Some(ProbeVerdict::Legacy)
        );
        assert!(
            probe_verdict(detail("mcp_http_503")).is_err(),
            "a 5xx is surfaced"
        );
        assert!(
            probe_verdict(detail("mcp_stdio_eof")).is_err(),
            "a crash is surfaced"
        );
    }

    #[test]
    fn only_a_complete_result_is_accepted() {
        let done = json!({"result": {"content": []}});
        assert!(complete_result(&done).is_ok(), "no resultType is complete");
        let tagged = json!({"result": {"resultType": "complete"}});
        assert!(complete_result(&tagged).is_ok());
        let interim = json!({"result": {"resultType": "input_required", "inputRequests": {}}});
        let err = complete_result(&interim).err().and_then(|e| e.detail_code);
        assert_eq!(err.as_deref(), Some("mcp_input_required"));
        let odd = json!({"result": {"resultType": "partial"}});
        assert!(complete_result(&odd).is_err());
        assert!(complete_result(&json!({"jsonrpc": "2.0"})).is_err());
    }

    #[test]
    fn modern_meta_is_added_to_every_params_shape() {
        let p = with_modern_meta(json!({"name": "t"}));
        assert_eq!(p["name"], "t");
        assert_eq!(
            p["_meta"]["io.modelcontextprotocol/protocolVersion"],
            MCP_PROTOCOL_2026
        );
        assert!(p["_meta"]["io.modelcontextprotocol/clientCapabilities"].is_object());
        assert_eq!(
            p["_meta"]["io.modelcontextprotocol/clientInfo"]["name"],
            "Bistre"
        );
        assert!(with_modern_meta(Value::Null)["_meta"].is_object());
    }
}
