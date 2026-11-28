//! Progressive-disclosure `SKILL.md` frontmatter indexer and `AGENTS.md` workspace discovery.
//!
//! Only lightweight YAML frontmatter (`name` + `description`) is indexed at startup so context
//! stays tiny; full `SKILL.md` instructions load strictly on demand when activated.

use std::path::{Path, PathBuf};

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use serde::{Deserialize, Serialize};

const MAX_SKILL_BODY_BYTES: usize = 128 * 1024;
/// Maximum indexed skills per workspace.
const MAX_INDEXED_SKILLS: usize = 64;
/// `SKILL.md` files above this size are skipped during discovery (never read whole).
const MAX_SKILL_FILE_BYTES: u64 = 512 * 1024;

/// Compact metadata entry indexed from `SKILL.md` YAML frontmatter.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SkillIndexEntry {
    pub name: String,
    pub description: String,
    pub path: String,
}

/// Scans `.agents/skills/*/SKILL.md` and `skills/*/SKILL.md` inside `workspace_root`,
/// returning sorted frontmatter entries without loading full bodies into memory.
pub fn discover_workspace_skills(workspace_root: &Path) -> Vec<SkillIndexEntry> {
    let mut found = discover_skills_in(&workspace_root.join(".agents").join("skills"));
    found.extend(discover_skills_in(&workspace_root.join("skills")));
    found.sort_by(|a, b| a.name.cmp(&b.name));
    found.dedup_by(|a, b| a.name == b.name);
    found.truncate(MAX_INDEXED_SKILLS);
    found
}

/// The skills in `dir` (`<dir>/<folder>/SKILL.md`), at most `MAX_INDEXED_SKILLS`, sorted by
/// name. A missing folder has none; a `SKILL.md` that cannot be read is logged and skipped.
pub fn discover_skills_in(dir: &Path) -> Vec<SkillIndexEntry> {
    let mut found = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return found;
    };
    for entry in entries.flatten() {
        if found.len() >= MAX_INDEXED_SKILLS {
            break;
        }
        let candidate = entry.path().join("SKILL.md");
        if !candidate
            .metadata()
            .is_ok_and(|m| m.is_file() && m.len() <= MAX_SKILL_FILE_BYTES)
        {
            continue;
        }
        match std::fs::read_to_string(&candidate) {
            Ok(raw) => {
                let (name, description) =
                    parse_skill_frontmatter(&raw, &entry.file_name().to_string_lossy());
                found.push(SkillIndexEntry {
                    name,
                    description,
                    path: candidate.display().to_string(),
                });
            }
            Err(err) => tracing::warn!(error = %err, "skill file unreadable; skipped"),
        }
    }
    found.sort_by(|a, b| a.name.cmp(&b.name));
    found
}

/// Loads the full `SKILL.md` instruction body on demand (capped at 128 KiB).
pub fn load_skill_body(workspace_root: &Path, skill_path: &Path) -> BistreResult<String> {
    let canon_root = std::fs::canonicalize(workspace_root)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "workspace_canon"))?;
    let canon_file = std::fs::canonicalize(skill_path)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "skill_not_found"))?;
    if !canon_file.starts_with(&canon_root)
        || canon_file.file_name().is_none_or(|n| n != "SKILL.md")
    {
        return Err(BistreError::with_detail(
            DiagnosticKey::ToolPathDenied,
            "skill_outside_workspace",
        ));
    }
    let mut text = std::fs::read_to_string(&canon_file)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "skill_read"))?;
    if text.len() > MAX_SKILL_BODY_BYTES {
        let cut = text.floor_char_boundary(MAX_SKILL_BODY_BYTES);
        text.truncate(cut);
        text.push_str("\n...[truncated]");
    }
    Ok(text)
}

/// Discovers a workspace-level `AGENTS.md` contract file if present.
pub fn discover_agents_md(workspace_root: &Path) -> Option<(PathBuf, String)> {
    let candidate = workspace_root.join("AGENTS.md");
    if !candidate.is_file() {
        return None;
    }
    let text = std::fs::read_to_string(&candidate).ok()?;
    Some((candidate, text))
}

/// Discovers workspace-level instruction files (`AGENTS.md` and `CLAUDE.md`) in order.
pub fn discover_workspace_instructions(workspace_root: &Path) -> Vec<(PathBuf, String)> {
    let mut out = Vec::new();
    for name in ["AGENTS.md", "CLAUDE.md"] {
        let candidate = workspace_root.join(name);
        if candidate.is_file()
            && let Ok(text) = std::fs::read_to_string(&candidate)
            && !text.trim().is_empty()
        {
            out.push((candidate, text));
        }
    }
    out
}

pub(crate) fn parse_skill_frontmatter(raw: &str, fallback_name: &str) -> (String, String) {
    let mut name = fallback_name.to_owned();
    let mut description = String::new();
    let normalized = raw.replace("\r\n", "\n");
    let Some(rest) = normalized.strip_prefix("---\n") else {
        return (name, description);
    };
    let Some(end_idx) = rest.find("\n---") else {
        return (name, description);
    };
    let frontmatter = &rest[..end_idx];

    for line in frontmatter.lines() {
        let trimmed = line.trim();
        if let Some(val) = trimmed.strip_prefix("name:") {
            let cleaned = val.trim().trim_matches('"').trim_matches('\'');
            if !cleaned.is_empty() {
                cleaned.clone_into(&mut name);
            }
        } else if let Some(val) = trimmed.strip_prefix("description:") {
            let cleaned = val.trim().trim_matches('"').trim_matches('\'');
            if !cleaned.is_empty() {
                cleaned.clone_into(&mut description);
            }
        }
    }
    (name, description)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    /// A file outside the workspace is a path denial with its own key, not an "edit hash
    /// mismatch" (which sent the user to the wrong fix).
    #[test]
    fn a_skill_outside_the_workspace_is_a_path_denial() -> TestResult {
        let ws = tempdir()?;
        let outside = tempdir()?;
        let file = outside.path().join("SKILL.md");
        std::fs::write(&file, "---\nname: x\n---\nbody")?;
        let err = load_skill_body(ws.path(), &file)
            .err()
            .ok_or("must be denied")?;
        assert_eq!(err.key, DiagnosticKey::ToolPathDenied);
        Ok(())
    }

    #[test]
    fn discovers_skill_frontmatter_and_loads_body_on_demand() -> TestResult {
        let dir = tempdir()?;
        let skill_dir = dir.path().join(".agents").join("skills").join("review");
        assert!(std::fs::create_dir_all(&skill_dir).is_ok());
        assert!(
            std::fs::write(
                skill_dir.join("SKILL.md"),
                "---\nname: code-review\ndescription: Rigorous security & diff audit\n---\n# Instructions\nCheck every edge case.\n",
            )
            .is_ok()
        );
        assert!(std::fs::write(dir.path().join("AGENTS.md"), "# Contract\nNo unwrap.\n").is_ok());

        let indexed = discover_workspace_skills(dir.path());
        assert_eq!(indexed.len(), 1);
        assert_eq!(indexed[0].name, "code-review");
        assert_eq!(indexed[0].description, "Rigorous security & diff audit");

        let body = Some(load_skill_body(dir.path(), Path::new(&indexed[0].path))?);
        assert!(
            body.as_deref()
                .is_some_and(|b| b.contains("Check every edge case"))
        );

        let agents = discover_agents_md(dir.path());
        assert!(agents.is_some());
        Ok(())
    }
}
