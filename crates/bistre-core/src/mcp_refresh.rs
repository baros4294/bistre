//! A server's cached tool list is listed again once it is no longer fresh: past its `ttlMs`,
//! changed (a `notifications/tools/list_changed`, `mcp_listen`), or, for a `private` list,
//! listed with another token. A send starts the refresh in the background and the next run
//! sends the new list; a private list for another token is dropped before the run, so a run
//! never sees it. A list with no `ttlMs` and no change stays until the user discovers again.

use std::collections::HashSet;
use std::sync::{Arc, LazyLock, Mutex};

use bistre_protocol::lock_or_recover;
use bistre_storage::StorageHandle;

use crate::InProcessEngine;
use crate::mcp::{McpDiscoveredTool, McpHttpTransport, McpServerConfig};

/// The `kv_meta` key prefix of when a server's tools were listed (Unix ms); the id follows.
const FETCHED_KEY_PREFIX: &str = "mcp.tools_fetched_ms:";

/// The `kv_meta` key prefix of the token a list was listed with ([`auth_context`]); the id
/// follows.
const AUTH_KEY_PREFIX: &str = "mcp.tools_auth:";

/// The BLAKE3 key-derivation context of [`auth_context`].
const AUTH_CONTEXT: &str = "bistre mcp tool list authorization context v1";

/// Most servers remembered as changed (the server list holds at most this many in practice).
const MAX_CHANGED_SERVERS: usize = 64;

/// Servers whose background refresh is running (one at a time per server).
static REFRESHING: LazyLock<Mutex<HashSet<String>>> = LazyLock::new(|| Mutex::new(HashSet::new()));

/// Servers that reported a changed tool list since they were last listed.
static CHANGED: LazyLock<Mutex<HashSet<String>>> = LazyLock::new(|| Mutex::new(HashSet::new()));

/// The authorization context of `bearer`: a keyed hash of the token (never the token), empty
/// for none.
pub(crate) fn auth_context(bearer: Option<&str>) -> String {
    bearer
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .map_or_else(String::new, |t| {
            blake3::Hash::from(blake3::derive_key(AUTH_CONTEXT, t.as_bytes()))
                .to_hex()
                .to_string()
        })
}

/// Records that `server_id`'s tool list changed; the next send lists it again.
pub(crate) fn note_list_changed(server_id: &str) {
    let mut changed = lock_or_recover(&CHANGED, "mcp_changed");
    if changed.len() < MAX_CHANGED_SERVERS || changed.contains(server_id) {
        changed.insert(server_id.to_owned());
    } else {
        tracing::warn!(server = %server_id, "too many changed mcp servers; waiting for ttl");
    }
}

/// Whether `server_id` reported a change it was not listed again after.
pub(crate) fn list_changed(server_id: &str) -> bool {
    lock_or_recover(&CHANGED, "mcp_changed").contains(server_id)
}

/// Caches `tools` as `server_id`'s list, listed at `now_ms` with the token whose
/// [`auth_context`] is `auth`; a failed write is logged and the previous list stays.
pub(crate) fn store_tools(
    storage: &StorageHandle,
    server_id: &str,
    tools: &[McpDiscoveredTool],
    now_ms: i64,
    auth: &str,
) {
    let json = match serde_json::to_string(tools) {
        Ok(json) => json,
        Err(err) => {
            tracing::warn!(%err, "failed to encode mcp tools for the cache");
            return;
        }
    };
    let written = storage
        .set_kv_meta(format!("mcp.tools_cache:{server_id}"), json)
        .and_then(|()| {
            storage.set_kv_meta(
                format!("{FETCHED_KEY_PREFIX}{server_id}"),
                now_ms.to_string(),
            )
        })
        .and_then(|()| {
            storage.set_kv_meta(format!("{AUTH_KEY_PREFIX}{server_id}"), auth.to_owned())
        });
    match written {
        Ok(()) => {
            lock_or_recover(&CHANGED, "mcp_changed").remove(server_id);
        }
        Err(err) => tracing::warn!(key = err.key.as_key(), "failed to cache mcp tools"),
    }
}

/// Whether a list fetched at `fetched_ms` (unknown for a list cached before times were kept)
/// is past its shortest `ttlMs` at `now_ms`.
fn is_stale(tools: &[McpDiscoveredTool], fetched_ms: Option<i64>, now_ms: i64) -> bool {
    let Some(ttl) = tools.iter().filter_map(|t| t.cache_ttl_ms).min() else {
        return false;
    };
    fetched_ms.is_none_or(|at| now_ms.saturating_sub(at) >= i64::try_from(ttl).unwrap_or(i64::MAX))
}

/// Whether a private list was listed with a token other than the one whose context is `auth`
/// (a list whose token is unknown or unreadable counts as another token).
fn listed_for_another_token(
    storage: &StorageHandle,
    server_id: &str,
    tools: &[McpDiscoveredTool],
    auth: &str,
) -> bool {
    if !tools.iter().any(|t| t.cache_private) {
        return false;
    }
    match storage.get_kv_meta(&format!("{AUTH_KEY_PREFIX}{server_id}")) {
        Ok(stored) => stored.as_deref() != Some(auth),
        Err(err) => {
            tracing::warn!(
                key = err.key.as_key(),
                "mcp list token unreadable; relisting"
            );
            true
        }
    }
}

fn fetched_ms(storage: &StorageHandle, server_id: &str) -> Option<i64> {
    match storage.get_kv_meta(&format!("{FETCHED_KEY_PREFIX}{server_id}")) {
        Ok(None) => None,
        Ok(Some(raw)) => match raw.parse() {
            Ok(ms) => Some(ms),
            Err(err) => {
                tracing::warn!(%err, "mcp list time malformed; treated as old");
                None
            }
        },
        Err(err) => {
            tracing::warn!(
                key = err.key.as_key(),
                "mcp list time unreadable; treated as old"
            );
            None
        }
    }
}

/// Lists `server`'s tools again in the background, unless a refresh of it is running.
pub(crate) fn spawn_refresh(
    storage: Arc<StorageHandle>,
    transport: McpHttpTransport,
    server: McpServerConfig,
    bearer: Option<String>,
) {
    if !lock_or_recover(&REFRESHING, "mcp_refreshing").insert(server.id.clone()) {
        return;
    }
    tokio::spawn(async move {
        match crate::mcp::discover_mcp_server(&transport, &server, bearer.as_deref()).await {
            Ok(report) => store_tools(
                &storage,
                &server.id,
                &report.tools,
                crate::engine_runs::utc_now_unix_ms(),
                &auth_context(bearer.as_deref()),
            ),
            Err(err) => tracing::warn!(
                key = err.key.as_key(),
                server = %server.id,
                "mcp tool list refresh failed; the cached list stays"
            ),
        }
        lock_or_recover(&REFRESHING, "mcp_refreshing").remove(&server.id);
    });
}

impl InProcessEngine {
    /// Before a send: drops each private list listed with another token, starts a background
    /// relisting of each enabled server whose list is no longer fresh, and keeps the
    /// `subscriptions/listen` streams of the enabled servers open.
    pub(crate) fn refresh_stale_mcp_tools(&self) {
        let now = crate::engine_runs::utc_now_unix_ms();
        let mut listened = Vec::new();
        for server in crate::agent_tools::load_enabled_mcp_servers(&self.storage) {
            let bearer = self.load_mcp_bearer(&server.id);
            let auth = auth_context(bearer.as_deref());
            let cached = crate::agent_tools::load_cached_mcp_tools(&self.storage, &server.id);
            let other_token = listed_for_another_token(&self.storage, &server.id, &cached, &auth);
            if other_token {
                // Fail closed: the run must not see tools listed for another token.
                store_tools(&self.storage, &server.id, &[], now, &auth);
                note_list_changed(&server.id);
            }
            let fresh = !other_token
                && !list_changed(&server.id)
                && !is_stale(&cached, fetched_ms(&self.storage, &server.id), now);
            if !fresh {
                spawn_refresh(
                    Arc::clone(&self.storage),
                    self.mcp_http.clone(),
                    server.clone(),
                    bearer.clone(),
                );
            }
            listened.push((server, bearer));
        }
        crate::mcp_listen::keep_listening(&self.storage, &self.mcp_http, listened);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tool(ttl: Option<u64>, private: bool) -> McpDiscoveredTool {
        McpDiscoveredTool {
            server_id: "s".to_owned(),
            name: "t".to_owned(),
            description: String::new(),
            input_schema: serde_json::json!({ "type": "object" }),
            cache_ttl_ms: ttl,
            cache_private: private,
        }
    }

    /// The shortest `ttlMs` decides; no `ttlMs` never expires; an unknown list time is old.
    #[test]
    fn a_list_expires_at_its_shortest_ttl() {
        let tools = [
            tool(Some(60_000), false),
            tool(Some(5_000), false),
            tool(None, false),
        ];
        assert!(!is_stale(&tools, Some(1_000), 5_999));
        assert!(is_stale(&tools, Some(1_000), 6_000));
        assert!(is_stale(&tools, None, 0));
        assert!(!is_stale(&[tool(None, false)], None, i64::MAX));
    }

    /// A private list holds only for the token it was listed with; a public one for any.
    #[test]
    fn a_private_list_holds_only_for_its_token() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("t.sqlite"))?;
        let first = auth_context(Some("token-a"));
        assert_ne!(first, auth_context(Some("token-b")));
        assert_eq!(auth_context(Some("  ")), "");
        assert!(!first.contains("token-a"));
        store_tools(&storage, "s", &[tool(None, true)], 1, &first);
        let cached = crate::agent_tools::load_cached_mcp_tools(&storage, "s");
        assert!(!listed_for_another_token(&storage, "s", &cached, &first));
        let second = auth_context(Some("token-b"));
        assert!(listed_for_another_token(&storage, "s", &cached, &second));
        assert!(!listed_for_another_token(
            &storage,
            "s",
            &[tool(None, false)],
            &second
        ));
        Ok(())
    }

    /// A change notice makes the list stale until it is listed again.
    #[test]
    fn a_changed_list_stays_changed_until_listed_again() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("t.sqlite"))?;
        note_list_changed("changed-srv");
        assert!(list_changed("changed-srv"));
        store_tools(&storage, "changed-srv", &[], 1, "");
        assert!(!list_changed("changed-srv"));
        Ok(())
    }
}
