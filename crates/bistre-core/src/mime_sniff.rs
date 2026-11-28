//! Types a file by its first bytes when its name does not say: a `.zip` or HEIC photo
//! with no or an unknown extension is never sent as `text/plain`. Signatures from the format
//! specifications (ZIP local header `PK\x03\x04`, ISO-BMFF `ftyp` brands for HEIF/HEIC and MP4,
//! PNG, JPEG, GIF, WebP `RIFF....WEBP`, WAV `RIFF....WAVE`, MP3 `ID3` or a frame sync, Ogg
//! `OggS`, FLAC `fLaC`, Matroska/WebM `\x1a\x45\xdf\xa3`, PDF `%PDF-`).

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
    if head.len() >= 12 && &head[..4] == b"RIFF" {
        match &head[8..12] {
            b"WEBP" => return Some("image/webp"),
            b"WAVE" => return Some("audio/wav"),
            _ => {}
        }
    }
    if starts(b"ID3") || starts(b"\xff\xfb") || starts(b"\xff\xf3") || starts(b"\xff\xf2") {
        return Some("audio/mpeg");
    }
    if starts(b"OggS") {
        return Some("audio/ogg");
    }
    if starts(b"fLaC") {
        return Some("audio/flac");
    }
    if starts(b"\x1a\x45\xdf\xa3") {
        return Some("video/webm");
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_audio_and_video_are_typed_by_their_bytes() {
        let wav = crate::voice::wrap_pcm16_as_wav(&[0, 0], 24_000);
        assert_eq!(sniff(&wav), Some("audio/wav"));
        assert_eq!(sniff(b"ID3\x04rest"), Some("audio/mpeg"));
        assert_eq!(sniff(b"\xff\xfb\x90"), Some("audio/mpeg"));
        assert_eq!(sniff(b"OggS\x00"), Some("audio/ogg"));
        assert_eq!(sniff(b"fLaC\x00"), Some("audio/flac"));
        assert_eq!(sniff(b"\x1a\x45\xdf\xa3\x01"), Some("video/webm"));
        assert_eq!(sniff(b"\x00\x00\x00\x18ftypisom"), Some("video/mp4"));
        assert_eq!(sniff(b"RIFF\x00\x00\x00\x00WEBPVP8"), Some("image/webp"));
        assert_eq!(sniff(b"RIFF\x00\x00\x00\x00AVI "), None);
    }
}
