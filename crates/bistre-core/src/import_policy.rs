//! Untrusted import policy (`with_imported_permissions`, Spec 06 / Spec 07).
//!
//! Anything that arrives from outside the user's own device (character cards, `.charx`
//! archives, shared configs) is data, never authority:
//! - Local filesystem, shell, web, and MCP grants embedded in extensions are stripped.
//! - Local MCP server commands are dropped (an imported card can never launch a process).
//! - Windows UNC paths (`\\server\share`, `//server/share`, `\\?\UNC\…`) are removed from every
//!   path-like field: merely probing such a path makes Windows send SMB credentials, leaking
//!   the user's NTLM hash to the remote host.
//! - Media paths are restricted to relative `media/<name>` entries.
//! - Transient tool screenshots are dropped.

use serde_json::{Map, Value};

use crate::story::card_io::ImportedCharacterBundle;

/// Extension keys that would grant capabilities if honored verbatim.
const STRIPPED_GRANT_KEYS: [&str; 10] = [
    "tools",
    "tool_permissions",
    "allowed_tools",
    "shell",
    "workspace_root",
    "workspace_path",
    "web_access",
    "mcp_servers",
    "permissions",
    "screenshots",
];

/// What the policy removed, so the UI can say so in plain words.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportPolicyReport {
    pub stripped_grants: u32,
    pub stripped_network_paths: u32,
    pub stripped_media_paths: u32,
}

impl ImportPolicyReport {
    pub const fn is_clean(&self) -> bool {
        self.stripped_grants == 0
            && self.stripped_network_paths == 0
            && self.stripped_media_paths == 0
    }
}

/// Returns `true` for Windows UNC / device network paths in either slash style.
pub fn is_windows_unc_path(raw: &str) -> bool {
    let p = raw.trim();
    let lower = p.to_ascii_lowercase();
    if lower.starts_with(r"\\?\unc\") || lower.starts_with("//?/unc/") {
        return true;
    }
    if lower.starts_with(r"\\?\") || lower.starts_with(r"\\.\") {
        // Local device namespace (`\\?\C:\…`) is not a network share.
        return false;
    }
    let bytes = p.as_bytes();
    bytes.len() > 2
        && (bytes[0] == b'\\' || bytes[0] == b'/')
        && (bytes[1] == b'\\' || bytes[1] == b'/')
        && bytes[2] != b'\\'
        && bytes[2] != b'/'
}

/// Accepts only empty or relative `media/<name>` paths without traversal.
pub fn sanitize_media_path(raw: &str) -> Option<String> {
    let p = raw.trim().replace('\\', "/");
    if p.is_empty() {
        return Some(String::new());
    }
    let rest = p.strip_prefix("media/")?;
    if rest.is_empty() || rest.contains('/') || rest.contains(':') || rest == "." || rest == ".." {
        return None;
    }
    Some(p)
}

/// Applies the untrusted-import policy to a decoded character bundle.
pub fn with_imported_permissions(
    mut bundle: ImportedCharacterBundle,
) -> (ImportedCharacterBundle, ImportPolicyReport) {
    let mut report = ImportPolicyReport::default();

    let avatar = bundle.card.avatar_path.clone();
    if is_windows_unc_path(&avatar) {
        report.stripped_network_paths += 1;
        bundle.card.avatar_path.clear();
    } else if let Some(clean) = sanitize_media_path(&avatar) {
        bundle.card.avatar_path = clean;
    } else {
        report.stripped_media_paths += 1;
        bundle.card.avatar_path.clear();
    }

    if let Ok(mut ext) = serde_json::from_str::<Value>(&bundle.card.extensions_json) {
        scrub_value(&mut ext, &mut report);
        bundle.card.extensions_json = ext.to_string();
    } else {
        "{}".clone_into(&mut bundle.card.extensions_json);
    }
    (bundle, report)
}

fn scrub_value(value: &mut Value, report: &mut ImportPolicyReport) {
    match value {
        Value::Object(map) => scrub_map(map, report),
        Value::Array(items) => {
            let before = items.len();
            items.retain(|v| !v.as_str().is_some_and(is_windows_unc_path));
            report.stripped_network_paths +=
                u32::try_from(before - items.len()).unwrap_or(u32::MAX);
            for item in items {
                scrub_value(item, report);
            }
        }
        Value::String(s) if is_windows_unc_path(s) => {
            report.stripped_network_paths += 1;
            s.clear();
        }
        _ => {}
    }
}

fn scrub_map(map: &mut Map<String, Value>, report: &mut ImportPolicyReport) {
    let keys: Vec<String> = map.keys().cloned().collect();
    for key in keys {
        let lower = key.to_ascii_lowercase();
        if STRIPPED_GRANT_KEYS.contains(&lower.as_str()) || lower == "command" || lower == "args" {
            map.remove(&key);
            report.stripped_grants += 1;
            continue;
        }
        if let Some(v) = map.get_mut(&key) {
            scrub_value(v, report);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bistre_protocol::CharacterCardRecord;

    fn bundle(avatar: &str, extensions: &str) -> ImportedCharacterBundle {
        ImportedCharacterBundle {
            card: CharacterCardRecord {
                name: "Mira".to_owned(),
                avatar_path: avatar.to_owned(),
                extensions_json: extensions.to_owned(),
                ..CharacterCardRecord::default()
            },
            lore_entries: Vec::new(),
        }
    }

    #[test]
    fn unc_detection_covers_both_slash_styles() {
        assert!(is_windows_unc_path(r"\\attacker\share\font.ttf"));
        assert!(is_windows_unc_path("//attacker/share/font.ttf"));
        assert!(is_windows_unc_path(r"\\?\UNC\attacker\share"));
        assert!(!is_windows_unc_path(r"\\?\C:\Users\me"));
        assert!(!is_windows_unc_path(r"C:\Users\me\font.ttf"));
        assert!(!is_windows_unc_path("media/avatar.png"));
        assert!(!is_windows_unc_path("/usr/share/fonts"));
    }

    #[test]
    fn strips_grants_mcp_commands_and_network_paths() {
        let ext = r#"{
            "bistre": {
                "tools": ["shell"],
                "mcp_servers": [{"command": "powershell", "args": ["-c", "evil"]}],
                "font": "\\\\attacker\\share\\x.ttf",
                "gallery": ["media/a.png", "//attacker/share/b.png"]
            },
            "depth_prompt": {"prompt": "stay in character"}
        }"#;
        let (out, report) = with_imported_permissions(bundle(r"\\attacker\share\a.png", ext));
        assert_eq!(out.card.avatar_path, "");
        assert!(report.stripped_grants >= 2);
        assert_eq!(report.stripped_network_paths, 3);
        let v: Value = serde_json::from_str(&out.card.extensions_json).unwrap_or(Value::Null);
        assert!(v.pointer("/bistre/tools").is_none());
        assert!(v.pointer("/bistre/mcp_servers").is_none());
        assert_eq!(v.pointer("/bistre/font").and_then(Value::as_str), Some(""));
        assert_eq!(
            v.pointer("/bistre/gallery")
                .and_then(Value::as_array)
                .map(Vec::len),
            Some(1)
        );
        assert_eq!(
            v.pointer("/depth_prompt/prompt").and_then(Value::as_str),
            Some("stay in character")
        );
    }

    #[test]
    fn media_paths_are_relative_media_only() {
        let (ok, r1) = with_imported_permissions(bundle("media/avatar.png", "{}"));
        assert_eq!(ok.card.avatar_path, "media/avatar.png");
        assert!(r1.is_clean());
        let (abs, r2) = with_imported_permissions(bundle("C:/Windows/system32/x.png", "{}"));
        assert_eq!(abs.card.avatar_path, "");
        assert_eq!(r2.stripped_media_paths, 1);
        assert_eq!(sanitize_media_path("media/../x"), None);
        assert_eq!(sanitize_media_path("media/a/b.png"), None);
    }
}
