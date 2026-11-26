//! Types a file by its first bytes when its name does not say (R23): a `.zip` or HEIC photo
//! with no or an unknown extension is never sent as `text/plain`. Signatures from the format
//! specifications (ZIP local header `PK\x03\x04`, ISO-BMFF `ftyp` brands for HEIF/HEIC, PNG,
//! JPEG, GIF, WebP `RIFF....WEBP`, PDF `%PDF-`).

/// How many leading bytes the sniffer looks at.
pub const SNIFF_BYTES: usize = 512;

/// The type a file's leading bytes declare, if they carry a known signature.
pub fn sniff(head: &[u8]) -> Option<&'static str> {
    let starts = |sig: &[u8]| head.starts_with(sig);
    if starts(b"\x89PNG\r\n\x1a\n") {
        return Some("image/png");
    }
    if starts(b"\xff\xd8\xff") {
        return Some("image/jpeg");
    }
    if starts(b"GIF87a") || starts(b"GIF89a") {
        return Some("image/gif");
    }
    if head.len() >= 12 && &head[..4] == b"RIFF" && &head[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    if starts(b"%PDF-") {
        return Some("application/pdf");
    }
    if starts(b"PK\x03\x04") || starts(b"PK\x05\x06") {
        return Some("application/zip");
    }
    if head.len() >= 12 && &head[4..8] == b"ftyp" {
        return match &head[8..12] {
            b"heic" | b"heix" | b"heim" | b"heis" => Some("image/heic"),
            b"mif1" | b"msf1" => Some("image/heif"),
            b"avif" => Some("image/avif"),
            b"qt  " => Some("video/quicktime"),
            b"M4A " => Some("audio/mp4"),
            _ => Some("video/mp4"),
        };
    }
    None
}

/// Whether the leading bytes read as text: valid UTF-8 (a cut final character allowed) with no
/// NUL or other binary control bytes.
pub fn looks_like_text(head: &[u8]) -> bool {
    let valid = match std::str::from_utf8(head) {
        Ok(_) => true,
        Err(e) => e.error_len().is_none(),
    };
    valid
        && !head
            .iter()
            .any(|&b| b == 0 || (b < 0x20 && !matches!(b, b'\n' | b'\r' | b'\t' | 0x0c)))
}
