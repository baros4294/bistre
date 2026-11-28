//! Native Live TTS playback synthesis and Live Voice bidirectional audio WebSocket sessions.
//!
//! - **Live TTS** (`synthesize_speech`): supports Google Gemini TTS (`generateContent` with
//!   `responseModalities: ["AUDIO"]`, wrapping raw 24 kHz 16-bit mono PCM into a standard WAV)
//!   and `OpenAI` / Custom `/audio/speech` endpoints.
//! - **Live Voice** (`LiveVoiceManager`): pure-Rust RFC 6455 TLS WebSocket client over
//!   `tokio-rustls` + `rustls-platform-verifier` (zero `unsafe`, zero extra crates) supporting
//!   both Google Gemini Live API (`BidiGenerateContent`) and `OpenAI` Realtime/Live (`/v1/realtime`).

use base64::Engine as _;
use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, ProviderDialect, ProviderProfile};
use serde_json::{Value, json};

use crate::credentials::{KeyRing, apply_auth_header, resolve_base_url};
pub use crate::live_voice::LiveVoiceManager;

const MAX_TTS_TEXT_CHARS: usize = 8_000;
const MAX_TTS_AUDIO_BYTES: usize = 24 * 1024 * 1024;
pub(crate) const MAX_WS_FRAME_BYTES: usize = 8 * 1024 * 1024;
pub(crate) const LIVE_VOICE_CHANNEL_CAP: usize = 64;

/// Wraps raw 16-bit signed little-endian mono PCM into a valid 44-byte RIFF/WAVE container.
pub fn wrap_pcm16_as_wav(pcm: &[u8], sample_rate_hz: u32) -> Vec<u8> {
    let data_len = u32::try_from(pcm.len()).unwrap_or(u32::MAX - 36);
    let byte_rate = sample_rate_hz.saturating_mul(2);
    let mut wav = Vec::with_capacity(44 + pcm.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&data_len.saturating_add(36).to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16_u32.to_le_bytes()); // PCM chunk size
    wav.extend_from_slice(&1_u16.to_le_bytes()); // PCM format
    wav.extend_from_slice(&1_u16.to_le_bytes()); // mono
    wav.extend_from_slice(&sample_rate_hz.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&2_u16.to_le_bytes()); // block align
    wav.extend_from_slice(&16_u16.to_le_bytes()); // bits per sample
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.extend_from_slice(pcm);
    wav
}

/// Synthesizes spoken audio (WAV bytes) for `text` using the provider's native TTS endpoint.
/// `voice` when one is named, else the provider's own default voice.
pub fn voice_or_default(dialect: ProviderDialect, voice: &str) -> &str {
    match voice.trim() {
        "" => match dialect {
            ProviderDialect::GoogleGemini => "Kore",
            _ => "alloy",
        },
        named => named,
    }
}

pub async fn synthesize_speech(
    http: &reqwest::Client,
    provider: &ProviderProfile,
    keys: &KeyRing,
    model: &str,
    text: &str,
    voice: Option<&str>,
) -> BistreResult<Vec<u8>> {
    let clean_text: String = text.trim().chars().take(MAX_TTS_TEXT_CHARS).collect();
    if clean_text.is_empty() {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "tts_empty_text",
        ));
    }
    let clean_model = model.trim();
    if clean_model.is_empty() {
        return Err(BistreError::new(DiagnosticKey::ProviderModelRequired));
    }
    // Keys rotate like every other request; a missing key never sends an empty credential.
    let api_key = keys.rotation().first().copied().unwrap_or("");
    if api_key.is_empty() && !crate::net::is_loopback_url(&provider.base_url) {
        return Err(BistreError::new(DiagnosticKey::ProviderNotConfigured));
    }
    let base = resolve_base_url(provider.dialect, &provider.base_url);
    let voice_name = voice_or_default(provider.dialect, voice.unwrap_or(""));

    match provider.dialect {
        ProviderDialect::GoogleGemini => {
            synthesize_gemini_tts(http, &base, api_key, clean_model, &clean_text, voice_name).await
        }
        ProviderDialect::OpenAi | ProviderDialect::CustomOpenAi => {
            synthesize_openai_tts(
                http,
                provider.dialect,
                &base,
                api_key,
                clean_model,
                &clean_text,
                voice_name,
            )
            .await
        }
        ProviderDialect::Anthropic => Err(BistreError::with_detail(
            DiagnosticKey::ProviderRequestFailed,
            "tts_unsupported_dialect",
        )),
    }
}

async fn synthesize_gemini_tts(
    http: &reqwest::Client,
    base: &str,
    api_key: &str,
    clean_model: &str,
    clean_text: &str,
    voice_name: &str,
) -> BistreResult<Vec<u8>> {
    let model_slug = clean_model.strip_prefix("models/").unwrap_or(clean_model);
    let base = ProviderDialect::GoogleGemini.api_root(base);
    let url = format!("{base}/v1beta/models/{model_slug}:generateContent");
    let mut headers = reqwest::header::HeaderMap::new();
    headers.insert(
        reqwest::header::CONTENT_TYPE,
        reqwest::header::HeaderValue::from_static("application/json"),
    );
    apply_auth_header(ProviderDialect::GoogleGemini, api_key, &mut headers);

    let body = json!({
        "contents": [{ "role": "user", "parts": [{ "text": clean_text }] }],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {
                "voiceConfig": {
                    "prebuiltVoiceConfig": { "voiceName": voice_name }
                }
            }
        }
    });
    let resp = http
        .post(&url)
        .headers(headers)
        .json(&body)
        .send()
        .await
        .map_err(|_| {
            BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "tts_connect")
        })?;
    if !resp.status().is_success() {
        return Err(BistreError::with_detail(
            DiagnosticKey::ProviderRequestFailed,
            format!("tts_http_{}", resp.status().as_u16()),
        ));
    }
    let payload: Value = resp.json().await.map_err(|_| {
        BistreError::with_detail(DiagnosticKey::ProviderStreamInterrupted, "tts_json")
    })?;
    let inline = payload
        .pointer("/candidates/0/content/parts/0/inlineData")
        .or_else(|| payload.pointer("/candidates/0/content/parts/0/inline_data"))
        .ok_or_else(|| {
            BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "tts_no_audio")
        })?;
    let b64 = inline.get("data").and_then(Value::as_str).ok_or_else(|| {
        BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "tts_no_data")
    })?;
    let mime = inline
        .get("mimeType")
        .or_else(|| inline.get("mime_type"))
        .and_then(Value::as_str)
        .unwrap_or("audio/L16;rate=24000");
    let raw = base64::engine::general_purpose::STANDARD
        .decode(b64)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "tts_b64"))?;
    if raw.len() > MAX_TTS_AUDIO_BYTES {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "tts_audio_too_large",
        ));
    }
    if mime.to_ascii_lowercase().contains("wav") || raw.starts_with(b"RIFF") {
        Ok(raw)
    } else {
        Ok(wrap_pcm16_as_wav(&raw, 24_000))
    }
}

async fn synthesize_openai_tts(
    http: &reqwest::Client,
    dialect: ProviderDialect,
    base: &str,
    api_key: &str,
    clean_model: &str,
    clean_text: &str,
    voice_name: &str,
) -> BistreResult<Vec<u8>> {
    let url = format!("{base}/audio/speech");
    let mut headers = reqwest::header::HeaderMap::new();
    headers.insert(
        reqwest::header::CONTENT_TYPE,
        reqwest::header::HeaderValue::from_static("application/json"),
    );
    apply_auth_header(dialect, api_key, &mut headers);

    // `OpenRouter` returns `wav` for Gemini voices only; `pcm` (16-bit mono at the Chat
    // Completions rate) is served for every voice and is wrapped as WAV here.
    let openrouter = bistre_protocol::dialect::is_openrouter_base(base);
    let body = json!({
        "model": clean_model,
        "input": clean_text,
        "voice": voice_name,
        "response_format": if openrouter { "pcm" } else { "wav" },
    });
    let resp = http
        .post(&url)
        .headers(headers)
        .json(&body)
        .send()
        .await
        .map_err(|_| {
            BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "tts_connect")
        })?;
    if !resp.status().is_success() {
        return Err(BistreError::with_detail(
            DiagnosticKey::ProviderRequestFailed,
            format!("tts_http_{}", resp.status().as_u16()),
        ));
    }
    let bytes = resp.bytes().await.map_err(|_| {
        BistreError::with_detail(DiagnosticKey::ProviderStreamInterrupted, "tts_read")
    })?;
    if bytes.len() > MAX_TTS_AUDIO_BYTES {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "tts_audio_too_large",
        ));
    }
    if openrouter {
        return Ok(wrap_pcm16_as_wav(
            &bytes,
            crate::media_wire::CHAT_AUDIO_RATE_HZ,
        ));
    }
    Ok(bytes.to_vec())
}

#[cfg(test)]
#[path = "voice_tests.rs"]
mod tests;
