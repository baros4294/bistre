//! Centralized child-process creation (`AGENTS.md` §7, enforced by `just guard`).
//!
//! Every Bistre child process is created through [`no_window_command`]:
//! - Windows: `CREATE_NO_WINDOW` (`0x0800_0000`) so consoles never flash or steal focus.
//! - Unix: the child leads its own process group so a timeout kills the whole tree.
//! - `stdin` is null and `kill_on_drop(true)` is set, so dropped futures never leak children.
//! - Lifetime containment (`bistre_crypto::containment`): Linux/Android children get
//!   `PR_SET_PDEATHSIG(SIGKILL)`; on Windows [`spawn_contained`] assigns every child to the
//!   process-wide `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (+ `DIE_ON_UNHANDLED_EXCEPTION`) Job Object, so a crashed Bistre never
//!   leaves tool, hook, or git children running. Spawning goes through [`spawn_contained`]
//!   (`clippy.toml` bans direct `spawn` / `output` / `status`).
//!
//! The Windows shell prefers `pwsh -NoLogo -NoProfile -NonInteractive -OutputFormat Text`
//! (falling back to `cmd /C`), with `#< CLIXML` stderr decoded back into plain text.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};
use std::sync::OnceLock;
use std::time::Duration;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use tokio::process::{Child, Command};

/// Win32 `CREATE_NO_WINDOW` process creation flag.
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Environment variables never inherited by tool, hook, or subagent children.
pub const SCRUBBED_ENV_VARS: [&str; 3] = ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY"];

/// Shell used for a user/agent-supplied command line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShellKind {
    Pwsh,
    Cmd,
    Sh,
}

/// The ONLY constructor for child processes in Bistre crates (raw `Command::new` is banned).
pub fn no_window_command(program: impl AsRef<OsStr>) -> Command {
    #[expect(
        clippy::disallowed_methods,
        reason = "Single audited construction site; every other crate path goes through this helper."
    )]
    let mut cmd = Command::new(program);
    cmd.stdin(Stdio::null()).kill_on_drop(true);
    #[cfg(windows)]
    {
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(unix)]
    {
        cmd.process_group(0);
    }
    contain_with_parent(cmd.as_std_mut());
    for var in SCRUBBED_ENV_VARS {
        cmd.env_remove(var);
    }
    cmd
}

/// Ties a `std::process::Command` child's lifetime to Bistre's on Linux/Android
/// (`PR_SET_PDEATHSIG(SIGKILL)`); a no-op elsewhere (Windows uses [`spawn_contained`]).
#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn contain_with_parent(cmd: &mut std::process::Command) {
    bistre_crypto::containment::kill_with_parent(cmd);
}

/// Ties a `std::process::Command` child's lifetime to Bistre's on Linux/Android
/// (`PR_SET_PDEATHSIG(SIGKILL)`); a no-op elsewhere (Windows uses [`spawn_contained`]).
#[cfg(not(any(target_os = "linux", target_os = "android")))]
pub fn contain_with_parent(_cmd: &mut std::process::Command) {}

/// Lifetime guard returned with every contained child. On Windows it owns the child's
/// kill-on-close Job Object: [`ChildContainment::kill_tree`] kills the child and every descendant,
/// and dropping the guard does the same for anything still running. Elsewhere it is empty
/// (Unix trees are killed through the child's process group).
#[derive(Debug, Default)]
pub struct ChildContainment {
    #[cfg(windows)]
    job: Option<bistre_crypto::containment::KillOnCloseJob>,
}

impl ChildContainment {
    /// Kills every process still in the job; returns `false` when no job is held.
    pub fn kill_tree(&self) -> bool {
        #[cfg(windows)]
        {
            self.job
                .as_ref()
                .is_some_and(bistre_crypto::containment::KillOnCloseJob::terminate)
        }
        #[cfg(not(windows))]
        {
            false
        }
    }

    /// Reports whether `child` is inside this guard's job.
    #[cfg(windows)]
    pub fn holds(&self, child: &Child) -> bool {
        match (self.job.as_ref(), child.raw_handle()) {
            (Some(job), Some(handle)) => job.contains(handle),
            _ => false,
        }
    }
}

/// The ONLY spawn site for [`no_window_command`] children: spawns `cmd` and, on Windows, places the
/// child in its own kill-on-close Job Object. A refused assignment is logged, never fatal, because
/// the timeout tree-kill and `kill_on_drop` still apply. Keep the guard alive as long as the child.
pub fn spawn_contained(cmd: &mut Command) -> std::io::Result<(Child, ChildContainment)> {
    #[expect(
        clippy::disallowed_methods,
        reason = "Single audited spawn site that applies Job Object containment."
    )]
    let child = cmd.spawn()?;
    #[cfg(windows)]
    {
        let job = bistre_crypto::containment::KillOnCloseJob::new()
            .filter(|job| child.raw_handle().is_some_and(|handle| job.assign(handle)));
        if job.is_none() {
            tracing::warn!("child process could not join a kill-on-close job object");
        }
        Ok((child, ChildContainment { job }))
    }
    #[cfg(not(windows))]
    {
        Ok((child, ChildContainment::default()))
    }
}

/// Win32 `CREATE_NEW_PROCESS_GROUP`: a console Ctrl+C in the app never reaches the child.
#[cfg(windows)]
const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
/// Win32 `CREATE_BREAKAWAY_FROM_JOB`: the child leaves a job the app itself was started in.
#[cfg(windows)]
const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;

/// The one child that is NOT contained: `bistre-daemon --active-scoped --data-dir <dir>`, which
/// must outlive the window so runs survive closing it (ADR-0003). It gets no window, its own
/// process group, no parent-death signal, and no kill-on-close job; it bounds its own life
/// by exiting once no app is attached and no work is live.
pub fn spawn_detached_daemon(exe: &Path, data_dir: &Path) -> std::io::Result<()> {
    let build = || {
        #[expect(
            clippy::disallowed_methods,
            reason = "Audited: the daemon must outlive the app, so it skips the contained helpers."
        )]
        let mut cmd = Command::new(exe);
        cmd.arg("--active-scoped")
            .arg("--data-dir")
            .arg(data_dir)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(false);
        for var in SCRUBBED_ENV_VARS {
            cmd.env_remove(var);
        }
        #[cfg(unix)]
        {
            cmd.process_group(0);
        }
        cmd
    };
    #[cfg(windows)]
    {
        // Breaking away is refused inside a job that does not allow it; then start it plainly.
        let mut cmd = build();
        cmd.creation_flags(CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB);
        #[expect(
            clippy::disallowed_methods,
            reason = "Audited detached daemon spawn; containment would kill it with the window."
        )]
        let first = cmd.spawn();
        if first.is_ok() {
            return first.map(drop);
        }
        let mut cmd = build();
        cmd.creation_flags(CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP);
        #[expect(
            clippy::disallowed_methods,
            reason = "Audited detached daemon spawn; containment would kill it with the window."
        )]
        let child = cmd.spawn();
        child.map(drop)
    }
    #[cfg(not(windows))]
    {
        // tokio reaps the exited child in the background, so it never lingers as a zombie.
        let mut cmd = build();
        #[expect(
            clippy::disallowed_methods,
            reason = "Audited detached daemon spawn; containment would kill it with the window."
        )]
        let child = cmd.spawn();
        child.map(drop)
    }
}

/// Returns the first `PATH` entry containing `exe` (checked once per process for the shell probe).
pub fn find_on_path(exe: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(exe))
        .find(|candidate| candidate.is_file())
}

/// Returns `true` when `path` points into Windows's Microsoft Store `WindowsApps` `AppExecAlias`
/// folder. Packaged MSIX `AppExecAlias` shims (such as Store-installed `pwsh.exe`) launch through
/// the Desktop Bridge outside the caller's Win32 Job Object, allowing grandchildren to outlive
/// `TerminateJobObject` and `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
pub fn is_windows_app_exec_alias(path: &Path) -> bool {
    let raw = path.to_string_lossy();
    let mut prev_microsoft = false;
    for segment in raw.split(['\\', '/']) {
        if prev_microsoft && segment.eq_ignore_ascii_case("windowsapps") {
            return true;
        }
        prev_microsoft = segment.eq_ignore_ascii_case("microsoft");
    }
    false
}

/// Returns the first non-AppExecAlias `pwsh.exe` on `PATH` so Win32 Job Object containment holds.
fn containable_pwsh_path() -> Option<&'static Path> {
    static PWSH: OnceLock<Option<PathBuf>> = OnceLock::new();
    PWSH.get_or_init(|| {
        let path = std::env::var_os("PATH")?;
        std::env::split_paths(&path)
            .map(|dir| dir.join("pwsh.exe"))
            .find(|candidate| candidate.is_file() && !is_windows_app_exec_alias(candidate))
    })
    .as_deref()
}

/// Picks the platform shell for a command line.
pub fn preferred_shell() -> ShellKind {
    if cfg!(windows) {
        if containable_pwsh_path().is_some() {
            ShellKind::Pwsh
        } else {
            ShellKind::Cmd
        }
    } else {
        ShellKind::Sh
    }
}

/// Builds a no-window shell command for `script` using `kind`, rooted at `cwd`.
pub fn shell_command(kind: ShellKind, script: &str, cwd: &Path) -> Command {
    let mut cmd = match kind {
        ShellKind::Pwsh => {
            let mut c = match containable_pwsh_path() {
                Some(path) => no_window_command(path),
                None => no_window_command("pwsh"),
            };
            c.args([
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-OutputFormat",
                "Text",
                "-Command",
                script,
            ]);
            c
        }
        ShellKind::Cmd => {
            let mut c = no_window_command("cmd");
            c.args(["/C", script]);
            c
        }
        ShellKind::Sh => {
            let mut c = no_window_command("sh");
            c.args(["-c", script]);
            c
        }
    };
    cmd.current_dir(cwd).env("PYTHONUNBUFFERED", "1");
    cmd
}

/// Decodes PowerShell `#< CLIXML` serialized error streams back into plain text lines.
/// Non-CLIXML input is returned unchanged.
pub fn decode_clixml(stderr: &str) -> String {
    let trimmed = stderr.trim_start();
    let Some(body) = trimmed.strip_prefix("#< CLIXML") else {
        return stderr.to_owned();
    };
    let mut out = String::new();
    let mut rest = body;
    while let Some(start) = rest.find("<S S=\"Error\">") {
        let after = &rest[start + "<S S=\"Error\">".len()..];
        let Some(end) = after.find("</S>") else {
            break;
        };
        out.push_str(&decode_clixml_text(&after[..end]));
        rest = &after[end + "</S>".len()..];
    }
    if out.is_empty() {
        stderr.to_owned()
    } else {
        out.trim_end().to_owned()
    }
}

fn decode_clixml_text(raw: &str) -> String {
    let mut s = raw
        .replace("_x000D__x000A_", "\n")
        .replace("_x000A_", "\n")
        .replace("_x000D_", "")
        .replace("_x0009_", "\t");
    for (entity, ch) in [
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
        ("&amp;", "&"),
    ] {
        s = s.replace(entity, ch);
    }
    s
}

/// Per-stream capture cap for [`run_bounded`]; output beyond it is drained and discarded so a
/// chatty child can never block on a full pipe or grow Bistre's memory without bound.
pub const MAX_CAPTURE_BYTES: u64 = 32 * 1024 * 1024;

async fn capture_pipe<R>(
    pipe: Option<R>,
    progress: Option<tokio::sync::mpsc::Sender<Vec<u8>>>,
) -> std::io::Result<Vec<u8>>
where
    R: tokio::io::AsyncRead + Unpin,
{
    use tokio::io::AsyncReadExt;

    let Some(mut pipe) = pipe else {
        return Ok(Vec::new());
    };
    let mut buf = Vec::new();
    let mut chunk = vec![0_u8; 8 * 1024];
    let cap = usize::try_from(MAX_CAPTURE_BYTES).unwrap_or(usize::MAX);
    while buf.len() < cap {
        let n = pipe.read(&mut chunk).await?;
        if n == 0 {
            return Ok(buf);
        }
        let take = n.min(cap - buf.len());
        buf.extend_from_slice(&chunk[..take]);
        // A full channel drops a progress copy, never the captured output itself.
        if let Some(tx) = &progress
            && tx.try_send(chunk[..take].to_vec()).is_err()
        {
            tracing::trace!("progress channel full; output still captured");
        }
    }
    tokio::io::copy(&mut pipe, &mut tokio::io::sink()).await?;
    Ok(buf)
}

/// Spawns `cmd`, waits up to `timeout`, and on expiry kills the whole process tree while the root
/// is still alive (so the tree walk can find every descendant) before reaping it.
pub async fn run_bounded(cmd: Command, timeout: Duration) -> BistreResult<Output> {
    run_bounded_with_progress(cmd, timeout, None).await
}

/// [`run_bounded`], also sending each piece of stdout and stderr to `progress` as it arrives
/// (a long shell command shows its output while it runs). A slow reader loses progress
/// copies, never output.
pub async fn run_bounded_with_progress(
    mut cmd: Command,
    timeout: Duration,
    progress: Option<tokio::sync::mpsc::Sender<Vec<u8>>>,
) -> BistreResult<Output> {
    let wait_err = |_| BistreError::with_detail(DiagnosticKey::InternalError, "process_wait");
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let (mut child, containment) = spawn_contained(&mut cmd)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "process_spawn"))?;
    let pid = child.id();
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let finished = tokio::time::timeout(timeout, async {
        tokio::join!(
            child.wait(),
            capture_pipe(stdout, progress.clone()),
            capture_pipe(stderr, progress)
        )
    })
    .await;
    if let Ok((status, stdout, stderr)) = finished {
        return Ok(Output {
            status: status.map_err(wait_err)?,
            stdout: stdout.map_err(wait_err)?,
            stderr: stderr.map_err(wait_err)?,
        });
    }
    // Terminate the kernel Job Object first (instant, atomic whole-tree kill on Windows) so
    // descendants cannot outlive a slow `taskkill` spawn under heavy CPU load; fall back to
    // walking/killing the process group on Unix or if no job object was attached.
    if !containment.kill_tree() {
        tracing::debug!("no job object to terminate for the timed-out child; killing process tree");
        if let Some(pid) = pid {
            kill_process_tree(pid).await;
        }
    }
    if child.kill().await.is_err() {
        tracing::debug!("timed-out child already exited before the final kill");
    }
    Err(BistreError::with_detail(
        DiagnosticKey::ProviderRequestFailed,
        "process_timeout",
    ))
}

/// Best-effort kill of `pid` and all of its descendants (no `unsafe`, no extra crates).
pub async fn kill_process_tree(pid: u32) {
    let pid_text = pid.to_string();
    let mut killer = if cfg!(windows) {
        let mut c = no_window_command("taskkill");
        c.args(["/PID", &pid_text, "/T", "/F"]);
        c
    } else {
        // The child leads its own process group (`process_group(0)`), so `-pid` names the group.
        let mut c = no_window_command("kill");
        c.args(["-KILL", "--", &format!("-{pid_text}")]);
        c
    };
    killer.stdout(Stdio::null()).stderr(Stdio::null());
    let Ok((mut child, _containment)) = spawn_contained(&mut killer) else {
        tracing::warn!("process tree killer could not be spawned");
        return;
    };
    // The tree may already be gone; failure to kill an exited tree is not an error.
    if tokio::time::timeout(Duration::from_secs(5), child.wait())
        .await
        .is_err()
    {
        tracing::warn!("process tree killer timed out");
    }
}

/// Executable / script extensions that Bistre never hands to the OS shell "open" verb.
pub const BLOCKED_OPEN_EXTENSIONS: [&str; 25] = [
    "exe", "com", "bat", "cmd", "ps1", "psm1", "vbs", "vbe", "js", "jse", "wsf", "wsh", "msi",
    "msp", "scr", "pif", "cpl", "hta", "jar", "lnk", "reg", "inf", "sh", "appimage", "desktop",
];

/// Returns `true` when `path` must never be opened by the OS (executables, scripts, shortcuts,
/// or Windows UNC network paths that trigger SMB/NTLM authentication on probe).
pub fn is_blocked_open_path(path: &str) -> bool {
    let trimmed = path.trim();
    if crate::import_policy::is_windows_unc_path(trimmed) {
        return true;
    }
    Path::new(trimmed)
        .extension()
        .and_then(OsStr::to_str)
        .is_some_and(|ext| {
            BLOCKED_OPEN_EXTENSIONS
                .iter()
                .any(|blocked| blocked.eq_ignore_ascii_case(ext))
        })
}

/// Validates a link before handing it to the OS browser: only an `http` or `https` URL with a
/// host and no user name or password. Any other scheme would hand the opener a local file or
/// another app's handler.
pub fn validate_web_link(url: &str) -> BistreResult<reqwest::Url> {
    let refused = || BistreError::with_detail(DiagnosticKey::InvalidInput, "web_link_refused");
    let link = reqwest::Url::parse(url.trim()).map_err(|_| refused())?;
    let has_host = link.host_str().is_some_and(|h| !h.is_empty());
    let has_login = !link.username().is_empty() || link.password().is_some();
    if matches!(link.scheme(), "http" | "https") && has_host && !has_login {
        Ok(link)
    } else {
        Err(refused())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clixml_error_stream_decodes_to_plain_text() {
        let raw = "#< CLIXML\r\n<Objs Version=\"1.1.0.1\" xmlns=\"http://schemas.microsoft.com/powershell/2004/04\"><S S=\"Error\">Get-Item : Cannot find path_x000D__x000A_</S><S S=\"Error\">&lt;x&gt; &amp; y_x000D__x000A_</S></Objs>";
        assert_eq!(decode_clixml(raw), "Get-Item : Cannot find path\n<x> & y");
        assert_eq!(decode_clixml("plain error\n"), "plain error\n");
    }

    #[test]
    fn blocked_open_paths_and_web_links() {
        assert!(is_blocked_open_path("C:/Users/me/Downloads/setup.EXE"));
        assert!(is_blocked_open_path("notes/run.ps1"));
        assert!(is_blocked_open_path(r"\\attacker\share\doc.pdf"));
        assert!(!is_blocked_open_path("C:/Users/me/Documents"));
        assert!(!is_blocked_open_path("report.pdf"));
        assert_eq!(BLOCKED_OPEN_EXTENSIONS.len(), 25);

        assert!(validate_web_link("https://example.com/a").is_ok());
        assert!(validate_web_link(" HTTP://example.com ").is_ok());
        assert!(validate_web_link("file:///etc/passwd").is_err());
        assert!(validate_web_link("javascript:alert(1)").is_err());
        assert!(validate_web_link("ms-settings:privacy").is_err());
        assert!(validate_web_link("https://user:pass@example.com").is_err());
        assert!(validate_web_link("https://user@example.com").is_err());
        assert!(validate_web_link("example.com").is_err());
    }

    /// A running command's output reaches the progress channel while it runs, not only
    /// when it ends.
    #[tokio::test]
    async fn output_arrives_while_the_command_still_runs() -> Result<(), Box<dyn std::error::Error>>
    {
        let dir = std::env::temp_dir();
        let shell = preferred_shell();
        let script = if cfg!(windows) {
            "echo first && ping -n 3 127.0.0.1 > NUL && echo second"
        } else {
            "echo first; sleep 2; echo second"
        };
        let (tx, mut rx) = tokio::sync::mpsc::channel::<Vec<u8>>(16);
        let run = run_bounded_with_progress(
            shell_command(shell, script, &dir),
            Duration::from_secs(30),
            Some(tx),
        );
        let watch = async {
            let mut first_seen = None;
            while let Some(chunk) = rx.recv().await {
                if first_seen.is_none() && String::from_utf8_lossy(&chunk).contains("first") {
                    first_seen = Some(std::time::Instant::now());
                }
            }
            first_seen
        };
        let (out, first_seen) = tokio::join!(run, watch);
        let finished = std::time::Instant::now();
        let out = out?;
        assert!(String::from_utf8_lossy(&out.stdout).contains("second"));
        let first_seen = first_seen.ok_or("no progress arrived")?;
        assert!(
            finished.duration_since(first_seen) >= Duration::from_millis(800),
            "the first line arrived only at the end"
        );
        Ok(())
    }

    #[tokio::test]
    async fn bounded_run_captures_output_and_kills_on_timeout() {
        let dir = std::env::temp_dir();
        let shell = preferred_shell();
        let ok = run_bounded(
            shell_command(shell, "echo bistre", &dir),
            Duration::from_secs(30),
        )
        .await;
        assert!(ok.is_ok());
        let out = ok.map(|o| String::from_utf8_lossy(&o.stdout).into_owned());
        assert!(out.is_ok_and(|s| s.contains("bistre")));

        let sleeper = if cfg!(windows) {
            "ping -n 30 127.0.0.1 > NUL"
        } else {
            "sleep 30"
        };
        let started = std::time::Instant::now();
        let timed_out = run_bounded(
            shell_command(shell, sleeper, &dir),
            Duration::from_millis(300),
        )
        .await;
        assert!(timed_out.is_err());
        assert!(started.elapsed() < Duration::from_secs(15));
    }

    #[test]
    fn windows_app_exec_alias_detection_rejects_store_shims() {
        assert!(is_windows_app_exec_alias(Path::new(
            r"C:\Users\alice\AppData\Local\Microsoft\WindowsApps\pwsh.exe"
        )));
        assert!(!is_windows_app_exec_alias(Path::new(
            r"C:\Program Files\PowerShell\7\pwsh.exe"
        )));
    }

    #[tokio::test]
    async fn timeout_kills_grandchildren_before_they_outlive_the_shell()
    -> Result<(), Box<dyn std::error::Error>> {
        let scratch = tempfile::tempdir()?;
        let marker = scratch.path().join("leaked.txt");
        let shell = preferred_shell();
        // The shell starts a grandchild that writes the marker ~3 s later unless the tree dies.
        let script = match shell {
            ShellKind::Pwsh => format!(
                "cmd /C \"ping -n 4 127.0.0.1 >NUL & echo leaked> {}\"",
                marker.display()
            ),
            ShellKind::Cmd => format!(
                "cmd /C ping -n 4 127.0.0.1 ^>NUL ^& echo leaked^> {}",
                marker.display()
            ),
            ShellKind::Sh => format!("sh -c 'sleep 3; echo leaked > {}'", marker.display()),
        };
        let timed_out = run_bounded(
            shell_command(shell, &script, scratch.path()),
            Duration::from_millis(1500),
        )
        .await;
        assert!(timed_out.is_err());
        tokio::time::sleep(Duration::from_secs(4)).await;
        assert!(
            !marker.exists(),
            "a grandchild outlived the timed-out shell"
        );
        Ok(())
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn spawned_children_join_the_kill_on_close_job() {
        let dir = std::env::temp_dir();
        let mut cmd = shell_command(preferred_shell(), "ping -n 30 127.0.0.1 > NUL", &dir);
        let spawned = spawn_contained(&mut cmd);
        assert!(spawned.is_ok());
        if let Ok((mut child, containment)) = spawned {
            let in_job = containment.holds(&child);
            assert!(containment.kill_tree());
            assert!(child.wait().await.is_ok());
            assert!(in_job);
        }
    }
}
