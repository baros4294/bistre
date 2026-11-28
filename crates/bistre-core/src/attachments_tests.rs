//! Unit tests for `attachments.rs`.

use super::*;
use serde_json::json;
use std::io::Write as _;

#[test]
fn extracts_docx_and_xlsx_text_without_mcp() -> Result<(), Box<dyn std::error::Error>> {
    let mut docx_buf = Vec::new();
    {
        let mut zw = zip::ZipWriter::new(std::io::Cursor::new(&mut docx_buf));
        let opts = zip::write::SimpleFileOptions::default();
        zw.start_file("word/document.xml", opts)?;
        zw.write_all(
            br"<w:document><w:body><w:p><w:r><w:t>Hello &amp; welcome</w:t></w:r></w:p><w:p><w:r><w:t>Second line</w:t></w:r></w:p></w:body></w:document>",
        )?;
        zw.finish()?;
    }
    let docx_text = extract_office_text(&docx_buf, "docx").ok_or("docx extract failed")?;
    assert!(docx_text.contains("Hello & welcome"));
    assert!(docx_text.contains("Second line"));

    let mut xlsx_buf = Vec::new();
    {
        let mut zw = zip::ZipWriter::new(std::io::Cursor::new(&mut xlsx_buf));
        let opts = zip::write::SimpleFileOptions::default();
        zw.start_file("xl/sharedStrings.xml", opts)?;
        zw.write_all(br"<sst><si><t>Quarter</t></si><si><t>Revenue</t></si></sst>")?;
        zw.start_file("xl/worksheets/sheet1.xml", opts)?;
        zw.write_all(
            br#"<worksheet><sheetData><row><c t="s"><v>0</v></c><c t="s"><v>1</v></c></row><row><c><v>1</v></c><c><v>4200</v></c></row></sheetData></worksheet>"#,
        )?;
        zw.finish()?;
    }
    let xlsx_text = extract_office_text(&xlsx_buf, "xlsx").ok_or("xlsx extract failed")?;
    assert!(xlsx_text.contains("Quarter, Revenue"));
    assert!(xlsx_text.contains("1, 4200"));
    Ok(())
}

#[test]
fn encodes_multimodal_attachments_across_big_3() -> Result<(), Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let png_path = dir.path().join("sample.png");
    std::fs::write(&png_path, [137_u8, 80, 78, 71, 13, 10, 26, 10])?;
    let stored = ingest_attachment(
        dir.path(),
        &AttachmentInput {
            name: "sample.png".to_owned(),
            mime_type: String::new(),
            local_path: png_path.to_string_lossy().into_owned(),
        },
    )?;
    assert_eq!(stored.mime_type, "image/png");

    let node = bistre_protocol::NodeRecord {
        id: "n1".to_owned(),
        thread_id: "t1".to_owned(),
        parent_id: None,
        role: bistre_protocol::NodeRole::User,
        content: "Describe this".to_owned(),
        provider_meta_json: Some(json!({ "attachments": [stored] }).to_string()),
        created_at_ms: 0,
    };

    let oai = build_openai_responses_input(std::slice::from_ref(&node), Some(dir.path()));
    assert_eq!(oai[0]["content"][0]["type"], "input_image");

    let anth = build_anthropic_messages(std::slice::from_ref(&node), Some(dir.path()));
    assert_eq!(anth[0]["content"][0]["type"], "image");

    let gem = build_gemini_interactions_input(
        std::slice::from_ref(&node),
        Some(dir.path()),
        &HashMap::new(),
    );
    assert_eq!(gem[0]["content"][0]["type"], "image");
    Ok(())
}

#[test]
fn multi_key_remote_cache_is_isolated_and_evictable() -> Result<(), Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let k_a = remote_file_cache_key(
        bistre_protocol::ProviderDialect::GoogleGemini,
        "https://example.test",
        "key-alpha",
        "hash123",
    );
    let k_b = remote_file_cache_key(
        bistre_protocol::ProviderDialect::GoogleGemini,
        "https://example.test",
        "key-beta",
        "hash123",
    );
    assert_ne!(
        k_a, k_b,
        "different API keys must never share cached remote URIs"
    );

    store_remote_cache(
        dir.path(),
        k_a.clone(),
        "https://files/a".to_owned(),
        60_000,
    );
    assert_eq!(
        lookup_remote_cache(dir.path(), &k_a).as_deref(),
        Some("https://files/a")
    );
    assert_eq!(lookup_remote_cache(dir.path(), &k_b), None);

    evict_remote_file_cache(
        Some(dir.path()),
        bistre_protocol::ProviderDialect::GoogleGemini,
        "https://example.test",
        "key-alpha",
    );
    assert_eq!(lookup_remote_cache(dir.path(), &k_a), None);
    Ok(())
}

#[tokio::test]
async fn gemini_upload_polls_processing_until_active_and_openai_uploads_file_id()
-> Result<(), Box<dyn std::error::Error>> {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    let dir = tempfile::tempdir()?;
    let pdf_path = dir.path().join("doc.pdf");
    std::fs::write(&pdf_path, b"%PDF-1.7 test content")?;
    let stored = ingest_attachment(
        dir.path(),
        &AttachmentInput {
            name: "doc.pdf".to_owned(),
            mime_type: "application/pdf".to_owned(),
            local_path: pdf_path.to_string_lossy().into_owned(),
        },
    )?;

    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let polls = Arc::new(AtomicUsize::new(0));
    let polls_clone = Arc::clone(&polls);

    let srv = tokio::spawn(async move {
        for _ in 0..4 {
            let Ok((mut sock, _)) = listener.accept().await else {
                break;
            };
            let mut buf = vec![0_u8; 8192];
            let n = sock.read(&mut buf).await.unwrap_or(0);
            let req = String::from_utf8_lossy(&buf[..n]);
            let body = if req.starts_with("POST /upload/v1beta/files") {
                r#"{"file":{"name":"files/abc123","uri":"https://example.test/files/abc123","state":"PROCESSING"}}"#
                    .to_owned()
            } else if req.starts_with("GET /v1beta/files/abc123") {
                let count = polls_clone.fetch_add(1, Ordering::SeqCst);
                if count == 0 {
                    r#"{"name":"files/abc123","state":"PROCESSING"}"#.to_owned()
                } else {
                    r#"{"name":"files/abc123","state":"ACTIVE"}"#.to_owned()
                }
            } else if req.starts_with("POST /files") {
                r#"{"id":"file-openai-999"}"#.to_owned()
            } else {
                "{}".to_owned()
            };
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            if sock.write_all(resp.as_bytes()).await.is_err() {
                break;
            }
        }
    });

    let client = crate::providers::build_http_client()?;
    let base = format!("http://{addr}");
    let uri = gemini_upload_file(&client, &base, "gem-key", dir.path(), &stored).await;
    assert_eq!(uri.as_deref(), Some("https://example.test/files/abc123"));
    assert!(polls.load(Ordering::SeqCst) >= 2, "must poll until ACTIVE");

    let oai_id = upload_provider_file_api(
        &client,
        bistre_protocol::ProviderDialect::OpenAi,
        &base,
        "oai-key",
        dir.path(),
        &stored,
        false,
    )
    .await;
    assert_eq!(oai_id.as_deref(), Some("file-openai-999"));
    srv.abort();
    Ok(())
}
