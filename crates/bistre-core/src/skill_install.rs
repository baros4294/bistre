//! Bistre's own skills, offered in every chat with tools on: `<data dir>/skills/<name>/SKILL.md`.
//! A skill is installed from a folder, a `SKILL.md` file, a zip, or a GitHub link, or saved
//! from a reply. Installing a skill whose name is taken replaces it; saving a reply never does.

use std::io::Read;
use std::path::{Component, Path, PathBuf};

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use bistre_storage::StorageHandle;
use uuid::Uuid;

use crate::skills::{self, SkillIndexEntry};

/// Most files one skill folder may hold.
pub const MAX_SKILL_FILES: usize = 200;
/// Most bytes one skill folder may hold.
pub const MAX_SKILL_BYTES: u64 = 8 * 1024 * 1024;
/// Largest zip (a file or a GitHub download) read for a skill.
pub const MAX_SKILL_ZIP_BYTES: usize = 32 * 1024 * 1024;
/// Longest skill folder name, in characters.
const MAX_SKILL_NAME_CHARS: usize = 64;
/// Longest description a saved reply gets, in characters.
const MAX_SAVED_DESCRIPTION_CHARS: usize = 200;
/// Most numbered names tried for a saved reply whose name is taken.
const MAX_NAME_SUFFIX: u32 = 99;

const SKILL_FILE: &str = "SKILL.md";

fn invalid(detail: &str) -> BistreError {
    BistreError::with_detail(DiagnosticKey::InvalidInput, detail)
}

fn io_err(detail: &str) -> impl Fn(std::io::Error) -> BistreError + '_ {
    move |err| {
        tracing::warn!(error = %err, detail, "skill file operation failed");
        BistreError::with_detail(DiagnosticKey::InternalError, detail)
    }
}

/// `<data dir>/skills`.
pub fn skills_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("skills")
}

/// Bistre's skills folder beside the database `storage` opened.
pub(crate) fn app_skills_dir(storage: &StorageHandle) -> Option<PathBuf> {
    storage.db_path().parent().map(skills_dir)
}

/// `roots` with Bistre's skills folder last, for `skill_load`.
pub(crate) fn with_app_skills(storage: &StorageHandle, mut roots: Vec<PathBuf>) -> Vec<PathBuf> {
    roots.extend(app_skills_dir(storage));
    roots
}

/// Whether Bistre's skills folder holds a skill (so `skill_load` is offered without a workspace).
pub(crate) fn has_app_skills(storage: &StorageHandle) -> bool {
    app_skills_dir(storage).is_some_and(|dir| {
        std::fs::read_dir(dir).is_ok_and(|entries| {
            entries
                .flatten()
                .any(|e| e.path().join(SKILL_FILE).is_file())
        })
    })
}

/// Bistre's installed skills, sorted by name.
pub fn list(data_dir: &Path) -> Vec<SkillIndexEntry> {
    skills::discover_skills_in(&skills_dir(data_dir))
}

/// A folder name from a skill name: lowercase letters, digits, and single hyphens.
fn slug(name: &str) -> BistreResult<String> {
    let mut out = String::new();
    for ch in name.trim().chars().flat_map(char::to_lowercase) {
        if ch.is_alphanumeric() {
            out.push(ch);
        } else if !out.is_empty() && !out.ends_with('-') {
            out.push('-');
        }
        if out.chars().count() >= MAX_SKILL_NAME_CHARS {
            break;
        }
    }
    let clean = out.trim_matches('-').to_owned();
    if clean.is_empty() {
        return Err(invalid("skill_name_empty"));
    }
    Ok(clean)
}

/// The files of one skill, relative to its folder, with `SKILL.md` among them.
struct SkillFiles {
    files: Vec<(PathBuf, Vec<u8>)>,
    total_bytes: u64,
}

impl SkillFiles {
    fn new() -> Self {
        Self {
            files: Vec::new(),
            total_bytes: 0,
        }
    }

    fn add(&mut self, rel: PathBuf, bytes: Vec<u8>) -> BistreResult<()> {
        let len = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
        self.total_bytes = self.total_bytes.saturating_add(len);
        if self.files.len() >= MAX_SKILL_FILES || self.total_bytes > MAX_SKILL_BYTES {
            return Err(invalid("skill_too_large"));
        }
        self.files.push((rel, bytes));
        Ok(())
    }

    fn skill_text(&self) -> BistreResult<String> {
        let (_, bytes) = self
            .files
            .iter()
            .find(|(rel, _)| rel.as_os_str() == SKILL_FILE)
            .ok_or_else(|| invalid("skill_file_missing"))?;
        String::from_utf8(bytes.clone()).map_err(|_| invalid("skill_file_not_text"))
    }
}

/// A relative path made only of plain parts (no `..`, root, or drive), else `None`.
fn plain_relative(path: &Path) -> Option<PathBuf> {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::Normal(p) => out.push(p),
            Component::CurDir => {}
            _ => return None,
        }
    }
    (!out.as_os_str().is_empty()).then_some(out)
}

/// Writes `files` as the skill named in its `SKILL.md` (else `fallback_name`). The folder is
/// written beside the old one and swapped in by rename, so a failed write leaves the old skill.
fn write_skill(
    data_dir: &Path,
    files: &SkillFiles,
    fallback_name: &str,
    replace: bool,
) -> BistreResult<SkillIndexEntry> {
    let text = files.skill_text()?;
    let (name, _) = skills::parse_skill_frontmatter(&text, fallback_name);
    let base = slug(&name)?;
    let root = skills_dir(data_dir);
    std::fs::create_dir_all(&root).map_err(io_err("skills_dir"))?;
    let folder = if replace {
        base
    } else {
        (1..=MAX_NAME_SUFFIX)
            .map(|n| {
                if n == 1 {
                    base.clone()
                } else {
                    format!("{base}-{n}")
                }
            })
            .find(|f| !root.join(f).exists())
            .ok_or_else(|| invalid("skill_name_taken"))?
    };
    let staging = root.join(format!(".tmp-{}", Uuid::now_v7()));
    let staged = (|| -> std::io::Result<()> {
        for (rel, bytes) in &files.files {
            let dest = staging.join(rel);
            if let Some(parent) = dest.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(dest, bytes)?;
        }
        Ok(())
    })();
    if let Err(err) = staged {
        if let Err(clean) = std::fs::remove_dir_all(&staging) {
            tracing::warn!(error = %clean, "staged skill not removed");
        }
        return Err(io_err("skill_write")(err));
    }
    let dest = root.join(&folder);
    let old = root.join(format!(".old-{}", Uuid::now_v7()));
    let had_old = dest.exists();
    if had_old {
        std::fs::rename(&dest, &old).map_err(io_err("skill_swap"))?;
    }
    if let Err(err) = std::fs::rename(&staging, &dest) {
        if had_old && let Err(back) = std::fs::rename(&old, &dest) {
            tracing::warn!(error = %back, "old skill not restored");
        }
        return Err(io_err("skill_swap")(err));
    }
    if had_old && let Err(err) = std::fs::remove_dir_all(&old) {
        tracing::warn!(error = %err, "replaced skill not removed");
    }
    let (name, description) = skills::parse_skill_frontmatter(&text, &folder);
    Ok(SkillIndexEntry {
        name,
        description,
        path: dest.join(SKILL_FILE).display().to_string(),
    })
}

/// Every file under `dir` (symlinks and `.git` skipped), within the skill bounds.
fn read_folder(dir: &Path) -> BistreResult<SkillFiles> {
    let mut files = SkillFiles::new();
    let mut pending = vec![PathBuf::new()];
    while let Some(rel) = pending.pop() {
        let entries = std::fs::read_dir(dir.join(&rel)).map_err(io_err("skill_folder_read"))?;
        for entry in entries {
            let entry = entry.map_err(io_err("skill_folder_read"))?;
            let kind = entry.file_type().map_err(io_err("skill_folder_read"))?;
            let name = entry.file_name();
            if kind.is_symlink() || name == ".git" {
                continue;
            }
            let child = rel.join(&name);
            if kind.is_dir() {
                if pending.len() + files.files.len() >= MAX_SKILL_FILES {
                    return Err(invalid("skill_too_large"));
                }
                pending.push(child);
            } else if kind.is_file() {
                let len = entry.metadata().map_err(io_err("skill_folder_read"))?.len();
                if len > MAX_SKILL_BYTES {
                    return Err(invalid("skill_too_large"));
                }
                let bytes = std::fs::read(entry.path()).map_err(io_err("skill_folder_read"))?;
                files.add(child, bytes)?;
            }
        }
    }
    Ok(files)
}

/// The skill inside a zip: the folder holding the `SKILL.md` closest to the top, or, with
/// `subdir`, the folder at that path under the zip's single top folder (a GitHub download).
fn read_zip(bytes: &[u8], subdir: Option<&Path>) -> BistreResult<SkillFiles> {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes))
        .map_err(|_| invalid("skill_zip_unreadable"))?;
    let mut names: Vec<PathBuf> = Vec::new();
    for i in 0..archive.len() {
        let entry = archive
            .by_index(i)
            .map_err(|_| invalid("skill_zip_unreadable"))?;
        if entry.is_file()
            && let Some(path) = entry.enclosed_name()
        {
            names.push(path);
        }
    }
    let root: PathBuf = match subdir {
        Some(sub) => {
            let top = names
                .first()
                .and_then(|p| p.components().next())
                .ok_or_else(|| invalid("skill_file_missing"))?;
            PathBuf::from(top.as_os_str()).join(sub)
        }
        None => names
            .iter()
            .filter(|p| p.file_name().is_some_and(|n| n == SKILL_FILE))
            .min_by_key(|p| p.components().count())
            .and_then(|p| p.parent().map(Path::to_path_buf))
            .ok_or_else(|| invalid("skill_file_missing"))?,
    };
    let mut files = SkillFiles::new();
    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|_| invalid("skill_zip_unreadable"))?;
        let Some(path) = entry.enclosed_name() else {
            continue;
        };
        let Some(rel) = path
            .strip_prefix(&root)
            .ok()
            .and_then(plain_relative)
            .filter(|r| r.components().all(|c| c.as_os_str() != ".git"))
        else {
            continue;
        };
        if !entry.is_file() {
            continue;
        }
        if entry.size() > MAX_SKILL_BYTES {
            return Err(invalid("skill_too_large"));
        }
        let mut buf = Vec::new();
        entry
            .by_ref()
            .take(MAX_SKILL_BYTES + 1)
            .read_to_end(&mut buf)
            .map_err(|_| invalid("skill_zip_unreadable"))?;
        files.add(rel, buf)?;
    }
    Ok(files)
}

/// Installs the skill at `source`: a folder with `SKILL.md`, a `SKILL.md` file, or a zip.
pub fn install_from_path(data_dir: &Path, source: &Path) -> BistreResult<SkillIndexEntry> {
    let meta = std::fs::metadata(source).map_err(io_err("skill_source_read"))?;
    let fallback = source
        .file_stem()
        .map_or_default(|s| s.to_string_lossy().into_owned());
    if meta.is_dir() {
        return write_skill(data_dir, &read_folder(source)?, &fallback, true);
    }
    let is_named = |want: &str| {
        source
            .file_name()
            .is_some_and(|n| n.to_string_lossy().eq_ignore_ascii_case(want))
    };
    let is_zip = source
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("zip"));
    if is_named(SKILL_FILE) {
        if meta.len() > MAX_SKILL_BYTES {
            return Err(invalid("skill_too_large"));
        }
        let mut files = SkillFiles::new();
        files.add(
            PathBuf::from(SKILL_FILE),
            std::fs::read(source).map_err(io_err("skill_source_read"))?,
        )?;
        let parent = source
            .parent()
            .and_then(Path::file_name)
            .map_or_default(|n| n.to_string_lossy().into_owned());
        return write_skill(data_dir, &files, &parent, true);
    }
    if is_zip {
        if meta.len() > u64::try_from(MAX_SKILL_ZIP_BYTES).unwrap_or(u64::MAX) {
            return Err(invalid("skill_too_large"));
        }
        let bytes = std::fs::read(source).map_err(io_err("skill_source_read"))?;
        return write_skill(data_dir, &read_zip(&bytes, None)?, &fallback, true);
    }
    Err(invalid("skill_source_kind"))
}

/// A GitHub link to a repository, or to a folder or `SKILL.md` in it, as the archive URL to
/// download and the skill's folder inside the archive. `/tree/<ref>/…` and `/blob/<ref>/…`
/// links take the first part after `tree` or `blob` as the branch or tag.
pub(crate) fn github_archive(url: &str) -> BistreResult<(String, PathBuf)> {
    let rest = url
        .trim()
        .strip_prefix("https://github.com/")
        .ok_or_else(|| invalid("skill_url_not_github"))?;
    let rest = rest.split(['?', '#']).next().unwrap_or_default();
    let parts: Vec<&str> = rest.split('/').filter(|p| !p.is_empty()).collect();
    let valid = |p: &str| {
        p.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
            && p != ".."
            && p != "."
    };
    let (owner, repo) = match parts.as_slice() {
        [owner, repo, ..] if valid(owner) && valid(repo) => (*owner, repo.trim_end_matches(".git")),
        _ => return Err(invalid("skill_url_not_github")),
    };
    let (git_ref, path_parts) = match parts.get(2..) {
        Some([kind, git_ref, path @ ..]) if matches!(*kind, "tree" | "blob") => {
            (*git_ref, path.to_vec())
        }
        Some([]) | None => ("HEAD", Vec::new()),
        Some(_) => return Err(invalid("skill_url_not_github")),
    };
    if !valid(git_ref) || !path_parts.iter().all(|p| valid(p)) {
        return Err(invalid("skill_url_not_github"));
    }
    let mut sub: PathBuf = path_parts.iter().collect();
    if sub.file_name().is_some_and(|n| n == SKILL_FILE) {
        sub.pop();
    }
    Ok((
        format!("https://github.com/{owner}/{repo}/archive/{git_ref}.zip"),
        sub,
    ))
}

/// Downloads and installs the skill a GitHub link points at (through `PublicWebTransport`).
pub async fn install_from_github(
    web: &crate::ssrf::PublicWebTransport,
    data_dir: PathBuf,
    url: &str,
) -> BistreResult<SkillIndexEntry> {
    let (archive_url, sub) = github_archive(url)?;
    let fetched = web.get(&archive_url, MAX_SKILL_ZIP_BYTES).await?;
    if fetched.status != 200 {
        return Err(BistreError::with_detail(
            DiagnosticKey::ProviderRequestFailed,
            "skill_download",
        ));
    }
    if fetched.truncated {
        return Err(invalid("skill_too_large"));
    }
    let fallback = sub
        .file_name()
        .map_or_default(|n| n.to_string_lossy().into_owned());
    crate::off_worker::blocking(move || {
        let files = read_zip(&fetched.body, Some(&sub))?;
        write_skill(&data_dir, &files, &fallback, true)
    })
    .await
}

/// Saves `body` as a new skill named `name` (a free numbered name when it is taken), its
/// description the first line of `body`.
pub fn save_text_as_skill(
    data_dir: &Path,
    name: &str,
    body: &str,
) -> BistreResult<SkillIndexEntry> {
    let body = body.trim();
    if body.is_empty() {
        return Err(invalid("skill_body_empty"));
    }
    let one_line = |text: &str, max: usize| -> String {
        text.lines()
            .map(str::trim)
            .find(|l| !l.is_empty())
            .unwrap_or_default()
            .trim_start_matches('#')
            .trim()
            .chars()
            .take(max)
            .collect()
    };
    let name_line = one_line(name, MAX_SKILL_NAME_CHARS);
    let description = one_line(body, MAX_SAVED_DESCRIPTION_CHARS);
    let text = format!("---\nname: {name_line}\ndescription: {description}\n---\n\n{body}\n");
    let mut files = SkillFiles::new();
    files.add(PathBuf::from(SKILL_FILE), text.into_bytes())?;
    write_skill(data_dir, &files, &name_line, false)
}

/// Removes the installed skill whose `SKILL.md` is at `skill_path` (inside Bistre's folder).
pub fn remove(data_dir: &Path, skill_path: &Path) -> BistreResult<()> {
    let root = std::fs::canonicalize(skills_dir(data_dir)).map_err(io_err("skills_dir"))?;
    let file = std::fs::canonicalize(skill_path).map_err(io_err("skill_not_found"))?;
    let folder = file
        .parent()
        .filter(|f| f.parent() == Some(root.as_path()))
        .filter(|_| file.file_name().is_some_and(|n| n == SKILL_FILE))
        .ok_or_else(|| BistreError::with_detail(DiagnosticKey::ToolPathDenied, "skill_outside"))?;
    std::fs::remove_dir_all(folder).map_err(io_err("skill_remove"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::tempdir;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    fn zip_of(entries: &[(&str, &str)]) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
        let mut out = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
        for (name, text) in entries {
            out.start_file(*name, zip::write::SimpleFileOptions::default())?;
            out.write_all(text.as_bytes())?;
        }
        Ok(out.finish()?.into_inner())
    }

    /// A folder, a zip, and a replaced install all land as one skill folder named by the
    /// skill, with the files beside `SKILL.md`.
    #[test]
    fn a_folder_or_zip_installs_and_a_reinstall_replaces() -> TestResult {
        let data = tempdir()?;
        let src = tempdir()?;
        let skill = src.path().join("review");
        std::fs::create_dir_all(skill.join("refs"))?;
        std::fs::write(
            skill.join(SKILL_FILE),
            "---\nname: Code Review\ndescription: d\n---\nv1",
        )?;
        std::fs::write(skill.join("refs").join("a.md"), "ref")?;
        let first = install_from_path(data.path(), &skill)?;
        assert_eq!(first.name, "Code Review");
        let folder = skills_dir(data.path()).join("code-review");
        assert!(folder.join("refs").join("a.md").is_file());

        let zip_path = src.path().join("pack.zip");
        std::fs::write(
            &zip_path,
            zip_of(&[
                ("pack/x/SKILL.md", "---\nname: code review\n---\nv2"),
                ("pack/x/notes.txt", "n"),
                ("pack/readme.md", "outside"),
            ])?,
        )?;
        install_from_path(data.path(), &zip_path)?;
        assert_eq!(
            std::fs::read_to_string(folder.join(SKILL_FILE))?,
            "---\nname: code review\n---\nv2"
        );
        assert!(folder.join("notes.txt").is_file());
        assert!(
            !folder.join("refs").exists(),
            "a reinstall replaces the old files"
        );
        assert!(!folder.join("readme.md").exists());
        assert_eq!(list(data.path()).len(), 1);

        remove(data.path(), Path::new(&list(data.path())[0].path))?;
        assert_eq!(list(data.path()), Vec::<SkillIndexEntry>::new());
        Ok(())
    }

    /// A zip entry that climbs out of its folder is never written, and a zip without a
    /// `SKILL.md` installs nothing.
    #[test]
    fn a_zip_never_writes_outside_its_skill() -> TestResult {
        let data = tempdir()?;
        let bytes = zip_of(&[
            ("s/SKILL.md", "---\nname: s\n---\nb"),
            ("s/../../evil.txt", "x"),
        ])?;
        let files = read_zip(&bytes, None)?;
        assert!(
            files
                .files
                .iter()
                .all(|(rel, _)| !rel.to_string_lossy().contains("evil"))
        );
        assert!(read_zip(&zip_of(&[("a/readme.md", "x")])?, None).is_err());
        assert_eq!(list(data.path()), Vec::<SkillIndexEntry>::new());
        Ok(())
    }

    #[test]
    fn github_links_map_to_their_archive_and_folder() -> TestResult {
        assert_eq!(
            github_archive("https://github.com/o/r")?,
            (
                "https://github.com/o/r/archive/HEAD.zip".to_owned(),
                PathBuf::new()
            )
        );
        assert_eq!(
            github_archive("https://github.com/o/r/tree/main/skills/pdf")?,
            (
                "https://github.com/o/r/archive/main.zip".to_owned(),
                PathBuf::from("skills").join("pdf")
            )
        );
        assert_eq!(
            github_archive("https://github.com/o/r/blob/v1/skills/pdf/SKILL.md")?.1,
            PathBuf::from("skills").join("pdf")
        );
        assert!(github_archive("https://example.com/o/r").is_err());
        assert!(github_archive("https://github.com/o/r/tree/main/../x").is_err());
        Ok(())
    }

    /// A saved reply becomes a skill named by its chat, described by its first line, and a
    /// second save under the same name gets a numbered folder.
    #[test]
    fn a_saved_reply_never_replaces_a_skill() -> TestResult {
        let data = tempdir()?;
        let first = save_text_as_skill(data.path(), "Trip plan", "# Steps\nBook early.")?;
        assert_eq!(first.name, "Trip plan");
        assert_eq!(first.description, "Steps");
        save_text_as_skill(data.path(), "Trip plan", "Other")?;
        assert!(
            skills_dir(data.path())
                .join("trip-plan-2")
                .join(SKILL_FILE)
                .is_file()
        );
        assert!(save_text_as_skill(data.path(), "x", "  ").is_err());
        Ok(())
    }
}
