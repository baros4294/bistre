//! Local workspace lifecycle hooks (`PreToolUse`, `PostToolUse`, `RunFinished`, `RunFailed`)
//! loaded from `.bistre/hooks.json` with strict timeout and environment secret stripping.

use std::path::Path;
use std::time::Duration;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use serde::{Deserialize, Serialize};

use crate::process_util::{ShellKind, decode_clixml, preferred_shell, run_bounded, shell_command};

/// Supported workspace lifecycle hook events.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HookEventKind {
    PreToolUse,
    PostToolUse,
    RunFinished,
    RunFailed,
}

/// Configured hook entry inside `.bistre/hooks.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkspaceHookConfig {
    pub event: HookEventKind,
    pub command: String,
    #[serde(default)]
    pub tool_filter: Option<String>,
    #[serde(default = "default_hook_timeout_secs")]
    pub timeout_secs: u64,
}

const fn default_hook_timeout_secs() -> u64 {
    15
}

/// Execution outcome of a single workspace lifecycle hook.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HookExecutionResult {
    pub event: HookEventKind,
    pub command: String,
    pub ok: bool,
    pub exit_code: i32,
    pub output: String,
}

/// The hooks file of a workspace with its content digest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceHooks {
    pub hooks: Vec<WorkspaceHookConfig>,
    /// `blake3` hex of the raw file bytes; an approval covers exactly these bytes.
    pub digest: String,
}

/// A workspace's hooks as shown to the user for approval.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceHooksStatus {
    pub hooks: Vec<WorkspaceHookConfig>,
    pub digest: String,
    /// The user approved exactly this file.
    pub approved: bool,
}

/// Largest hooks file read (64 KiB).
const MAX_HOOKS_FILE_BYTES: u64 = 64 * 1024;

/// Reads `.bistre/hooks.json` from `workspace_root`. A missing file means no hooks (`None`);
/// an unreadable, oversized, or malformed one is an error, so a broken config never silently
/// disables hooks.
pub fn load_workspace_hooks(workspace_root: &Path) -> BistreResult<Option<WorkspaceHooks>> {
    let path = workspace_root.join(".bistre").join("hooks.json");
    let read_err = || BistreError::with_detail(DiagnosticKey::InvalidInput, "hooks_json_read");
    let bytes = match std::fs::metadata(&path) {
        Ok(meta) if meta.len() > MAX_HOOKS_FILE_BYTES => return Err(read_err()),
        Ok(_) => std::fs::read(&path).map_err(|_| read_err())?,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(read_err()),
    };
    let hooks = serde_json::from_slice::<Vec<WorkspaceHookConfig>>(&bytes)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "hooks_json_parse"))?;
    Ok(Some(WorkspaceHooks {
        hooks,
        digest: blake3::hash(&bytes).to_hex().to_string(),
    }))
}

/// `kv_meta` key holding the approved hooks digest for one workspace root.
pub fn hooks_approval_key(workspace_root: &Path) -> String {
    let root = workspace_root.to_string_lossy();
    format!(
        "agent.hooks_approved:{}",
        blake3::hash(root.as_bytes()).to_hex()
    )
}

/// What running the hooks of one event did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HookRun {
    /// No hook matches this event and tool.
    None,
    /// Matching hooks exist, but the user has not approved this exact hooks file (A-S5).
    NotApproved,
    /// Every matching hook ran (in order); each result says whether it succeeded.
    Ran(Vec<HookExecutionResult>),
}

/// Runs the hooks matching `event`/`tool_name` with `kill_on_drop(true)` and stripped
/// provider keys, but only when `approved_digest` equals the current file's digest.
pub async fn run_lifecycle_hooks(
    workspace_root: &Path,
    event: HookEventKind,
    tool_name: Option<&str>,
    approved_digest: Option<&str>,
) -> BistreResult<HookRun> {
    let Some(file) = load_workspace_hooks(workspace_root)? else {
        return Ok(HookRun::None);
    };
    let matching: Vec<WorkspaceHookConfig> = file
        .hooks
        .into_iter()
        .filter(|hook| hook.event == event)
        .filter(|hook| {
            hook.tool_filter
                .as_deref()
                .map(str::trim)
                .filter(|f| !f.is_empty())
                .is_none_or(|f| tool_name == Some(f))
        })
        .collect();
    if matching.is_empty() {
        return Ok(HookRun::None);
    }
    if approved_digest != Some(file.digest.as_str()) {
        return Ok(HookRun::NotApproved);
    }
    let mut results = Vec::with_capacity(matching.len());
    for hook in matching {
        let timeout = Duration::from_secs(hook.timeout_secs.clamp(1, 60));
        let shell = preferred_shell();
        let mut cmd = shell_command(shell, &hook.command, workspace_root);
        cmd.env("BISTRE_HOOK_EVENT", format!("{event:?}"));
        if let Some(tn) = tool_name {
            cmd.env("BISTRE_TOOL_NAME", tn);
        }

        let output = run_bounded(cmd, timeout).await.map_err(|err| {
            if err.detail_code.as_deref() == Some("process_timeout") {
                BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "hook_timeout")
            } else {
                BistreError::with_detail(DiagnosticKey::InternalError, "hook_spawn")
            }
        })?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        let raw_stderr = String::from_utf8_lossy(&output.stderr);
        let stderr = if shell == ShellKind::Pwsh {
            decode_clixml(&raw_stderr)
        } else {
            raw_stderr.into_owned()
        };
        let combined = format!("{stdout}{stderr}").trim().to_owned();
        results.push(HookExecutionResult {
            event,
            command: hook.command,
            ok: output.status.success(),
            exit_code: output.status.code().unwrap_or(-1),
            output: combined,
        });
    }

    Ok(HookRun::Ran(results))
}
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[tokio::test]
    async fn loads_and_executes_matching_lifecycle_hooks() -> TestResult {
        let dir = tempdir()?;
        let cfg_dir = dir.path().join(".bistre");
        assert!(std::fs::create_dir_all(&cfg_dir).is_ok());
        assert!(
            std::fs::write(
                cfg_dir.join("hooks.json"),
                r#"[{"event":"post_tool_use","tool_filter":"edit","command":"echo hook_ran"}]"#,
            )
            .is_ok()
        );

        let digest = load_workspace_hooks(dir.path())?.map_or_else(String::new, |h| h.digest);
        let skipped = run_lifecycle_hooks(
            dir.path(),
            HookEventKind::PostToolUse,
            Some("read"),
            Some(&digest),
        )
        .await?;
        assert_eq!(skipped, HookRun::None);

        let ran = run_lifecycle_hooks(
            dir.path(),
            HookEventKind::PostToolUse,
            Some("edit"),
            Some(&digest),
        )
        .await?;
        assert!(matches!(ran, HookRun::Ran(ref v) if v.len() == 1 && v[0].ok));
        Ok(())
    }

    /// A-S5: hooks run only when the user approved this exact file; any edit needs a new
    /// approval.
    #[tokio::test]
    async fn hooks_run_only_for_the_approved_file() -> TestResult {
        let dir = tempdir()?;
        let cfg_dir = dir.path().join(".bistre");
        std::fs::create_dir_all(&cfg_dir)?;
        std::fs::write(
            cfg_dir.join("hooks.json"),
            r#"[{"event":"pre_tool_use","command":"echo one"}]"#,
        )?;
        let approved = load_workspace_hooks(dir.path())?.map_or_else(String::new, |h| h.digest);
        let run = |digest: Option<String>| {
            let root = dir.path().to_path_buf();
            async move {
                run_lifecycle_hooks(
                    &root,
                    HookEventKind::PreToolUse,
                    Some("edit"),
                    digest.as_deref(),
                )
                .await
            }
        };
        assert_eq!(run(None).await?, HookRun::NotApproved);
        assert!(matches!(
            run(Some(approved.clone())).await?,
            HookRun::Ran(_)
        ));
        std::fs::write(
            cfg_dir.join("hooks.json"),
            r#"[{"event":"pre_tool_use","command":"echo two"}]"#,
        )?;
        assert_eq!(
            run(Some(approved)).await?,
            HookRun::NotApproved,
            "an edited file needs a new approval"
        );
        Ok(())
    }
}
