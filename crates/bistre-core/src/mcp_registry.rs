//! Search of the public MCP Registry, turned into server profiles Bistre can run.
//!
//! The registry is fetched through `PublicWebTransport` with a body cap, parsed once into
//! [`McpRegistryEntry`] values, and entries Bistre cannot run as they are (required secrets,
//! environment variables, headers, URL templates, unknown package types, or package names that
//! could be read as options) are left out. A profile from here starts turned off, so the user
//! sees the command or address before anything starts.

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::mcp::McpServerConfig;
use crate::ssrf::PublicWebTransport;

/// The registry's server search endpoint.
const REGISTRY_SERVERS_URL: &str = "https://registry.modelcontextprotocol.io/v0.1/servers";
/// Results asked for per page.
const PAGE_SIZE: u32 = 20;
/// Largest search response read.
const MAX_REGISTRY_BYTES: usize = 2 * 1024 * 1024;
/// Most characters kept from a description or name.
const MAX_TEXT_CHARS: usize = 300;
/// Longest search text sent.
const MAX_QUERY_CHARS: usize = 100;

/// One server from the registry, ready to add.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct McpRegistryEntry {
    /// The registry name (`io.github.owner/server`).
    pub name: String,
    pub description: String,
    pub version: String,
    /// The profile to save; `enabled` is false.
    pub server: McpServerConfig,
}

/// One page of search results.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct McpRegistryPage {
    pub entries: Vec<McpRegistryEntry>,
    /// Pass back to get the next page; `None` on the last one.
    pub next_cursor: Option<String>,
}

/// Searches the registry for `query` (empty lists everything), newest versions only.
pub async fn search_registry(
    web: &PublicWebTransport,
    query: &str,
    cursor: Option<&str>,
) -> BistreResult<McpRegistryPage> {
    let mut url = reqwest::Url::parse(REGISTRY_SERVERS_URL)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "registry_url"))?;
    {
        let mut q = url.query_pairs_mut();
        q.append_pair("limit", &PAGE_SIZE.to_string());
        q.append_pair("version", "latest");
        let query: String = query.trim().chars().take(MAX_QUERY_CHARS).collect();
        if !query.is_empty() {
            q.append_pair("search", &query);
        }
        if let Some(cursor) = cursor.filter(|c| !c.is_empty()) {
            q.append_pair("cursor", cursor);
        }
    }
    let fetched = web.get(url.as_str(), MAX_REGISTRY_BYTES).await?;
    if fetched.truncated || !(200..300).contains(&fetched.status) {
        return Err(BistreError::with_detail(
            DiagnosticKey::ProviderRequestFailed,
            "mcp_registry",
        ));
    }
    parse_registry_page(&fetched.body)
}

/// Parses one registry response; a body that is not the registry's shape is an error.
pub fn parse_registry_page(body: &[u8]) -> BistreResult<McpRegistryPage> {
    let bad = || BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "mcp_registry");
    let root: Value = serde_json::from_slice(body).map_err(|_| bad())?;
    let servers = root
        .get("servers")
        .and_then(Value::as_array)
        .ok_or_else(bad)?;
    let entries = servers
        .iter()
        .take(PAGE_SIZE as usize * 2)
        .filter_map(|item| entry(item.get("server")?))
        .collect();
    let next_cursor = root
        .pointer("/metadata/nextCursor")
        .and_then(Value::as_str)
        .filter(|c| !c.is_empty())
        .map(str::to_owned);
    Ok(McpRegistryPage {
        entries,
        next_cursor,
    })
}

fn text(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .chars()
        .take(MAX_TEXT_CHARS)
        .collect()
}

fn entry(server: &Value) -> Option<McpRegistryEntry> {
    let name = text(server, "name");
    if name.is_empty() {
        return None;
    }
    let version = text(server, "version");
    let (transport, command, args, url) = remote(server).or_else(|| package(server))?;
    let title = text(server, "title");
    Some(McpRegistryEntry {
        description: text(server, "description"),
        server: McpServerConfig {
            id: format!("mcp_{}", uuid::Uuid::now_v7().simple()),
            name: if title.is_empty() {
                name.rsplit('/').next().unwrap_or(&name).to_owned()
            } else {
                title
            },
            transport,
            command,
            args,
            url,
            enabled: false,
        },
        name,
        version,
    })
}

type Launch = (String, String, Vec<String>, String);

/// Whether any item of `list` must be filled in by the user.
fn needs_input(list: Option<&Value>) -> bool {
    list.and_then(Value::as_array).is_some_and(|items| {
        items.iter().any(|i| {
            i.get("isRequired").and_then(Value::as_bool) == Some(true)
                && i.get("value").is_none()
                && i.get("default").is_none()
        })
    })
}

/// A Streamable HTTP address over HTTPS with nothing to fill in.
fn remote(server: &Value) -> Option<Launch> {
    server.get("remotes")?.as_array()?.iter().find_map(|r| {
        let url = r.get("url")?.as_str()?.trim();
        let ok = r.get("type")?.as_str()? == "streamable-http"
            && url.starts_with("https://")
            && !url.contains('{')
            && !needs_input(r.get("headers"))
            && !needs_input(r.get("variables"));
        ok.then(|| ("http".to_owned(), String::new(), Vec::new(), url.to_owned()))
    })
}

/// A package name or version that cannot be read as an option or carry shell syntax.
fn safe_token(raw: &str) -> bool {
    !raw.is_empty()
        && !raw.starts_with('-')
        && raw.len() <= 214
        && raw
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '@' | '/' | '.' | '_' | '-' | '+'))
}

/// An `npm` or `PyPI` package that runs over stdio with nothing to fill in.
fn package(server: &Value) -> Option<Launch> {
    server.get("packages")?.as_array()?.iter().find_map(|p| {
        let stdio = p.pointer("/transport/type")?.as_str()? == "stdio";
        let id = p.get("identifier")?.as_str()?.trim();
        let version = p.get("version").and_then(Value::as_str).unwrap_or("");
        let fillable = needs_input(p.get("environmentVariables"))
            || needs_input(p.get("packageArguments"))
            || needs_input(p.get("runtimeArguments"));
        if !stdio || fillable || !safe_token(id) || !(version.is_empty() || safe_token(version)) {
            return None;
        }
        let (command, spec) = match p.get("registryType")?.as_str()? {
            "npm" if version.is_empty() => ("npx", id.to_owned()),
            "npm" => ("npx", format!("{id}@{version}")),
            "pypi" if version.is_empty() => ("uvx", id.to_owned()),
            "pypi" => ("uvx", format!("{id}=={version}")),
            _ => return None,
        };
        let mut args = Vec::new();
        if command == "npx" {
            args.push("-y".to_owned());
        }
        args.push(spec);
        Some(("stdio".to_owned(), command.to_owned(), args, String::new()))
    })
}

#[cfg(test)]
mod tests {
    use super::parse_registry_page;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    fn page(servers: &serde_json::Value) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec(&serde_json::json!({
            "servers": servers,
            "metadata": { "nextCursor": "next:1", "count": 1 }
        }))
    }

    #[test]
    fn runnable_servers_become_profiles_that_start_turned_off() -> TestResult {
        let body = page(&serde_json::json!([
            { "server": {
                "name": "io.github.acme/notes",
                "description": "Notes",
                "version": "1.2.0",
                "remotes": [
                    { "type": "sse", "url": "https://acme.example/sse" },
                    { "type": "streamable-http", "url": "https://acme.example/mcp" }
                ]
            }},
            { "server": {
                "name": "io.github.acme/files",
                "version": "0.3.1",
                "packages": [{
                    "registryType": "npm", "identifier": "@acme/files-mcp", "version": "0.3.1",
                    "transport": { "type": "stdio" },
                    "environmentVariables": [{ "name": "ROOT", "default": "." }]
                }]
            }},
            { "server": {
                "name": "io.github.acme/py",
                "version": "2.0.0",
                "packages": [{
                    "registryType": "pypi", "identifier": "acme-mcp", "version": "2.0.0",
                    "transport": { "type": "stdio" }
                }]
            }}
        ]))?;
        let parsed = parse_registry_page(&body)?;
        assert_eq!(parsed.next_cursor.as_deref(), Some("next:1"));
        let got: Vec<_> = parsed
            .entries
            .iter()
            .map(|e| {
                (
                    e.server.name.as_str(),
                    e.server.transport.as_str(),
                    e.server.command.as_str(),
                    e.server.args.clone(),
                    e.server.url.as_str(),
                    e.server.enabled,
                )
            })
            .collect();
        assert_eq!(
            got,
            vec![
                (
                    "notes",
                    "http",
                    "",
                    vec![],
                    "https://acme.example/mcp",
                    false
                ),
                (
                    "files",
                    "stdio",
                    "npx",
                    vec!["-y".to_owned(), "@acme/files-mcp@0.3.1".to_owned()],
                    "",
                    false
                ),
                (
                    "py",
                    "stdio",
                    "uvx",
                    vec!["acme-mcp==2.0.0".to_owned()],
                    "",
                    false
                ),
            ]
        );
        Ok(())
    }

    #[test]
    fn servers_that_need_input_or_look_unsafe_are_left_out() -> TestResult {
        let stdio = |id: &str, extra: serde_json::Value| {
            let mut p = serde_json::json!({
                "registryType": "npm", "identifier": id, "version": "1.0.0",
                "transport": { "type": "stdio" }
            });
            if let (Some(map), Some(more)) = (p.as_object_mut(), extra.as_object()) {
                map.extend(more.clone());
            }
            serde_json::json!({ "server": { "name": format!("x/{id}"), "packages": [p] } })
        };
        let body = page(&serde_json::json!([
            stdio("needs-key", serde_json::json!({
                "environmentVariables": [{ "name": "API_KEY", "isRequired": true, "isSecret": true }]
            })),
            stdio("--eval=evil", serde_json::json!({})),
            stdio("semi;colon", serde_json::json!({})),
            { "server": { "name": "x/plain-http", "remotes": [
                { "type": "streamable-http", "url": "http://acme.example/mcp" }
            ]}},
            { "server": { "name": "x/templated", "remotes": [
                { "type": "streamable-http", "url": "https://{tenant}.acme.example/mcp" }
            ]}},
            { "server": { "name": "x/needs-header", "remotes": [
                { "type": "streamable-http", "url": "https://acme.example/mcp",
                  "headers": [{ "name": "Authorization", "isRequired": true }] }
            ]}},
            { "server": { "name": "x/docker", "packages": [{
                "registryType": "oci", "identifier": "acme/mcp", "transport": { "type": "stdio" }
            }]}}
        ]))?;
        assert_eq!(parse_registry_page(&body)?.entries, Vec::new());
        assert!(parse_registry_page(b"{\"items\": []}").is_err());
        assert!(parse_registry_page(b"not json").is_err());
        Ok(())
    }
}
