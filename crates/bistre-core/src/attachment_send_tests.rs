//! Attachments are typed by their bytes, never silently dropped, Office files
//! go to Gemini as text, and a request with uploaded files uses the uploading key.

use bistre_protocol::{NodeRecord, NodeRole, StoredAttachment};
use serde_json::{Value, json};

use crate::attachments::{infer_mime_type, unsent_attachment_names};

#[test]
fn unknown_extensions_are_typed_by_their_bytes() {
    let zip = b"PK\x03\x04\x14\x00rest";
    assert_eq!(infer_mime_type("backup", "", zip), "application/zip");
    let mut heic = vec![0, 0, 0, 24];
    heic.extend_from_slice(b"ftypheic\x00\x00\x00\x00mif1heic");
    assert_eq!(infer_mime_type("IMG_0001", "", &heic), "image/heic");
    assert_eq!(infer_mime_type("photo.heic", "", b""), "image/heic");
    assert_eq!(infer_mime_type("notes", "", b"plain words\n"), "text/plain");
    assert_eq!(
        infer_mime_type("blob", "", b"\x00\x01\x02\xff"),
        "application/octet-stream",
        "binary is never sent as text"
    );
    assert_eq!(
        infer_mime_type("a.png", "", b"\x89PNG\r\n\x1a\n"),
        "image/png"
    );
}

fn att(name: &str, mime: &str) -> StoredAttachment {
    StoredAttachment {
        id: "a1".to_owned(),
        name: name.to_owned(),
        mime_type: mime.to_owned(),
        blob_rel_path: "attachments/missing.png".to_owned(),
        size_bytes: 10,
        blake3_hex: "missing".to_owned(),
    }
}

fn history_with(attachment: &StoredAttachment) -> Vec<NodeRecord> {
    vec![NodeRecord {
        id: "u".to_owned(),
        thread_id: "t".to_owned(),
        parent_id: None,
        role: NodeRole::User,
        content: "look".to_owned(),
        provider_meta_json: Some(json!({ "attachments": [attachment] }).to_string()),
        created_at_ms: 1,
    }]
}

/// A missing blob becomes a visible note to the model in every dialect (and the run is
/// told, see `unsent_attachment_names`), never a silent drop.
#[test]
fn a_missing_attachment_is_never_silently_dropped() -> Result<(), Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let attachment = att("chart.png", "image/png");
    let history = history_with(&attachment);
    let refs = std::collections::HashMap::<String, String>::new();
    let bodies = [
        Value::Array(crate::wire_history::build_anthropic_messages_with_ctx(
            &history,
            Some(dir.path()),
            None,
        )),
        Value::Array(crate::wire_history::build_openai_responses_input_with_ctx(
            &history,
            Some(dir.path()),
            None,
        )),
        Value::Array(
            crate::wire_history::build_gemini_generate_contents_with_ctx(
                &history,
                Some(dir.path()),
                &refs,
                None,
            ),
        ),
        Value::Array(
            crate::wire_history::build_gemini_interactions_input_with_ctx(
                &history,
                Some(dir.path()),
                &refs,
                None,
                0,
            ),
        ),
    ];
    for body in bodies {
        let text = body.to_string();
        assert!(
            text.contains("chart.png") && text.contains("could not be sent"),
            "{text}"
        );
    }
    assert_eq!(
        unsent_attachment_names(dir.path(), &history),
        vec!["chart.png".to_owned()]
    );
    Ok(())
}

/// Office files are never uploaded to Gemini's Files API (it rejects Office types); they
/// go as extracted text.
#[test]
fn office_files_go_to_gemini_as_text() {
    let docx = att(
        "plan.docx",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    );
    assert!(!crate::attachments::gemini_needs_files_api(&docx));
    assert!(crate::attachments::gemini_needs_files_api(&att(
        "a.pdf",
        "application/pdf"
    )));
}

/// A request that refers to uploaded files is sent with the key that uploaded them.
#[test]
fn a_request_with_uploaded_files_uses_the_uploading_key() {
    let ring = crate::credentials::KeyRing::from_vault_text("key-one\nkey-two");
    let pinned = ring.primary_only();
    for _ in 0..4 {
        assert_eq!(pinned.rotation(), vec!["key-one"]);
    }
}
