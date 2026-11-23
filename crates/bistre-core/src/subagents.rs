//! Isolated background subagent sandboxes using `git worktree` with automatic copy-sandbox
//! fallback on non-git directories and Android, plus compact structured progress receipts
//! so parent runs stay uncluttered (Spec 04).

use std::path::{Path, PathBuf};

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, MoneyMicros};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::process_util::{no_window_command, run_bounded};

/// Upper bound for one `git worktree` call before the whole tree is killed.
const GIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

/// Isolated workspace handle created for a background subagent run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubagentSandbox {
    pub sandbox_id: String,
    pub source_root: String,
    pub sandbox_path: String,
    pub used_git_worktree: bool,
}

/// Compact structured receipt returned to parent runs without flooding parent context.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SubagentProgressReceipt {
    pub subagent_id: String,
    pub role: String,
    pub status: String,
    pub sandbox_path: String,
    pub used_git_worktree: bool,
    pub summary: String,
    pub cost_micros: MoneyMicros,
}

/// Prepares an isolated sandbox directory for a background subagent under `scratch_parent`:
/// - Uses `git worktree add --detach` when `source_root` is a valid Git repository and `git` is available.
/// - Falls back deterministically to a clean filtered directory copy on non-git folders or Android.
pub async fn prepare_worktree_sandbox(
    source_root: &Path,
    scratch_parent: &Path,
) -> BistreResult<SubagentSandbox> {
    if !source_root.is_dir() {
        return Err(BistreError::with_detail(
            DiagnosticKey::StorageNotFound,
            "workspace_root_missing",
        ));
    }

    let sandbox_id = Uuid::now_v7().to_string();
    let target_dir = scratch_parent.join(format!("wt-{sandbox_id}"));
    std::fs::create_dir_all(scratch_parent).map_err(|_| {
        BistreError::with_detail(DiagnosticKey::InternalError, "sandbox_parent_dir")
    })?;

    let is_git_repo = source_root.join(".git").exists();
    if is_git_repo {
        let mut cmd = no_window_command("git");
        cmd.arg("-C")
            .arg(source_root)
            .args(["worktree", "add", "--detach"])
            .arg(&target_dir)
            .arg("HEAD");
        if let Ok(out) = run_bounded(cmd, GIT_TIMEOUT).await
            && out.status.success()
            && target_dir.is_dir()
        {
            return Ok(SubagentSandbox {
                sandbox_id,
                source_root: source_root.display().to_string(),
                sandbox_path: target_dir.display().to_string(),
                used_git_worktree: true,
            });
        }
    }

    // Deterministic non-git / Android copy-sandbox fallback (skipping heavy VCS/build caches).
    copy_dir_filtered(source_root, &target_dir, 0)?;
    Ok(SubagentSandbox {
        sandbox_id,
        source_root: source_root.display().to_string(),
        sandbox_path: target_dir.display().to_string(),
        used_git_worktree: false,
    })
}

/// Cleans up a subagent sandbox cleanly (pruning `git worktree` registration if used).
pub async fn cleanup_worktree_sandbox(sandbox: &SubagentSandbox) -> BistreResult<()> {
    let target = PathBuf::from(&sandbox.sandbox_path);
    if sandbox.used_git_worktree {
        let mut cmd = no_window_command("git");
        cmd.arg("-C")
            .arg(&sandbox.source_root)
            .args(["worktree", "remove", "--force"])
            .arg(&target);
        // A failed `worktree remove` is recovered below by deleting the directory, and git
        // prunes the stale registration on its next `worktree prune`.
        if let Ok(out) = run_bounded(cmd, GIT_TIMEOUT).await
            && !out.status.success()
        {
            tracing::debug!(code = ?out.status.code(), "git worktree remove failed; removing directory");
        }
    }
    if target.exists() {
        std::fs::remove_dir_all(&target).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InternalError, "sandbox_cleanup")
        })?;
    }
    Ok(())
}

fn copy_dir_filtered(src: &Path, dst: &Path, depth: u8) -> BistreResult<()> {
    if depth > 8 {
        return Ok(());
    }
    std::fs::create_dir_all(dst)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "sandbox_mkdir"))?;
    let entries = std::fs::read_dir(src)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "sandbox_readdir"))?;

    for entry in entries.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if matches!(
            name_str.as_ref(),
            ".git" | "target" | "build" | "node_modules" | ".dart_tool" | ".bistre-dev"
        ) {
            continue;
        }
        let Ok(ft) = entry.file_type() else {
            continue;
        };
        let from = entry.path();
        let to = dst.join(&name);
        if ft.is_dir() {
            copy_dir_filtered(&from, &to, depth.saturating_add(1))?;
        } else if ft.is_file() {
            // Never copy secret files into scratch sandboxes.
            if crate::tools::is_forbidden_secret_path(&name_str) {
                continue;
            }
            std::fs::copy(&from, &to).map_err(|_| {
                BistreError::with_detail(DiagnosticKey::InternalError, "sandbox_copy")
            })?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[tokio::test]
    async fn copy_sandbox_fallback_isolates_workspace_and_skips_secrets() {
        let dir = tempdir().ok();
        let Some(dir) = dir else { return };
        let src = dir.path().join("project");
        let scratch = dir.path().join("sandboxes");
        assert!(std::fs::create_dir_all(&src).is_ok());
        assert!(std::fs::write(src.join("main.rs"), "fn main() {}\n").is_ok());
        assert!(std::fs::write(src.join(".env"), "SECRET=do-not-copy\n").is_ok());

        let sb = prepare_worktree_sandbox(&src, &scratch).await.ok();
        assert!(sb.is_some());
        let Some(sb) = sb else { return };
        assert!(!sb.used_git_worktree);

        let sb_root = PathBuf::from(&sb.sandbox_path);
        assert!(sb_root.join("main.rs").exists());
        assert!(!sb_root.join(".env").exists());

        assert!(cleanup_worktree_sandbox(&sb).await.is_ok());
        assert!(!sb_root.exists());
    }
}
