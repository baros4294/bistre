//! Tool outputs larger than `TOOL_OUTPUT_SPILL_BYTES` (`64 KiB`) spill to
//! `<data_dir>/tool_blobs/` (atomic write, off the async workers) and the model gets a
//! `16 KiB` preview naming the blob (AGENTS section 7).

use std::path::Path;

use uuid::Uuid;

use crate::agent_tools::TOOL_OUTPUT_SPILL_BYTES;

/// [`spill_large_output`] on the blocking pool. Small outputs return inline at once.
pub(crate) async fn spill_off_worker(data_dir: &Path, call_id: &str, text: &str) -> String {
    if text.len() <= TOOL_OUTPUT_SPILL_BYTES {
        return text.to_owned();
    }
    let (dir, id, body) = (data_dir.to_path_buf(), call_id.to_owned(), text.to_owned());
    match crate::off_worker::blocking(move || Ok(spill_large_output(&dir, &id, &body))).await {
        Ok(spilled) => spilled,
        Err(err) => {
            tracing::warn!(key = err.key.as_key(), "tool output spill task failed");
            spill_preview(text, None)
        }
    }
}

/// Writes `bytes` to `dir/filename` atomically: a unique temp file, `sync_all`, then rename,
/// so a reader never sees a partial blob.
pub(crate) fn write_blob_atomically(
    dir: &Path,
    filename: &str,
    bytes: &[u8],
) -> std::io::Result<()> {
    use std::io::Write as _;
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".{filename}.{}.tmp", Uuid::now_v7().simple()));
    let written = std::fs::File::create(&tmp).and_then(|mut f| {
        f.write_all(bytes)?;
        f.sync_all()
    });
    let finished = written.and_then(|()| std::fs::rename(&tmp, dir.join(filename)));
    if finished.is_err()
        && let Err(err) = std::fs::remove_file(&tmp)
        && err.kind() != std::io::ErrorKind::NotFound
    {
        tracing::warn!(error = %err, "partial tool output blob not removed");
    }
    finished
}

/// Spills outputs larger than `TOOL_OUTPUT_SPILL_BYTES` (`64 KiB`) to `<data_dir>/tool_blobs/`
/// and returns a compact inline preview referencing the full blob path.
fn spill_large_output(data_dir: &Path, call_id: &str, text: &str) -> String {
    if text.len() <= TOOL_OUTPUT_SPILL_BYTES {
        return text.to_owned();
    }
    let dir = data_dir.join("tool_blobs");
    let safe_id: String = call_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .take(40)
        .collect();
    let filename = format!("{safe_id}-{}.txt", Uuid::now_v7().simple());
    let wrote = match write_blob_atomically(&dir, &filename, text.as_bytes()) {
        Ok(()) => true,
        Err(err) => {
            tracing::warn!(error = %err, "tool output blob not saved; keeping a truncated preview");
            false
        }
    };
    spill_preview(text, wrote.then_some(filename.as_str()))
}

/// The first `16 KiB` of `text` plus a footer naming the saved blob, or saying it was cut.
fn spill_preview(text: &str, saved_as: Option<&str>) -> String {
    let cut = text.floor_char_boundary(16 * 1024);
    let preview = &text[..cut];
    match saved_as {
        Some(filename) => format!(
            "{preview}\n\n[tool output spilled: {} bytes saved to tool_blobs/{filename}]",
            text.len()
        ),
        None => format!(
            "{preview}\n\n[tool output truncated at {} of {} bytes]",
            cut,
            text.len()
        ),
    }
}
