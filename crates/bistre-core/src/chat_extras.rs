//! Engine calls beside the chat runs: the files of a chat, Bistre's own skills, a drafted next
//! message, an assistant's opening message, every chat as a zip with its files, and a
//! character card saved as a PNG.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, NodeRole, ThreadMode, ThreadSummary,
};
use bistre_storage::StorageHandle;
use serde_json::Value;

use crate::attachments::{MAX_ATTACHMENT_BYTES, store_attachment_bytes};
use crate::off_worker::{blocking, off_worker};
use crate::skills::SkillIndexEntry;
use crate::utility::{UtilitySlot, clip_chars};
use crate::utility_chat::latest_transcript;
use crate::{BoxFuture, InProcessEngine, chat_files, skill_install, story};

/// `kv_meta` key prefix of an assistant's opening message (`<prefix><assistant id>`).
pub(crate) const GREETING_KEY_PREFIX: &str = "assistant_greeting:";
/// Longest opening message, in characters.
pub(crate) const MAX_GREETING_CHARS: usize = 8_000;
/// Longest note a drafted message follows, in characters.
const MAX_DRAFT_NOTE_CHARS: usize = 2_000;
/// Longest drafted message, in characters.
const MAX_DRAFT_CHARS: usize = 8_000;
/// Largest chats zip read, and most entries it may hold.
const MAX_CHATS_ZIP_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const MAX_CHATS_ZIP_ENTRIES: usize = 20_000;
/// Largest character picture read for a PNG card.
const MAX_CARD_PICTURE_BYTES: u64 = 16 * 1024 * 1024;
const CHATS_FILE: &str = "chats.json";

const DRAFT_MESSAGE_PROMPT: &str = "Write the user's next message in the conversation below, in the user's voice and language, as the user would send it. When the user left a note, the message does what the note says. Return only the message text.";

fn invalid(detail: &str) -> BistreError {
    BistreError::with_detail(DiagnosticKey::InvalidInput, detail)
}

fn io_err(detail: &'static str) -> impl Fn(std::io::Error) -> BistreError {
    move |err| {
        tracing::warn!(error = %err, detail, "file operation failed");
        BistreError::with_detail(DiagnosticKey::InternalError, detail)
    }
}

/// A new chat with an assistant that has an opening message starts with it as the first
/// reply (outside Write mode, where the character's greeting is chosen in the toolbar).
pub(crate) fn open_with_greeting(
    storage: &StorageHandle,
    thread: ThreadSummary,
) -> BistreResult<ThreadSummary> {
    if thread.mode == ThreadMode::Write || thread.assistant_id.is_empty() {
        return Ok(thread);
    }
    let key = format!("{GREETING_KEY_PREFIX}{}", thread.assistant_id);
    let Some(greeting) = storage.get_kv_meta(&key)?.filter(|g| !g.trim().is_empty()) else {
        return Ok(thread);
    };
    storage.append_node(
        thread.id.clone(),
        None,
        NodeRole::Assistant,
        clip_chars(greeting.trim(), MAX_GREETING_CHARS),
        Some(serde_json::json!({ "greeting": true }).to_string()),
    )?;
    storage
        .get_thread(&thread.id)?
        .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))
}

/// The blob paths of every file the archive's messages carry.
fn archive_blobs(archive: &Value) -> Vec<String> {
    let mut out = Vec::new();
    let threads = archive.get("threads").and_then(Value::as_array);
    for node in threads
        .into_iter()
        .flatten()
        .filter_map(|t| t.get("nodes").and_then(Value::as_array))
        .flatten()
    {
        let meta = node.get("provider_meta_json").and_then(Value::as_str);
        for att in crate::attachments::parse_node_attachments(meta) {
            if !out.contains(&att.blob_rel_path) {
                out.push(att.blob_rel_path);
            }
        }
    }
    out
}

/// Writes every chat (`chats.json`, the format chat import reads) and the files its messages
/// carry (`attachments/`) to a zip at `dest`, through a temporary file renamed into place.
/// Returns how many files went in; a file missing on disk is logged and left out.
pub(crate) fn export_chats_zip(
    storage: &StorageHandle,
    data_dir: &Path,
    dest: &Path,
) -> BistreResult<u32> {
    let json = crate::storage_files::export_all_threads_json(storage)?;
    let archive: Value = serde_json::from_str(&json).map_err(|_| invalid("export_json"))?;
    let tmp = dest.with_extension(format!("tmp-{}", uuid::Uuid::now_v7()));
    let written = (|| -> BistreResult<u32> {
        let file = std::fs::File::create(&tmp).map_err(io_err("zip_create"))?;
        let mut zip = zip::ZipWriter::new(file);
        let opts = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated)
            .large_file(true);
        zip.start_file(CHATS_FILE, opts)
            .map_err(|_| invalid("zip_write"))?;
        zip.write_all(json.as_bytes())
            .map_err(io_err("zip_write"))?;
        let mut count = 0_u32;
        for rel in archive_blobs(&archive) {
            let att = bistre_protocol::StoredAttachment {
                id: String::new(),
                name: String::new(),
                mime_type: String::new(),
                blob_rel_path: rel.clone(),
                size_bytes: 0,
                blake3_hex: String::new(),
            };
            let Some(path) = crate::attachments::resolve_blob_path(data_dir, &att) else {
                tracing::warn!("export: a file path outside attachments/ was left out");
                continue;
            };
            let mut src = match std::fs::File::open(&path) {
                Ok(f) => f,
                Err(err) => {
                    tracing::warn!(error = %err, "export: a chat file is gone; left out");
                    continue;
                }
            };
            zip.start_file(rel.replace('\\', "/"), opts)
                .map_err(|_| invalid("zip_write"))?;
            std::io::copy(&mut src, &mut zip).map_err(io_err("zip_write"))?;
            count = count.saturating_add(1);
        }
        zip.finish().map_err(|_| invalid("zip_write"))?;
        Ok(count)
    })();
    match written {
        Ok(count) => {
            std::fs::rename(&tmp, dest).map_err(io_err("zip_rename"))?;
            Ok(count)
        }
        Err(err) => {
            if let Err(clean) = std::fs::remove_file(&tmp) {
                tracing::warn!(error = %clean, "partial zip not removed");
            }
            Err(err)
        }
    }
}

/// Imports a zip from `export_chats_zip`: each file is checked against its content hash
/// (the name) before it is stored, then the chats are imported. Returns the chats imported.
pub(crate) fn import_chats_zip(
    storage: &StorageHandle,
    data_dir: &Path,
    src: &Path,
) -> BistreResult<u32> {
    let len = std::fs::metadata(src).map_err(io_err("zip_open"))?.len();
    if len > MAX_CHATS_ZIP_BYTES {
        return Err(invalid("import_too_large"));
    }
    let file = std::fs::File::open(src).map_err(io_err("zip_open"))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|_| invalid("zip_unreadable"))?;
    if zip.len() > MAX_CHATS_ZIP_ENTRIES {
        return Err(invalid("import_too_large"));
    }
    let mut chats: Option<String> = None;
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|_| invalid("zip_unreadable"))?;
        let Some(name) = entry.enclosed_name() else {
            continue;
        };
        let name = name.to_string_lossy().replace('\\', "/");
        if name == CHATS_FILE {
            let mut text = String::new();
            entry
                .by_ref()
                .take(32 * 1024 * 1024 + 1)
                .read_to_string(&mut text)
                .map_err(|_| invalid("zip_unreadable"))?;
            chats = Some(text);
            continue;
        }
        let Some(file_name) = name.strip_prefix("attachments/") else {
            continue;
        };
        let Some((hash, _)) = file_name.split_once('.') else {
            continue;
        };
        if entry.size() > MAX_ATTACHMENT_BYTES {
            return Err(invalid("attachment_too_large"));
        }
        let mut bytes = Vec::new();
        entry
            .by_ref()
            .take(MAX_ATTACHMENT_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| invalid("zip_unreadable"))?;
        if blake3::hash(&bytes).to_hex().as_str() != hash {
            return Err(invalid("zip_file_changed"));
        }
        store_attachment_bytes(
            data_dir,
            file_name.to_owned(),
            "application/octet-stream".to_owned(),
            &bytes,
        )?;
    }
    let chats = chats.ok_or_else(|| invalid("zip_without_chats"))?;
    crate::storage_files::import_threads_json(storage, &chats)
}

impl InProcessEngine {
    /// The open chat's files, newest first (`chat_files`).
    pub fn list_chat_files(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<chat_files::ChatFile>>> {
        Box::pin(off_worker(&self.storage, move |s| {
            chat_files::list(s, &thread_id)
        }))
    }

    /// Bistre's installed skills.
    pub fn list_app_skills(&self) -> BoxFuture<'_, BistreResult<Vec<SkillIndexEntry>>> {
        let dir = self.data_dir.clone();
        Box::pin(blocking(move || Ok(skill_install::list(&dir))))
    }

    /// Installs a skill from a GitHub link (`https://github.com/...`) or a local folder,
    /// `SKILL.md`, or zip path.
    pub fn install_skill(&self, source: String) -> BoxFuture<'_, BistreResult<SkillIndexEntry>> {
        let dir = self.data_dir.clone();
        Box::pin(async move {
            let source = source.trim().to_owned();
            if source.starts_with("https://") {
                return skill_install::install_from_github(&self.web, dir, &source).await;
            }
            blocking(move || skill_install::install_from_path(&dir, Path::new(&source))).await
        })
    }

    /// Saves a reply as a new skill named by its chat.
    pub fn save_reply_as_skill(
        &self,
        thread_id: String,
        node_id: String,
    ) -> BoxFuture<'_, BistreResult<SkillIndexEntry>> {
        let dir = self.data_dir.clone();
        Box::pin(off_worker(&self.storage, move |s| {
            let thread = s
                .get_thread(&thread_id)?
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
            let node = s
                .list_branch(&thread_id, &node_id)?
                .pop()
                .filter(|n| n.id == node_id && n.role == NodeRole::Assistant)
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
            skill_install::save_text_as_skill(&dir, &thread.title, &node.content)
        }))
    }

    /// Removes an installed skill by the path of its `SKILL.md`.
    pub fn remove_app_skill(&self, skill_path: String) -> BoxFuture<'_, BistreResult<()>> {
        let dir = self.data_dir.clone();
        Box::pin(blocking(move || {
            skill_install::remove(&dir, Path::new(&skill_path))
        }))
    }

    /// Drafts the user's next message (to edit before sending), following `note` when given.
    /// Nothing is saved to the chat; the spend is booked on it.
    pub fn draft_next_message(
        &self,
        thread_id: String,
        note: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            let note = note.trim();
            if note.chars().count() > MAX_DRAFT_NOTE_CHARS {
                return Err(invalid("draft_note_length"));
            }
            // A chat with no messages yet gets an opening message.
            let has_messages = self
                .storage
                .get_thread(&thread_id)?
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?
                .active_head_node_id
                .is_some();
            let history = if has_messages {
                self.active_history(&thread_id)?
            } else {
                Vec::new()
            };
            let mut prompt = latest_transcript(&history);
            if prompt.is_empty() {
                prompt.push_str("[The conversation has no messages yet]");
            }
            if let Some(persona) = self.chat_persona(&thread_id)? {
                prompt.push_str("\n\n[The user's persona]\n");
                prompt.push_str(persona.name.trim());
                if !persona.description.trim().is_empty() {
                    prompt.push_str(": ");
                    prompt.push_str(persona.description.trim());
                }
            }
            if !note.is_empty() {
                prompt.push_str("\n\n[The user's note for the message]\n");
                prompt.push_str(note);
            }
            let out = self
                .run_utility_completion(
                    UtilitySlot::SideQuestion,
                    Some(&thread_id),
                    DRAFT_MESSAGE_PROMPT,
                    &prompt,
                    2048,
                )
                .await?;
            if out.text.is_empty() {
                return Err(BistreError::with_detail(
                    DiagnosticKey::ProviderRequestFailed,
                    "empty_draft",
                ));
            }
            Ok(clip_chars(&out.text, MAX_DRAFT_CHARS))
        })
    }

    /// Writes every chat with its files to a zip at `dest_path`; returns the files written.
    pub fn export_chats_zip(&self, dest_path: String) -> BoxFuture<'_, BistreResult<u32>> {
        let dir = self.data_dir.clone();
        Box::pin(off_worker(&self.storage, move |s| {
            export_chats_zip(s, &dir, Path::new(&dest_path))
        }))
    }

    /// Imports the chats and files of a zip from `export_chats_zip`.
    pub fn import_chats_zip(&self, src_path: String) -> BoxFuture<'_, BistreResult<u32>> {
        let dir = self.data_dir.clone();
        Box::pin(off_worker(&self.storage, move |s| {
            import_chats_zip(s, &dir, Path::new(&src_path))
        }))
    }

    /// Saves a character card with its lore as a PNG card at `dest_path`, on its picture
    /// (a card without a PNG picture cannot be saved this way).
    pub fn export_character_card_png(
        &self,
        card_id: String,
        dest_path: String,
    ) -> BoxFuture<'_, BistreResult<()>> {
        let dir = self.data_dir.clone();
        Box::pin(off_worker(&self.storage, move |s| {
            let card = s
                .list_character_cards()?
                .into_iter()
                .find(|c| c.id == card_id)
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
            if card.avatar_path.trim().is_empty() {
                return Err(invalid("card_has_no_picture"));
            }
            let picture = PathBuf::from(&card.avatar_path);
            let picture = if picture.is_absolute() {
                picture
            } else {
                dir.join(picture)
            };
            let len = std::fs::metadata(&picture)
                .map_err(io_err("card_picture"))?
                .len();
            if len > MAX_CARD_PICTURE_BYTES {
                return Err(invalid("card_picture_too_large"));
            }
            let base = std::fs::read(&picture).map_err(io_err("card_picture"))?;
            let entries = s.list_story_entries(None)?;
            let png = story::card_io::export_card_png(&base, &card, &entries)?;
            let dest = Path::new(&dest_path);
            let (Some(dir), Some(name)) =
                (dest.parent(), dest.file_name().and_then(|n| n.to_str()))
            else {
                return Err(invalid("card_destination"));
            };
            crate::tool_spill::write_blob_atomically(dir, name, &png).map_err(io_err("card_write"))
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    /// Every chat and its files survive a zip round trip, and a file changed inside the zip
    /// stops the import before any chat is added.
    #[test]
    fn chats_and_their_files_round_trip_through_a_zip() -> TestResult {
        let src_dir = tempdir()?;
        let src = StorageHandle::open(src_dir.path().join("a.sqlite"))?;
        let att = store_attachment_bytes(
            src_dir.path(),
            "p.png".to_owned(),
            "image/png".to_owned(),
            b"png",
        )?;
        let t = src.create_thread(None, "Trip", ThreadMode::Chat, None, None)?;
        src.append_node(
            t.id,
            None,
            NodeRole::User,
            "see".to_owned(),
            Some(serde_json::json!({ "attachments": [att] }).to_string()),
        )?;
        let zip_path = src_dir.path().join("chats.zip");
        assert_eq!(export_chats_zip(&src, src_dir.path(), &zip_path)?, 1);

        let dest_dir = tempdir()?;
        let dest = StorageHandle::open(dest_dir.path().join("b.sqlite"))?;
        assert_eq!(import_chats_zip(&dest, dest_dir.path(), &zip_path)?, 1);
        let blob = dest_dir.path().join(&att.blob_rel_path);
        assert_eq!(std::fs::read(blob)?, b"png");
        let imported = dest.list_threads(None)?;
        assert_eq!(imported.len(), 1);
        let files = chat_files::list(&dest, &imported[0].id)?;
        assert_eq!(files.len(), 1);

        let bad = src_dir.path().join("bad.zip");
        let mut zip = zip::ZipWriter::new(std::fs::File::create(&bad)?);
        let opts = zip::write::SimpleFileOptions::default();
        zip.start_file(CHATS_FILE, opts)?;
        zip.write_all(crate::storage_files::export_all_threads_json(&src)?.as_bytes())?;
        zip.start_file(att.blob_rel_path.clone(), opts)?;
        zip.write_all(b"changed")?;
        zip.finish()?;
        let fresh = StorageHandle::open(dest_dir.path().join("c.sqlite"))?;
        assert!(import_chats_zip(&fresh, dest_dir.path(), &bad).is_err());
        assert_eq!(fresh.list_threads(None)?, Vec::<ThreadSummary>::new());
        Ok(())
    }

    /// An assistant's opening message starts its new chats outside Write mode.
    #[test]
    fn an_opening_message_starts_the_assistants_new_chats() -> TestResult {
        let dir = tempdir()?;
        let s = StorageHandle::open(dir.path().join("g.sqlite"))?;
        let assistant = s
            .list_assistants()?
            .into_iter()
            .next()
            .ok_or("no assistant")?;
        s.set_kv_meta(
            format!("{GREETING_KEY_PREFIX}{}", assistant.id),
            "Hello there".to_owned(),
        )?;
        let chat = s.create_thread(None, "c", ThreadMode::Chat, None, Some(&assistant.id))?;
        let opened = open_with_greeting(&s, chat)?;
        let nodes = s.list_nodes(&opened.id)?;
        assert_eq!(nodes.len(), 1);
        assert_eq!(nodes[0].role, NodeRole::Assistant);
        assert_eq!(
            opened.active_head_node_id.as_deref(),
            Some(nodes[0].id.as_str())
        );
        let story = s.create_thread(None, "w", ThreadMode::Write, None, Some(&assistant.id))?;
        assert_eq!(
            s.list_nodes(&open_with_greeting(&s, story)?.id)?,
            Vec::<bistre_protocol::NodeRecord>::new()
        );
        Ok(())
    }

    #[test]
    fn the_draft_prompt_follows_the_prompt_rules() {
        assert_eq!(
            crate::test_support::prompt_rule_breaks(DRAFT_MESSAGE_PROMPT),
            Vec::<String>::new()
        );
    }
}
