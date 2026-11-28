//! Plain text from Office documents (DOCX, XLSX, PPTX) read from their ZIP and XML parts (split out of `attachments.rs`).

use crate::attachments::{MAX_EXTRACTED_TEXT_BYTES, MAX_OFFICE_ZIP_BYTES, MAX_OFFICE_ZIP_ENTRIES};
use std::io::Read as _;

/// Pure-Rust ZIP+XML text extraction for Office & `OpenDocument` formats (`.docx`, `.dotx`,
/// `.xlsx`, `.pptx`, `.odt`, `.ods`, `.odp`). Zip-bomb bounded (`<= 4 MiB`, `<= 256` entries).
pub fn extract_office_text(bytes: &[u8], ext: &str) -> Option<String> {
    let cursor = std::io::Cursor::new(bytes);
    let mut archive = zip::ZipArchive::new(cursor)
        .map_err(|err| tracing::warn!(%err, ext, "office document is not a readable zip"))
        .ok()?;
    let entry_count = archive.len().min(MAX_OFFICE_ZIP_ENTRIES);
    let mut total_read = 0_usize;

    let mut read_xml =
        |archive: &mut zip::ZipArchive<std::io::Cursor<&[u8]>>, name: &str| -> Option<String> {
            let mut file = archive.by_name(name).ok()?;
            let remaining = MAX_OFFICE_ZIP_BYTES.saturating_sub(total_read);
            if remaining == 0 {
                return None;
            }
            let mut buf = Vec::new();
            let mut limited = (&mut file).take(u64::try_from(remaining).unwrap_or(0));
            limited
                .read_to_end(&mut buf)
                .map_err(|err| tracing::warn!(%err, name, "office document part not read"))
                .ok()?;
            total_read = total_read.saturating_add(buf.len());
            String::from_utf8(buf).ok()
        };

    let mut out = String::new();
    match ext {
        "docx" | "dotx" => {
            if let Some(xml) = read_xml(&mut archive, "word/document.xml") {
                out.push_str(&strip_xml_text(&xml, &["</w:p>", "<w:br", "</w:tr>"]));
            }
        }
        "xlsx" => {
            let shared_strings = read_xml(&mut archive, "xl/sharedStrings.xml")
                .map_or_default(|xml| parse_xlsx_shared_strings(&xml));
            let mut sheet_names: Vec<String> = Vec::new();
            for i in 0..entry_count {
                if let Ok(entry) = archive.by_index(i)
                    && let Ok(n) = entry.name()
                    && n.starts_with("xl/worksheets/sheet")
                    && n.ends_with(".xml")
                {
                    sheet_names.push(n.into_owned());
                }
            }
            sheet_names.sort();
            for (idx, sheet) in sheet_names.iter().enumerate() {
                if let Some(xml) = read_xml(&mut archive, sheet) {
                    if idx > 0 {
                        out.push_str("\n\n");
                    }
                    out.push_str("--- Sheet ");
                    out.push_str(&(idx + 1).to_string());
                    out.push_str(" ---\n");
                    out.push_str(&parse_xlsx_sheet(&xml, &shared_strings));
                }
            }
        }
        "pptx" => {
            let mut slides: Vec<String> = Vec::new();
            for i in 0..entry_count {
                if let Ok(entry) = archive.by_index(i)
                    && let Ok(n) = entry.name()
                    && n.starts_with("ppt/slides/slide")
                    && n.ends_with(".xml")
                {
                    slides.push(n.into_owned());
                }
            }
            slides.sort_by_key(|name| {
                name.trim_start_matches("ppt/slides/slide")
                    .trim_end_matches(".xml")
                    .parse::<u32>()
                    .unwrap_or(u32::MAX)
            });
            for (idx, slide) in slides.iter().enumerate() {
                if let Some(xml) = read_xml(&mut archive, slide) {
                    if idx > 0 {
                        out.push_str("\n\n");
                    }
                    out.push_str("--- Slide ");
                    out.push_str(&(idx + 1).to_string());
                    out.push_str(" ---\n");
                    out.push_str(&strip_xml_text(&xml, &["</a:p>", "</p:txBody>"]));
                }
            }
        }
        "odt" | "ods" | "odp" => {
            if let Some(xml) = read_xml(&mut archive, "content.xml") {
                out.push_str(&strip_xml_text(
                    &xml,
                    &["</text:p>", "</table:table-row>", "<text:line-break"],
                ));
            }
        }
        _ => return None,
    }

    let trimmed = out.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.len() > MAX_EXTRACTED_TEXT_BYTES {
        let end = trimmed.floor_char_boundary(MAX_EXTRACTED_TEXT_BYTES);
        Some(format!("{}\n[...truncated...]", &trimmed[..end]))
    } else {
        Some(trimmed.to_owned())
    }
}

pub(crate) fn decode_xml_entities(input: &str) -> String {
    input
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
}

pub(crate) fn strip_xml_text(xml: &str, break_tags: &[&str]) -> String {
    let mut out = String::with_capacity(xml.len() / 4);
    let mut rest = xml;
    while let Some(lt) = rest.find('<') {
        let text = &rest[..lt];
        if !text.is_empty() {
            out.push_str(&decode_xml_entities(text));
        }
        let after_lt = &rest[lt..];
        let Some(gt) = after_lt.find('>') else {
            break;
        };
        let tag = &after_lt[..=gt];
        if break_tags.iter().any(|b| tag.starts_with(b)) && !out.ends_with('\n') {
            out.push('\n');
        } else if tag.starts_with("<w:tab") || tag.starts_with("</w:tc>") {
            out.push('\t');
        }
        rest = &after_lt[gt + 1..];
    }
    out
}

pub(crate) fn parse_xlsx_shared_strings(xml: &str) -> Vec<String> {
    let mut strings = Vec::new();
    let mut rest = xml;
    while let Some(start) = rest.find("<si") {
        let after = &rest[start..];
        let Some(end) = after.find("</si>") else {
            break;
        };
        let chunk = &after[..end];
        strings.push(strip_xml_text(chunk, &[]).trim().to_owned());
        rest = &after[end + 5..];
    }
    strings
}

pub(crate) fn parse_xlsx_sheet(xml: &str, shared: &[String]) -> String {
    let mut out = String::new();
    let mut rest = xml;
    while let Some(row_start) = rest.find("<row") {
        let after_row = &rest[row_start..];
        let Some(row_end) = after_row.find("</row>") else {
            break;
        };
        let row_chunk = &after_row[..row_end];
        let mut cells = Vec::new();
        let mut cell_rest = row_chunk;
        while let Some(c_start) = find_xml_open_tag(cell_rest, "c") {
            let after_c = &cell_rest[c_start..];
            let Some(c_end) = after_c.find("</c>") else {
                break;
            };
            let cell_xml = &after_c[..c_end];
            let is_shared = cell_xml.contains("t=\"s\"");
            let val = if let Some(v_start) = cell_xml.find("<v>")
                && let Some(v_end) = cell_xml[v_start + 3..].find("</v>")
            {
                let raw = cell_xml[v_start + 3..v_start + 3 + v_end].trim();
                if is_shared {
                    raw.parse::<usize>()
                        .ok()
                        .and_then(|idx| shared.get(idx))
                        .cloned()
                        .unwrap_or_default()
                } else {
                    decode_xml_entities(raw)
                }
            } else {
                strip_xml_text(cell_xml, &[]).trim().to_owned()
            };
            cells.push(val);
            cell_rest = &after_c[c_end + 4..];
        }
        if !cells.is_empty() {
            out.push_str(&cells.join(", "));
            out.push('\n');
        }
        rest = &after_row[row_end + 6..];
    }
    out
}

pub(crate) fn find_xml_open_tag(haystack: &str, tag: &str) -> Option<usize> {
    let needle = format!("<{tag}");
    let mut offset = 0;
    while let Some(pos) = haystack[offset..].find(&needle) {
        let abs = offset + pos;
        let next_idx = abs + needle.len();
        if let Some(next_ch) = haystack[next_idx..].chars().next()
            && matches!(next_ch, ' ' | '>' | '/' | '\t' | '\n' | '\r')
        {
            return Some(abs);
        }
        offset = next_idx;
    }
    None
}
