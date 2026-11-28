//! Linux desktop helpers: the folder picker (`zenity` / `kdialog`), notifications
//! (`notify-send`), files and pictures on the clipboard (`wl-paste` / `xclip`), and opening a
//! folder, a file, or a web page (`xdg-open`). Each runs through the same containment as
//! every other child (`no_window_command` + `run_bounded`: process group, parent-death signal,
//! whole-tree kill on timeout), with arguments built here so text from a chat is never read as
//! an option.

use std::path::Path;
use std::time::Duration;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};

use crate::process_util::{find_on_path, no_window_command, run_bounded};

/// The folder picker waits for the user, but never forever.
pub const PICKER_TIMEOUT: Duration = Duration::from_secs(600);
/// Notifications and `xdg-open` hand off to a desktop service and return at once.
pub const HANDOFF_TIMEOUT: Duration = Duration::from_secs(15);
/// Longest notification title or body passed on (in characters).
pub const MAX_NOTIFICATION_CHARS: usize = 512;

/// The folder pickers tried in order, with their arguments.
#[must_use]
pub fn folder_picker_commands(title: &str) -> [(&'static str, Vec<String>); 2] {
    let title = clip(title);
    [
        (
            "zenity",
            vec![
                "--file-selection".to_owned(),
                "--directory".to_owned(),
                format!("--title={title}"),
            ],
        ),
        (
            "kdialog",
            vec![
                "--title".to_owned(),
                title,
                "--getexistingdirectory".to_owned(),
                ".".to_owned(),
            ],
        ),
    ]
}

/// `notify-send` arguments; `--` ends the options, so a title or body that starts with `-` is
/// shown as text.
#[must_use]
pub fn notification_args(title: &str, body: &str, play_sound: bool) -> Vec<String> {
    let mut args = vec!["--app-name=Bistre".to_owned()];
    if play_sound {
        // The desktop's own message sound, where the notification daemon plays one.
        args.push("--hint".to_owned());
        args.push("string:sound-name:message-new-instant".to_owned());
    }
    args.push("--".to_owned());
    args.push(clip(title));
    args.push(clip(body));
    args
}

fn clip(text: &str) -> String {
    text.chars()
        .filter(|c| !c.is_control() || *c == '\n')
        .take(MAX_NOTIFICATION_CHARS)
        .collect()
}

/// Asks the desktop for a folder. `Ok(None)` when the user cancels or no picker is installed
/// (the caller then offers to type the path).
pub async fn pick_folder(title: &str) -> BistreResult<Option<String>> {
    for (program, args) in folder_picker_commands(title) {
        if find_on_path(program).is_none() {
            continue;
        }
        let mut cmd = no_window_command(program);
        cmd.args(&args);
        let out = run_bounded(cmd, PICKER_TIMEOUT).await?;
        if !out.status.success() {
            return Ok(None);
        }
        let chosen = String::from_utf8(out.stdout).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InvalidInput, "picked_path_not_utf8")
        })?;
        let chosen = chosen.trim_end_matches(['\r', '\n']);
        return Ok((!chosen.is_empty()).then(|| chosen.to_owned()));
    }
    tracing::info!("no folder picker (zenity or kdialog) on PATH");
    Ok(None)
}

/// Shows a desktop notification through `notify-send`.
pub async fn notify(title: &str, body: &str, play_sound: bool) -> BistreResult<()> {
    let mut cmd = no_window_command("notify-send");
    cmd.args(notification_args(title, body, play_sound));
    finished_ok(
        &run_bounded(cmd, HANDOFF_TIMEOUT).await?,
        "notify_send_failed",
    )
}

/// Opens an existing local folder in the file manager through `xdg-open`.
pub async fn open_folder(path: &str) -> BistreResult<()> {
    let dir = Path::new(path);
    if !dir.is_absolute() || !dir.is_dir() {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "open_folder_not_a_directory",
        ));
    }
    let mut cmd = no_window_command("xdg-open");
    cmd.arg(dir);
    finished_ok(&run_bounded(cmd, HANDOFF_TIMEOUT).await?, "xdg_open_failed")
}

/// Opens an existing local file in its default app through `xdg-open`; executables, scripts,
/// shortcuts, and network paths are refused (`process_util::is_blocked_open_path`).
pub async fn open_file(path: &str) -> BistreResult<()> {
    let file = checked_open_file(path)?;
    let mut cmd = no_window_command("xdg-open");
    cmd.arg(file);
    finished_ok(&run_bounded(cmd, HANDOFF_TIMEOUT).await?, "xdg_open_failed")
}

/// Opens a web page in the default browser through `xdg-open`.
pub async fn open_web_link(url: &str) -> BistreResult<()> {
    let link = checked_web_link(url)?;
    let mut cmd = no_window_command("xdg-open");
    cmd.arg(link.as_str());
    finished_ok(&run_bounded(cmd, HANDOFF_TIMEOUT).await?, "xdg_open_failed")
}

/// Only an `http` or `https` URL with a host and no user name or password opens: any other
/// scheme would hand `xdg-open` a local file or another app's handler.
fn checked_web_link(url: &str) -> BistreResult<reqwest::Url> {
    let refused = || BistreError::with_detail(DiagnosticKey::InvalidInput, "open_web_link_refused");
    let link = reqwest::Url::parse(url.trim()).map_err(|_| refused())?;
    let has_host = link.host_str().is_some_and(|h| !h.is_empty());
    let has_login = !link.username().is_empty() || link.password().is_some();
    if matches!(link.scheme(), "http" | "https") && has_host && !has_login {
        Ok(link)
    } else {
        Err(refused())
    }
}

fn checked_open_file(path: &str) -> BistreResult<&Path> {
    let file = Path::new(path);
    if crate::process_util::is_blocked_open_path(path) || !file.is_absolute() || !file.is_file() {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "open_file_refused",
        ));
    }
    Ok(file)
}

fn finished_ok(out: &std::process::Output, detail: &'static str) -> BistreResult<()> {
    if out.status.success() {
        Ok(())
    } else {
        Err(BistreError::with_detail(
            DiagnosticKey::InternalError,
            detail,
        ))
    }
}

/// The clipboard tool answers at once; a stuck one is killed.
pub const CLIPBOARD_TIMEOUT: Duration = Duration::from_secs(10);
/// Most copied files one paste takes.
pub const MAX_PASTED_FILES: usize = 16;

/// The files or the picture (PNG, at most `MAX_CAPTURE_BYTES`) the clipboard holds.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct ClipboardAttachments {
    pub files: Vec<String>,
    pub png: Option<Vec<u8>>,
}

/// The clipboard reader and its arguments for `mime` (`None` lists the types): `wl-paste`
/// on Wayland, else `xclip`.
#[must_use]
pub fn clipboard_command(wayland: bool, mime: Option<&str>) -> (&'static str, Vec<String>) {
    let owned = |v: &[&str]| v.iter().map(|a| (*a).to_owned()).collect::<Vec<_>>();
    match (wayland, mime) {
        (true, None) => ("wl-paste", owned(&["--list-types"])),
        (true, Some(m)) => ("wl-paste", owned(&["--no-newline", "--type", m])),
        (false, None) => (
            "xclip",
            owned(&["-selection", "clipboard", "-o", "-t", "TARGETS"]),
        ),
        (false, Some(m)) => ("xclip", owned(&["-selection", "clipboard", "-o", "-t", m])),
    }
}

/// The local files a `text/uri-list` names (`file://` URIs, percent-decoded), at most
/// `MAX_PASTED_FILES`; other schemes, comments, and paths that are not files are skipped.
#[must_use]
pub fn uri_list_files(list: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in list.lines().map(str::trim) {
        if out.len() >= MAX_PASTED_FILES {
            break;
        }
        let Some(rest) = line.strip_prefix("file://") else {
            continue;
        };
        // `file://host/path`: only the local host (empty or `localhost`).
        let path = rest.strip_prefix("localhost").unwrap_or(rest);
        if !path.starts_with('/') {
            continue;
        }
        let Some(decoded) = percent_decode(path) else {
            continue;
        };
        if Path::new(&decoded).is_file() {
            out.push(decoded);
        }
    }
    out
}

fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = text.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// Reads one clipboard type; `None` when the tool reports nothing of that type.
async fn read_clipboard(wayland: bool, mime: Option<&str>) -> BistreResult<Option<Vec<u8>>> {
    let (program, args) = clipboard_command(wayland, mime);
    let mut cmd = no_window_command(program);
    cmd.args(&args);
    let out = run_bounded(cmd, CLIPBOARD_TIMEOUT).await?;
    Ok(out.status.success().then_some(out.stdout))
}

/// What the Linux clipboard holds as files or a picture. Text stays with Flutter's own
/// clipboard; no clipboard tool installed means none (logged).
pub async fn clipboard_attachments() -> BistreResult<ClipboardAttachments> {
    let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
    let (program, _) = clipboard_command(wayland, None);
    if find_on_path(program).is_none() {
        tracing::info!(
            program,
            "no clipboard tool on PATH; pasted files are not read"
        );
        return Ok(ClipboardAttachments::default());
    }
    let Some(types) = read_clipboard(wayland, None).await? else {
        return Ok(ClipboardAttachments::default());
    };
    let types = String::from_utf8_lossy(&types);
    let has = |mime: &str| types.lines().any(|t| t.trim() == mime);
    if has("text/uri-list")
        && let Some(list) = read_clipboard(wayland, Some("text/uri-list")).await?
    {
        let files = uri_list_files(&String::from_utf8_lossy(&list));
        if !files.is_empty() {
            return Ok(ClipboardAttachments { files, png: None });
        }
    }
    if has("image/png") {
        let png = read_clipboard(wayland, Some("image/png"))
            .await?
            .filter(|b| !b.is_empty());
        return Ok(ClipboardAttachments {
            files: Vec::new(),
            png,
        });
    }
    Ok(ClipboardAttachments::default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_uri_list_gives_its_local_files_only() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let file = dir.path().join("a b.png");
        std::fs::write(&file, b"x")?;
        let uri = format!("file://{}", file.to_string_lossy().replace(' ', "%20"));
        let list = format!(
            "# comment
{uri}
https://example.com/x.png
file://other-host/etc/passwd
"
        );
        let files = uri_list_files(&list);
        if cfg!(windows) {
            // Windows paths are not `/`-rooted, so no Linux URI resolves there.
            assert_eq!(files, Vec::<String>::new());
        } else {
            assert_eq!(files, [file.to_string_lossy().into_owned()]);
        }
        assert_eq!(
            uri_list_files("file:///no/such/bistre/file"),
            Vec::<String>::new()
        );
        Ok(())
    }

    #[test]
    fn the_clipboard_type_is_one_argument() {
        let (wl, args) = clipboard_command(true, Some("image/png"));
        assert_eq!(wl, "wl-paste");
        assert_eq!(args.last().map(String::as_str), Some("image/png"));
        let (x, targets) = clipboard_command(false, None);
        assert_eq!(x, "xclip");
        assert_eq!(targets.last().map(String::as_str), Some("TARGETS"));
    }

    #[test]
    fn only_a_plain_local_file_is_handed_to_the_default_app()
    -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let note = dir.path().join("note.txt");
        let script = dir.path().join("run.sh");
        for f in [&note, &script] {
            std::fs::write(f, b"x")?;
        }
        let text = |p: &Path| p.to_string_lossy().into_owned();
        assert!(checked_open_file(&text(&note)).is_ok());
        for refused in [
            text(&script),
            text(dir.path()),
            "note.txt".to_owned(),
            r"\\server\share\note.txt".to_owned(),
        ] {
            assert!(checked_open_file(&refused).is_err(), "{refused}");
        }
        Ok(())
    }

    #[test]
    fn notification_text_is_never_read_as_an_option() {
        let args = notification_args("--help", "-u critical\u{7}", true);
        let dashes = args.iter().position(|a| a == "--");
        assert_eq!(dashes, Some(args.len() - 3), "{args:?}");
        assert_eq!(args[args.len() - 2], "--help");
        assert_eq!(
            args[args.len() - 1],
            "-u critical",
            "control characters dropped"
        );
        assert!(args.contains(&"string:sound-name:message-new-instant".to_owned()));
        assert!(!notification_args("a", "b", false).contains(&"--hint".to_owned()));
    }

    #[test]
    fn long_text_is_cut_by_characters() {
        let body = "é".repeat(MAX_NOTIFICATION_CHARS + 50);
        let args = notification_args("t", &body, false);
        assert_eq!(
            args.last().map(|b| b.chars().count()),
            Some(MAX_NOTIFICATION_CHARS)
        );
    }

    #[test]
    fn picker_titles_stay_one_argument() {
        let [(zenity, z), (kdialog, k)] = folder_picker_commands("Choose --directory");
        assert_eq!((zenity, kdialog), ("zenity", "kdialog"));
        assert_eq!(
            z.last().map(String::as_str),
            Some("--title=Choose --directory")
        );
        assert_eq!(k[1], "Choose --directory");
    }

    #[test]
    fn only_a_web_page_link_opens() {
        for good in [
            "https://example.com/a?b=1#c",
            "http://example.org",
            " https://example.com ",
        ] {
            assert!(checked_web_link(good).is_ok(), "{good}");
        }
        for bad in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "ftp://example.com",
            "https://user:pass@example.com",
            "https://user@example.com",
            "/home/user/page.html",
            "example.com",
            "",
        ] {
            assert_eq!(
                checked_web_link(bad).err().map(|e| e.key),
                Some(DiagnosticKey::InvalidInput),
                "{bad}"
            );
        }
    }

    #[tokio::test]
    async fn only_an_existing_absolute_folder_opens() {
        for bad in ["relative/dir", "/definitely/not/a/bistre/dir"] {
            assert_eq!(
                open_folder(bad).await.err().map(|e| e.key),
                Some(DiagnosticKey::InvalidInput),
                "{bad}"
            );
        }
    }
}
