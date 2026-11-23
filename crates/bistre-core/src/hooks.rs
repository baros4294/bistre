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

/// Reads `.bistre/hooks.json` from `workspace_root`. A missing file means no hooks; an
/// unreadable or malformed one is an error, so a broken config never silently disables hooks.
pub fn load_workspace_hooks(workspace_root: &Path) -> BistreResult<Vec<WorkspaceHookConfig>> {
    let path = workspace_root.join(".bistre").join("hooks.json");
    let raw = match std::fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(_) => {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "hooks_json_read",
            ));
        }
    };
    serde_json::from_str::<Vec<WorkspaceHookConfig>>(&raw)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "hooks_json_parse"))
}

/// Runs matching workspace lifecycle hooks with `kill_on_drop(true)` and stripped provider keys.
pub async fn run_lifecycle_hooks(
    workspace_root: &Path,
    event: HookEventKind,
    tool_name: Option<&str>,
) -> BistreResult<Vec<HookExecutionResult>> {
    let hooks = load_workspace_hooks(workspace_root)?;
    let mut results = Vec::new();

    for hook in hooks {
        if hook.event != event {
            continue;
        }
        if let Some(ref filter) = hook.tool_filter
            && !filter.trim().is_empty()
            && tool_name != Some(filter.as_str())
        {
            continue;
        }
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

    Ok(results)
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

        let skipped = run_lifecycle_hooks(dir.path(), HookEventKind::PostToolUse, Some("read"))
            .await
            .ok();
        assert_eq!(skipped.as_ref().map(Vec::len), Some(0));

        let ran = run_lifecycle_hooks(dir.path(), HookEventKind::PostToolUse, Some("edit"))
            .await
            .ok();
        assert_eq!(ran.as_ref().map(Vec::len), Some(1));
        assert!(ran.as_ref().and_then(|v| v.first()).is_some_and(|r| r.ok));
        Ok(())
    }
}
