//! Native Pure-Rust Character Card V3 / V2 importer & exporter supporting:
//! - PNG `tEXt` chunks (`ccv3` preferred, `chara` fallback) with standard IEEE CRC-32 encoding
//! - Raw `CCv3` / `CCv2` JSON
//! - `.charx` ZIP archives (`card.json` + safe path-traversal & 16 MiB decompression guard).

use std::io::{Cursor, Read, Write};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use bistre_protocol::{
    BistreError, BistreResult, CharacterCardRecord, DiagnosticKey, StoryEntryRecord,
};
use serde_json::{Value, json};
use zip::ZipArchive;
use zip::write::SimpleFileOptions;

const PNG_SIGNATURE: [u8; 8] = [137, 80, 78, 71, 13, 10, 26, 10];
const MAX_CARD_JSON_BYTES: usize = 16 * 1024 * 1024;

/// Decoded character card paired with any embedded CCv3/V2 `character_book` lore entries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportedCharacterBundle {
    pub card: CharacterCardRecord,
    pub lore_entries: Vec<StoryEntryRecord>,
}

/// Parses a Character Card V3 / V2 JSON document (accepts wrapped `{spec, data}` or flat V1/V2 objects).
pub fn import_card_json(json_str: &str) -> BistreResult<ImportedCharacterBundle> {
    if json_str.len() > MAX_CARD_JSON_BYTES {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "card_json_too_large",
        ));
    }
    let root: Value = serde_json::from_str(json_str)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "card_invalid_json"))?;
    let spec_version = root
        .get("spec_version")
        .and_then(Value::as_str)
        .unwrap_or("2.0")
        .to_owned();
    let data = root.get("data").unwrap_or(&root);

    let name = data
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| BistreError::with_detail(DiagnosticKey::InvalidInput, "card_missing_name"))?
        .to_owned();

    let str_field = |k: &str| -> String {
        data.get(k)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    let str_vec = |k: &str| -> Vec<String> {
        data.get(k).and_then(Value::as_array).map_or_default(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
    };

    let card = CharacterCardRecord {
        id: String::new(),
        name,
        nickname: str_field("nickname"),
        spec_version,
        description: str_field("description"),
        personality: str_field("personality"),
        scenario: str_field("scenario"),
        first_message: str_field("first_mes"),
        alternate_greetings: str_vec("alternate_greetings"),
        system_prompt: str_field("system_prompt"),
        post_history_instructions: str_field("post_history_instructions"),
        creator_notes: str_field("creator_notes"),
        tags: str_vec("tags"),
        avatar_path: String::new(),
        extensions_json: data
            .get("extensions")
            .map_or_else(|| "{}".to_owned(), Value::to_string),
        updated_at_ms: 0,
    };

    let lore_entries = parse_embedded_character_book(data);
    Ok(ImportedCharacterBundle { card, lore_entries })
}

fn parse_embedded_character_book(data: &Value) -> Vec<StoryEntryRecord> {
    let mut lore_entries = Vec::new();
    let Some(entries) = data
        .get("character_book")
        .and_then(|b| b.get("entries"))
        .and_then(Value::as_array)
    else {
        return lore_entries;
    };
    for raw in entries {
        let entry_name = raw
            .get("name")
            .or_else(|| raw.get("comment"))
            .and_then(Value::as_str)
            .unwrap_or("Lore entry")
            .to_owned();
        let keys: Vec<String> = raw
            .get("keys")
            .and_then(Value::as_array)
            .map_or_default(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            });
        let secondary_keys: Vec<String> = raw
            .get("secondary_keys")
            .and_then(Value::as_array)
            .map_or_default(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            });
        let content = raw
            .get("content")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let enabled = raw.get("enabled").and_then(Value::as_bool).unwrap_or(true);
        let constant = raw
            .get("constant")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let use_regex = raw
            .get("use_regex")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let case_sensitive = raw
            .get("case_sensitive")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let insertion_order = raw
            .get("insertion_order")
            .and_then(Value::as_i64)
            .and_then(|v| i32::try_from(v).ok())
            .unwrap_or(100);
        let priority = raw
            .get("priority")
            .and_then(Value::as_i64)
            .and_then(|v| i32::try_from(v).ok())
            .unwrap_or(10);
        let position = raw
            .get("position")
            .and_then(Value::as_str)
            .unwrap_or("after_char")
            .to_owned();
        lore_entries.push(StoryEntryRecord {
            name: entry_name,
            keys,
            secondary_keys,
            content,
            insertion_order,
            priority,
            position,
            constant,
            use_regex,
            case_sensitive,
            enabled,
            ..StoryEntryRecord::default()
        });
    }
    lore_entries
}

/// Serializes a `CharacterCardRecord` (+ optional lorebook entries) into standard `CCv3` JSON.
pub fn export_card_ccv3_json(
    card: &CharacterCardRecord,
    lore_entries: &[StoryEntryRecord],
) -> String {
    let book_entries: Vec<Value> = lore_entries
        .iter()
        .map(|e| {
            json!({
                "name": e.name,
                "keys": e.keys,
                "secondary_keys": e.secondary_keys,
                "content": e.content,
                "enabled": e.enabled,
                "constant": e.constant,
                "use_regex": e.use_regex,
                "case_sensitive": e.case_sensitive,
                "insertion_order": e.insertion_order,
                "priority": e.priority,
                "position": e.position,
            })
        })
        .collect();
    let extensions: Value =
        serde_json::from_str(&card.extensions_json).unwrap_or_else(|_| json!({}));

    let payload = json!({
        "spec": "chara_card_v3",
        "spec_version": "3.0",
        "data": {
            "name": card.name,
            "nickname": card.nickname,
            "description": card.description,
            "personality": card.personality,
            "scenario": card.scenario,
            "first_mes": card.first_message,
            "alternate_greetings": card.alternate_greetings,
            "system_prompt": card.system_prompt,
            "post_history_instructions": card.post_history_instructions,
            "creator_notes": card.creator_notes,
            "tags": card.tags,
            "extensions": extensions,
            "character_book": {
                "name": format!("{} Lorebook", card.name),
                "entries": book_entries,
            }
        }
    });
    serde_json::to_string_pretty(&payload).unwrap_or_else(|_| "{}".to_owned())
}

/// Decodes a Character Card V3 (`ccv3`) or V2 (`chara`) embedded inside PNG `tEXt` chunks.
pub fn import_card_png(png_bytes: &[u8]) -> BistreResult<ImportedCharacterBundle> {
    if png_bytes.len() < 8 || png_bytes[..8] != PNG_SIGNATURE {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "invalid_png_signature",
        ));
    }
    let mut pos = 8_usize;
    let mut ccv3_b64: Option<String> = None;
    let mut chara_b64: Option<String> = None;

    while pos + 12 <= png_bytes.len() {
        let len = u32::from_be_bytes([
            png_bytes[pos],
            png_bytes[pos + 1],
            png_bytes[pos + 2],
            png_bytes[pos + 3],
        ]) as usize;
        let chunk_type = &png_bytes[(pos + 4)..(pos + 8)];
        let data_start = pos + 8;
        let Some(data_end) = data_start.checked_add(len) else {
            break;
        };
        if data_end + 4 > png_bytes.len() {
            break;
        }
        if chunk_type == b"tEXt" {
            let chunk_data = &png_bytes[data_start..data_end];
            if let Some(nul_idx) = chunk_data.iter().position(|&b| b == 0) {
                let keyword = String::from_utf8_lossy(&chunk_data[..nul_idx]);
                let value = String::from_utf8_lossy(&chunk_data[(nul_idx + 1)..]).into_owned();
                if keyword.eq_ignore_ascii_case("ccv3") {
                    ccv3_b64 = Some(value);
                } else if keyword.eq_ignore_ascii_case("chara") {
                    chara_b64 = Some(value);
                }
            }
        }
        pos = data_end + 4;
    }

    let encoded = ccv3_b64.or(chara_b64).ok_or_else(|| {
        BistreError::with_detail(DiagnosticKey::InvalidInput, "png_missing_card_chunk")
    })?;
    let decoded = BASE64_STANDARD
        .decode(encoded.trim())
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "png_card_base64"))?;
    let json_str = String::from_utf8(decoded)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "png_card_utf8"))?;
    import_card_json(&json_str)
}

/// Embeds both `ccv3` and V2-compatible `chara` `tEXt` chunks before `IEND` inside a PNG image.
pub fn export_card_png(
    base_png_bytes: &[u8],
    card: &CharacterCardRecord,
    lore_entries: &[StoryEntryRecord],
) -> BistreResult<Vec<u8>> {
    if base_png_bytes.len() < 20 || base_png_bytes[..8] != PNG_SIGNATURE {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "invalid_png_signature",
        ));
    }
    let json_text = export_card_ccv3_json(card, lore_entries);
    let b64 = BASE64_STANDARD.encode(json_text.as_bytes());
    let ccv3_chunk = build_png_text_chunk("ccv3", &b64);
    let chara_chunk = build_png_text_chunk("chara", &b64);

    // Strip any existing `ccv3`/`chara` chunks and insert fresh ones immediately before `IEND`.
    let mut out = Vec::with_capacity(base_png_bytes.len() + ccv3_chunk.len() * 2);
    out.extend_from_slice(&PNG_SIGNATURE);

    let mut pos = 8_usize;
    let mut inserted = false;
    while pos + 12 <= base_png_bytes.len() {
        let len = u32::from_be_bytes([
            base_png_bytes[pos],
            base_png_bytes[pos + 1],
            base_png_bytes[pos + 2],
            base_png_bytes[pos + 3],
        ]) as usize;
        let chunk_type = &base_png_bytes[(pos + 4)..(pos + 8)];
        let Some(chunk_end) = pos.checked_add(12).and_then(|v| v.checked_add(len)) else {
            break;
        };
        if chunk_end > base_png_bytes.len() {
            break;
        }
        if chunk_type == b"tEXt" {
            let chunk_data = &base_png_bytes[(pos + 8)..(pos + 8 + len)];
            if let Some(nul) = chunk_data.iter().position(|&b| b == 0) {
                let kw = String::from_utf8_lossy(&chunk_data[..nul]);
                if kw.eq_ignore_ascii_case("ccv3") || kw.eq_ignore_ascii_case("chara") {
                    pos = chunk_end;
                    continue;
                }
            }
        }
        if chunk_type == b"IEND" && !inserted {
            out.extend_from_slice(&ccv3_chunk);
            out.extend_from_slice(&chara_chunk);
            inserted = true;
        }
        out.extend_from_slice(&base_png_bytes[pos..chunk_end]);
        pos = chunk_end;
    }

    if !inserted {
        out.extend_from_slice(&ccv3_chunk);
        out.extend_from_slice(&chara_chunk);
    }
    Ok(out)
}

/// Imports a `.charx` ZIP archive cleanly with strict path-traversal and 16 MiB zip-bomb checks.
pub fn import_card_charx(zip_bytes: &[u8]) -> BistreResult<ImportedCharacterBundle> {
    let cursor = Cursor::new(zip_bytes);
    let mut archive = ZipArchive::new(cursor)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "invalid_charx_zip"))?;

    // Validate every archive entry name against Zip Slip (`..` or absolute paths) first.
    for i in 0..archive.len() {
        let entry = archive
            .by_index(i)
            .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "charx_entry"))?;
        let name = entry.name().map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InvalidInput, "charx_entry_name")
        })?;
        if name.contains("..")
            || name.starts_with('/')
            || name.starts_with('\\')
            || name.contains(':')
        {
            return Err(BistreError::with_detail(
                DiagnosticKey::ToolPathDenied,
                "charx_path_traversal_blocked",
            ));
        }
    }

    let mut card_file = archive.by_name("card.json").map_err(|_| {
        BistreError::with_detail(DiagnosticKey::InvalidInput, "charx_missing_card_json")
    })?;
    let mut limited = card_file.by_ref().take((MAX_CARD_JSON_BYTES + 1) as u64);
    let mut buf = Vec::new();
    limited
        .read_to_end(&mut buf)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "charx_read_card"))?;
    if buf.len() > MAX_CARD_JSON_BYTES {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "charx_card_too_large",
        ));
    }
    let json_str = String::from_utf8(buf)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "charx_utf8"))?;
    import_card_json(&json_str)
}

/// Exports a Character Card (+ lore entries) into a clean `.charx` ZIP archive containing `card.json`.
pub fn export_card_charx(
    card: &CharacterCardRecord,
    lore_entries: &[StoryEntryRecord],
) -> BistreResult<Vec<u8>> {
    let mut cursor = Cursor::new(Vec::new());
    {
        let mut writer = zip::ZipWriter::new(&mut cursor);
        let options =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        writer
            .start_file("card.json", options)
            .map_err(|_| BistreError::with_detail(DiagnosticKey::ExportFailed, "charx_start"))?;
        let json_str = export_card_ccv3_json(card, lore_entries);
        writer
            .write_all(json_str.as_bytes())
            .map_err(|_| BistreError::with_detail(DiagnosticKey::ExportFailed, "charx_write"))?;
        writer
            .finish()
            .map_err(|_| BistreError::with_detail(DiagnosticKey::ExportFailed, "charx_finish"))?;
    }
    Ok(cursor.into_inner())
}

fn build_png_text_chunk(keyword: &str, text: &str) -> Vec<u8> {
    let mut data = Vec::with_capacity(keyword.len() + 1 + text.len());
    data.extend_from_slice(keyword.as_bytes());
    data.push(0);
    data.extend_from_slice(text.as_bytes());

    let len = u32::try_from(data.len()).unwrap_or(0);
    let mut crc_input = Vec::with_capacity(4 + data.len());
    crc_input.extend_from_slice(b"tEXt");
    crc_input.extend_from_slice(&data);
    let crc = ieee_crc32(&crc_input);

    let mut chunk = Vec::with_capacity(12 + data.len());
    chunk.extend_from_slice(&len.to_be_bytes());
    chunk.extend_from_slice(b"tEXt");
    chunk.extend_from_slice(&data);
    chunk.extend_from_slice(&crc.to_be_bytes());
    chunk
}

fn ieee_crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFF_u32;
    for &b in bytes {
        crc ^= u32::from(b);
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

#[cfg(test)]
mod tests {
    use super::*;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    fn minimal_valid_png() -> Vec<u8> {
        // Minimal 1x1 PNG header + IHDR + IEND for chunk round-trip testing.
        let mut png = Vec::new();
        png.extend_from_slice(&PNG_SIGNATURE);
        let ihdr_data: [u8; 13] = [0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0];
        png.extend_from_slice(&13_u32.to_be_bytes());
        png.extend_from_slice(b"IHDR");
        png.extend_from_slice(&ihdr_data);
        let mut ihdr_crc = Vec::from(&b"IHDR"[..]);
        ihdr_crc.extend_from_slice(&ihdr_data);
        png.extend_from_slice(&ieee_crc32(&ihdr_crc).to_be_bytes());
        png.extend_from_slice(&0_u32.to_be_bytes());
        png.extend_from_slice(b"IEND");
        png.extend_from_slice(&ieee_crc32(b"IEND").to_be_bytes());
        png
    }

    #[test]
    fn ccv3_json_png_and_charx_round_trip_and_zip_slip_blocked() -> TestResult {
        let card = CharacterCardRecord {
            name: "Captain Aria".to_owned(),
            description: "Navigator of the brass dirigible.".to_owned(),
            alternate_greetings: vec!["Fog blankets the pier.".to_owned()],
            ..CharacterCardRecord::default()
        };
        let lore = vec![StoryEntryRecord {
            name: "Dirigible".to_owned(),
            keys: vec!["airship".to_owned()],
            content: "Powered by helium cells.".to_owned(),
            ..StoryEntryRecord::default()
        }];

        // 1. JSON round-trip.
        let json_str = export_card_ccv3_json(&card, &lore);
        let from_json = Some(import_card_json(&json_str)?);
        assert_eq!(
            from_json.as_ref().map(|b| b.card.name.as_str()),
            Some("Captain Aria")
        );
        assert_eq!(from_json.as_ref().map(|b| b.lore_entries.len()), Some(1));

        // 2. PNG tEXt (ccv3 + chara) round-trip.
        let png_with_card = Some(export_card_png(&minimal_valid_png(), &card, &lore)?);
        assert!(png_with_card.is_some());
        if let Some(bytes) = png_with_card {
            let decoded = Some(import_card_png(&bytes)?);
            assert_eq!(
                decoded.as_ref().map(|b| b.card.name.as_str()),
                Some("Captain Aria")
            );
        }

        // 3. `.charx` ZIP round-trip.
        let charx = Some(export_card_charx(&card, &lore)?);
        assert!(charx.is_some());
        if let Some(zbytes) = charx {
            let decoded = Some(import_card_charx(&zbytes)?);
            assert_eq!(
                decoded.as_ref().map(|b| b.card.name.as_str()),
                Some("Captain Aria")
            );
        }

        // 4. Zip Slip path traversal (`../evil.txt`) MUST be rejected!
        let mut bad_zip = Cursor::new(Vec::new());
        {
            let mut w = zip::ZipWriter::new(&mut bad_zip);
            let opts = SimpleFileOptions::default();
            assert!(w.start_file("../evil.txt", opts).is_ok());
            assert!(w.write_all(b"escape").is_ok());
            assert!(w.finish().is_ok());
        }
        let blocked = import_card_charx(&bad_zip.into_inner());
        assert!(blocked.is_err());
        Ok(())
    }
}
