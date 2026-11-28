//! Live voice sessions over a TLS WebSocket (split out of `voice.rs`).

use crate::credentials::{KeyRing, resolve_base_url};
use crate::events::emit;
use crate::voice::{
    LIVE_VOICE_CHANNEL_CAP, MAX_WS_FRAME_BYTES, voice_or_default, wrap_pcm16_as_wav,
};
use base64::Engine as _;
use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, EngineEvent, ProviderDialect, ProviderProfile,
    lock_or_recover,
};
use rustls::pki_types::ServerName;
use rustls_platform_verifier::ConfigVerifierExt as _;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncRead, AsyncReadExt as _, AsyncWrite, AsyncWriteExt as _};
use tokio::net::TcpStream;
use tokio::sync::{broadcast, mpsc};
use tokio_rustls::TlsConnector;
use uuid::Uuid;

pub(crate) enum LiveOutbound {
    PcmChunk(String),
    TextTurn(String),
    Close,
}

/// Manages active bidirectional Live Voice WebSocket sessions cleanly with bounded channels.
#[derive(Debug, Default)]
pub struct LiveVoiceManager {
    sessions: Mutex<HashMap<String, mpsc::Sender<LiveOutbound>>>,
}

impl LiveVoiceManager {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn start_session(
        self: &Arc<Self>,
        provider: ProviderProfile,
        keys: KeyRing,
        model: &str,
        voice: String,
        system_prompt: String,
        events_tx: broadcast::Sender<EngineEvent>,
    ) -> BistreResult<String> {
        let clean_model = model.trim().to_owned();
        if clean_model.is_empty() {
            return Err(BistreError::new(DiagnosticKey::ProviderModelRequired));
        }
        let session_id = format!("live_{}", Uuid::now_v7());
        let (tx, rx) = mpsc::channel::<LiveOutbound>(LIVE_VOICE_CHANNEL_CAP);
        lock_or_recover(&self.sessions, "live_voice_sessions").insert(session_id.clone(), tx);

        let mgr = Arc::clone(self);
        let sid = session_id.clone();
        tokio::spawn(async move {
            emit(
                &events_tx,
                EngineEvent::LiveVoiceState {
                    session_id: sid.clone(),
                    state: "connecting".to_owned(),
                    detail: None,
                },
            );
            let res = run_live_voice_ws(
                &sid,
                &provider,
                &keys,
                &clean_model,
                voice_or_default(provider.dialect, &voice),
                &system_prompt,
                rx,
                &events_tx,
            )
            .await;
            lock_or_recover(&mgr.sessions, "live_voice_sessions").remove(&sid);
            match res {
                Ok(()) => emit(
                    &events_tx,
                    EngineEvent::LiveVoiceState {
                        session_id: sid,
                        state: "closed".to_owned(),
                        detail: None,
                    },
                ),
                Err(err) => emit(
                    &events_tx,
                    EngineEvent::LiveVoiceState {
                        session_id: sid,
                        state: "error".to_owned(),
                        // The key first, so the app names the reason in words.
                        detail: Some(err.to_string()),
                    },
                ),
            }
        });
        Ok(session_id)
    }

    pub fn send_pcm_chunk(&self, session_id: &str, pcm_base64: String) -> BistreResult<()> {
        let tx = lock_or_recover(&self.sessions, "live_voice_sessions")
            .get(session_id)
            .cloned()
            .ok_or_else(|| {
                BistreError::with_detail(DiagnosticKey::InvalidInput, "live_no_session")
            })?;
        if tx.try_send(LiveOutbound::PcmChunk(pcm_base64)).is_err() {
            tracing::debug!(
                session_id,
                "dropping live voice mic chunk due to backpressure"
            );
        }
        Ok(())
    }

    pub fn send_text(&self, session_id: &str, text: String) -> BistreResult<()> {
        let tx = lock_or_recover(&self.sessions, "live_voice_sessions")
            .get(session_id)
            .cloned()
            .ok_or_else(|| {
                BistreError::with_detail(DiagnosticKey::InvalidInput, "live_no_session")
            })?;
        if tx.try_send(LiveOutbound::TextTurn(text)).is_err() {
            return Err(BistreError::with_detail(
                DiagnosticKey::InternalError,
                "live_send_full",
            ));
        }
        Ok(())
    }

    pub fn stop_session(&self, session_id: &str) {
        if let Some(tx) = lock_or_recover(&self.sessions, "live_voice_sessions").remove(session_id)
            && tx.try_send(LiveOutbound::Close).is_err()
        {
            tracing::debug!(session_id, "live voice session already closed");
        }
    }

    pub fn stop_all(&self) {
        let all: Vec<_> = lock_or_recover(&self.sessions, "live_voice_sessions")
            .drain()
            .collect();
        for (sid, tx) in all {
            if tx.try_send(LiveOutbound::Close).is_err() {
                tracing::debug!(session_id = %sid, "live voice session already closed");
            }
        }
    }
}

/// Where and how a live-voice WebSocket connects.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct LiveTarget {
    host: String,
    port: u16,
    pub(crate) is_tls: bool,
    pub(crate) path_and_query: String,
    pub(crate) headers: Vec<(String, String)>,
}

/// Builds the live-voice WebSocket target.
///
/// Gemini Live authenticates only with a `key` query parameter (the documented method; an
/// `x-goog-api-key` header is not accepted), so the key is URL-encoded
/// into the query and the session is refused over plain `ws` to a non-loopback host, so the
/// key never crosses the network unencrypted. `OpenAI` Realtime keeps the base path
/// (proxies mount it below `/v1`) and URL-encodes the model.
pub(crate) fn live_ws_target(
    dialect: ProviderDialect,
    base_url: &str,
    model: &str,
    api_key: &str,
) -> BistreResult<LiveTarget> {
    let is_local = crate::net::is_loopback_url(base_url);
    if api_key.is_empty() && !is_local {
        return Err(BistreError::new(DiagnosticKey::ProviderNotConfigured));
    }
    let base = resolve_base_url(dialect, base_url);
    let parsed = reqwest::Url::parse(&base).map_err(|_| {
        BistreError::with_detail(DiagnosticKey::InvalidInput, "live_invalid_base_url")
    })?;
    let host = parsed
        .host_str()
        .ok_or_else(|| BistreError::with_detail(DiagnosticKey::InvalidInput, "live_no_host"))?
        .to_owned();
    let is_tls = parsed.scheme().eq_ignore_ascii_case("https");
    if !is_tls && !is_local {
        return Err(BistreError::with_detail(
            DiagnosticKey::ProviderRequestFailed,
            "live_insecure_transport",
        ));
    }
    let port = parsed
        .port_or_known_default()
        .unwrap_or(if is_tls { 443 } else { 80 });
    let mut target = parsed.clone();
    let headers = match dialect {
        ProviderDialect::GoogleGemini => {
            target.set_path(
                "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
            );
            target.set_query(None);
            if !api_key.is_empty() {
                target.query_pairs_mut().append_pair("key", api_key);
            }
            Vec::new()
        }
        ProviderDialect::OpenAi | ProviderDialect::CustomOpenAi => {
            let path = format!("{}/realtime", parsed.path().trim_end_matches('/'));
            target.set_path(&path);
            target.set_query(None);
            target.query_pairs_mut().append_pair("model", model);
            vec![
                ("Authorization".to_owned(), format!("Bearer {api_key}")),
                ("OpenAI-Beta".to_owned(), "realtime=v1".to_owned()),
            ]
        }
        ProviderDialect::Anthropic => {
            return Err(BistreError::with_detail(
                DiagnosticKey::ProviderRequestFailed,
                "live_voice_unsupported_dialect",
            ));
        }
    };
    let path_and_query = match target.query() {
        Some(q) => format!("{}?{q}", target.path()),
        None => target.path().to_owned(),
    };
    Ok(LiveTarget {
        host,
        port,
        is_tls,
        path_and_query,
        headers,
    })
}
#[expect(
    clippy::too_many_arguments,
    reason = "Live voice runner takes explicit immutable session config without global state."
)]
pub(crate) async fn run_live_voice_ws(
    session_id: &str,
    provider: &ProviderProfile,
    keys: &KeyRing,
    model: &str,
    voice: &str,
    system_prompt: &str,
    mut rx: mpsc::Receiver<LiveOutbound>,
    events_tx: &broadcast::Sender<EngineEvent>,
) -> BistreResult<()> {
    // Keys rotate like every other request (round-robin start).
    let api_key = keys.rotation().first().copied().unwrap_or("");
    let LiveTarget {
        host,
        port,
        is_tls,
        path_and_query: ws_path,
        headers: extra_headers,
    } = live_ws_target(provider.dialect, &provider.base_url, model, api_key)?;
    let tcp = TcpStream::connect((host.as_str(), port))
        .await
        .map_err(|_| BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "live_tcp"))?;

    if is_tls {
        let mut tls_cfg = rustls::ClientConfig::with_platform_verifier().map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InternalError, "live_tls_config")
        })?;
        tls_cfg.alpn_protocols = vec![b"http/1.1".to_vec()];
        let connector = TlsConnector::from(Arc::new(tls_cfg));
        let server_name = ServerName::try_from(host.clone()).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InvalidInput, "live_server_name")
        })?;
        let stream = connector.connect(server_name, tcp).await.map_err(|_| {
            BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "live_tls")
        })?;
        drive_ws_protocol(
            stream,
            &host,
            &ws_path,
            &extra_headers,
            session_id,
            provider.dialect,
            model,
            voice,
            system_prompt,
            &mut rx,
            events_tx,
        )
        .await
    } else {
        drive_ws_protocol(
            tcp,
            &host,
            &ws_path,
            &extra_headers,
            session_id,
            provider.dialect,
            model,
            voice,
            system_prompt,
            &mut rx,
            events_tx,
        )
        .await
    }
}

pub(crate) async fn ws_handshake<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    host: &str,
    path: &str,
    extra_headers: &[(String, String)],
) -> BistreResult<()> {
    let ws_key = base64::engine::general_purpose::STANDARD.encode(Uuid::now_v7().as_bytes());
    let mut req = format!(
        "GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {ws_key}\r\nSec-WebSocket-Version: 13\r\n"
    );
    for (k, v) in extra_headers {
        req.push_str(k);
        req.push_str(": ");
        req.push_str(v);
        req.push_str("\r\n");
    }
    req.push_str("\r\n");
    stream
        .write_all(req.as_bytes())
        .await
        .map_err(|_| BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "ws_write"))?;
    stream
        .flush()
        .await
        .map_err(|_| BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "ws_flush"))?;

    let mut header_buf = Vec::with_capacity(512);
    let mut byte = [0_u8; 1];
    while header_buf.len() < 16_384 {
        let n = stream.read(&mut byte).await.map_err(|_| {
            BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "ws_hdr")
        })?;
        if n == 0 {
            return Err(BistreError::with_detail(
                DiagnosticKey::ProviderRequestFailed,
                "ws_eof_handshake",
            ));
        }
        header_buf.push(byte[0]);
        if header_buf.ends_with(b"\r\n\r\n") {
            break;
        }
    }
    let header_str = String::from_utf8_lossy(&header_buf);
    if !header_str.starts_with("HTTP/1.1 101") && !header_str.starts_with("HTTP/1.0 101") {
        let status_line = header_str.lines().next().unwrap_or("ws_rejected");
        return Err(BistreError::with_detail(
            DiagnosticKey::ProviderRequestFailed,
            status_line.to_owned(),
        ));
    }
    Ok(())
}

pub(crate) fn build_live_setup_frame(
    dialect: ProviderDialect,
    model: &str,
    voice: &str,
    system_prompt: &str,
) -> String {
    if dialect == ProviderDialect::GoogleGemini {
        let clean_model = if model.starts_with("models/") {
            model.to_owned()
        } else {
            format!("models/{model}")
        };
        let voice_name = if voice.trim().is_empty() {
            "Kore"
        } else {
            voice.trim()
        };
        let mut setup = json!({
            "model": clean_model,
            "generationConfig": {
                "responseModalities": ["AUDIO"],
                "speechConfig": {
                    "voiceConfig": {
                        "prebuiltVoiceConfig": { "voiceName": voice_name }
                    }
                }
            },
            "inputAudioTranscription": {},
            "outputAudioTranscription": {}
        });
        if !system_prompt.trim().is_empty()
            && let Some(obj) = setup.as_object_mut()
        {
            obj.insert(
                "systemInstruction".to_owned(),
                json!({ "parts": [{ "text": system_prompt }] }),
            );
        }
        json!({ "setup": setup }).to_string()
    } else {
        let voice_name = if voice.trim().is_empty() {
            "alloy"
        } else {
            voice.trim()
        };
        json!({
            "type": "session.update",
            "session": {
                "modalities": ["audio", "text"],
                "instructions": system_prompt,
                "voice": voice_name,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
            }
        })
        .to_string()
    }
}

pub(crate) async fn send_live_outbound<W: AsyncWrite + Unpin>(
    writer: &mut W,
    dialect: ProviderDialect,
    msg: LiveOutbound,
) -> BistreResult<bool> {
    match msg {
        LiveOutbound::PcmChunk(b64) => {
            let payload = if dialect == ProviderDialect::GoogleGemini {
                json!({
                    "realtimeInput": {
                        "mediaChunks": [{
                            "mimeType": "audio/pcm;rate=16000",
                            "data": b64
                        }]
                    }
                })
                .to_string()
            } else {
                json!({
                    "type": "input_audio_buffer.append",
                    "audio": b64
                })
                .to_string()
            };
            write_ws_frame(writer, 0x1, payload.as_bytes()).await?;
            Ok(true)
        }
        LiveOutbound::TextTurn(text) => {
            let payload = if dialect == ProviderDialect::GoogleGemini {
                json!({
                    "clientContent": {
                        "turns": [{
                            "role": "user",
                            "parts": [{ "text": text }]
                        }],
                        "turnComplete": true
                    }
                })
                .to_string()
            } else {
                json!({
                    "type": "conversation.item.create",
                    "item": {
                        "type": "message",
                        "role": "user",
                        "content": [{ "type": "input_text", "text": text }]
                    }
                })
                .to_string()
            };
            write_ws_frame(writer, 0x1, payload.as_bytes()).await?;
            if dialect != ProviderDialect::GoogleGemini {
                let trig = json!({ "type": "response.create" }).to_string();
                write_ws_frame(writer, 0x1, trig.as_bytes()).await?;
            }
            Ok(true)
        }
        LiveOutbound::Close => {
            if let Err(err) = write_ws_frame(writer, 0x8, &[]).await {
                tracing::debug!(error = ?err, "live voice close frame failed");
            }
            Ok(false)
        }
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "Explicit protocol parameters avoid shared mutable session state."
)]
pub(crate) async fn drive_ws_protocol<S>(
    mut stream: S,
    host: &str,
    path: &str,
    extra_headers: &[(String, String)],
    session_id: &str,
    dialect: ProviderDialect,
    model: &str,
    voice: &str,
    system_prompt: &str,
    rx: &mut mpsc::Receiver<LiveOutbound>,
    events_tx: &broadcast::Sender<EngineEvent>,
) -> BistreResult<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    ws_handshake(&mut stream, host, path, extra_headers).await?;
    let setup_frame = build_live_setup_frame(dialect, model, voice, system_prompt);
    write_ws_frame(&mut stream, 0x1, setup_frame.as_bytes()).await?;

    emit(
        events_tx,
        EngineEvent::LiveVoiceState {
            session_id: session_id.to_owned(),
            state: "listening".to_owned(),
            detail: None,
        },
    );

    let (mut reader, mut writer) = tokio::io::split(stream);
    let mut pcm_accum: Vec<u8> = Vec::new();

    loop {
        tokio::select! {
            inbound = read_ws_frame(&mut reader) => {
                match inbound {
                    Ok(Some((opcode, payload))) => match opcode {
                        0x1 | 0x2 => {
                            if let Ok(text) = std::str::from_utf8(&payload)
                                && let Ok(val) = serde_json::from_str::<Value>(text)
                            {
                                handle_live_server_json(
                                    session_id,
                                    dialect,
                                    &val,
                                    &mut pcm_accum,
                                    events_tx,
                                );
                            }
                        }
                        0x8 => break,
                        0x9 => write_ws_frame(&mut writer, 0xA, &payload).await?,
                        _ => {}
                    },
                    Ok(None) => break,
                    Err(err) => return Err(err),
                }
            }
            outbound = rx.recv() => {
                let msg = outbound.unwrap_or(LiveOutbound::Close);
                if !send_live_outbound(&mut writer, dialect, msg).await? {
                    break;
                }
            }
        }
    }
    Ok(())
}

pub(crate) fn handle_live_server_json(
    session_id: &str,
    dialect: ProviderDialect,
    val: &Value,
    pcm_accum: &mut Vec<u8>,
    events_tx: &broadcast::Sender<EngineEvent>,
) {
    if dialect == ProviderDialect::GoogleGemini {
        handle_gemini_live_json(session_id, val, pcm_accum, events_tx);
    } else {
        handle_openai_live_json(session_id, val, pcm_accum, events_tx);
    }
}

pub(crate) fn handle_gemini_live_json(
    session_id: &str,
    val: &Value,
    pcm_accum: &mut Vec<u8>,
    events_tx: &broadcast::Sender<EngineEvent>,
) {
    let Some(sc) = val.get("serverContent") else {
        return;
    };
    if let Some(t) = sc
        .pointer("/inputTranscription/text")
        .and_then(Value::as_str)
        && !t.is_empty()
    {
        emit(
            events_tx,
            EngineEvent::LiveVoiceTranscript {
                session_id: session_id.to_owned(),
                role: "user".to_owned(),
                text: t.to_owned(),
                is_final: false,
            },
        );
    }
    if let Some(t) = sc
        .pointer("/outputTranscription/text")
        .and_then(Value::as_str)
        && !t.is_empty()
    {
        emit(
            events_tx,
            EngineEvent::LiveVoiceTranscript {
                session_id: session_id.to_owned(),
                role: "assistant".to_owned(),
                text: t.to_owned(),
                is_final: false,
            },
        );
    }
    if let Some(parts) = sc.pointer("/modelTurn/parts").and_then(Value::as_array) {
        for part in parts {
            if let Some(text) = part.get("text").and_then(Value::as_str)
                && !text.is_empty()
            {
                emit(
                    events_tx,
                    EngineEvent::LiveVoiceTranscript {
                        session_id: session_id.to_owned(),
                        role: "assistant".to_owned(),
                        text: text.to_owned(),
                        is_final: false,
                    },
                );
            }
            if let Some(data) = part.pointer("/inlineData/data").and_then(Value::as_str)
                && let Ok(raw) = base64::engine::general_purpose::STANDARD.decode(data)
            {
                pcm_accum.extend_from_slice(&raw);
            }
        }
    }
    let turn_done = sc
        .get("turnComplete")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if turn_done && !pcm_accum.is_empty() {
        let wav = wrap_pcm16_as_wav(pcm_accum, 24_000);
        pcm_accum.clear();
        emit(
            events_tx,
            EngineEvent::LiveVoiceAudio {
                session_id: session_id.to_owned(),
                wav_base64: base64::engine::general_purpose::STANDARD.encode(wav),
            },
        );
        emit(
            events_tx,
            EngineEvent::LiveVoiceState {
                session_id: session_id.to_owned(),
                state: "listening".to_owned(),
                detail: None,
            },
        );
    }
}

pub(crate) fn handle_openai_live_json(
    session_id: &str,
    val: &Value,
    pcm_accum: &mut Vec<u8>,
    events_tx: &broadcast::Sender<EngineEvent>,
) {
    let kind = val.get("type").and_then(Value::as_str).unwrap_or("");
    match kind {
        "response.audio.delta" => {
            if let Some(delta) = val.get("delta").and_then(Value::as_str)
                && let Ok(raw) = base64::engine::general_purpose::STANDARD.decode(delta)
            {
                pcm_accum.extend_from_slice(&raw);
            }
        }
        "response.audio.done" => {
            if !pcm_accum.is_empty() {
                let wav = wrap_pcm16_as_wav(pcm_accum, 24_000);
                pcm_accum.clear();
                emit(
                    events_tx,
                    EngineEvent::LiveVoiceAudio {
                        session_id: session_id.to_owned(),
                        wav_base64: base64::engine::general_purpose::STANDARD.encode(wav),
                    },
                );
            }
        }
        "response.audio_transcript.delta" | "response.text.delta" => {
            if let Some(delta) = val.get("delta").and_then(Value::as_str) {
                emit(
                    events_tx,
                    EngineEvent::LiveVoiceTranscript {
                        session_id: session_id.to_owned(),
                        role: "assistant".to_owned(),
                        text: delta.to_owned(),
                        is_final: false,
                    },
                );
            }
        }
        "conversation.item.input_audio_transcription.completed" => {
            if let Some(text) = val.get("transcript").and_then(Value::as_str) {
                emit(
                    events_tx,
                    EngineEvent::LiveVoiceTranscript {
                        session_id: session_id.to_owned(),
                        role: "user".to_owned(),
                        text: text.to_owned(),
                        is_final: true,
                    },
                );
            }
        }
        _ => {}
    }
}

/// Writes a masked RFC 6455 client frame.
pub(crate) async fn write_ws_frame<W: AsyncWrite + Unpin>(
    writer: &mut W,
    opcode: u8,
    payload: &[u8],
) -> BistreResult<()> {
    let mut header = Vec::with_capacity(14);
    header.push(0x80 | (opcode & 0x0F));
    let len = payload.len();
    if len < 126 {
        header.push(0x80 | u8::try_from(len).unwrap_or(0));
    } else if u16::try_from(len).is_ok() {
        header.push(0x80 | 0x7E);
        header.extend_from_slice(&u16::try_from(len).unwrap_or(0).to_be_bytes());
    } else {
        header.push(0x80 | 0x7F);
        header.extend_from_slice(&u64::try_from(len).unwrap_or(0).to_be_bytes());
    }
    let mask = *Uuid::now_v7().as_bytes();
    let mask_key = [mask[0], mask[1], mask[2], mask[3]];
    header.extend_from_slice(&mask_key);
    let mut masked = Vec::with_capacity(len);
    for (i, b) in payload.iter().enumerate() {
        masked.push(b ^ mask_key[i & 3]);
    }
    writer.write_all(&header).await.map_err(|_| {
        BistreError::with_detail(DiagnosticKey::ProviderStreamInterrupted, "ws_tx_h")
    })?;
    writer.write_all(&masked).await.map_err(|_| {
        BistreError::with_detail(DiagnosticKey::ProviderStreamInterrupted, "ws_tx_p")
    })?;
    writer.flush().await.map_err(|_| {
        BistreError::with_detail(DiagnosticKey::ProviderStreamInterrupted, "ws_tx_f")
    })?;
    Ok(())
}

/// Reads one RFC 6455 frame (handling fragmented text/binary continuations cleanly).
pub(crate) async fn read_ws_frame<R: AsyncRead + Unpin>(
    reader: &mut R,
) -> BistreResult<Option<(u8, Vec<u8>)>> {
    let mut head = [0_u8; 2];
    match reader.read_exact(&mut head).await {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(_) => {
            return Err(BistreError::with_detail(
                DiagnosticKey::ProviderStreamInterrupted,
                "ws_rx_hdr",
            ));
        }
    }
    let opcode = head[0] & 0x0F;
    let masked = (head[1] & 0x80) != 0;
    let mut len = u64::from(head[1] & 0x7F);
    if len == 126 {
        let mut ext = [0_u8; 2];
        reader.read_exact(&mut ext).await.map_err(|_| {
            BistreError::with_detail(DiagnosticKey::ProviderStreamInterrupted, "ws_rx_len16")
        })?;
        len = u64::from(u16::from_be_bytes(ext));
    } else if len == 127 {
        let mut ext = [0_u8; 8];
        reader.read_exact(&mut ext).await.map_err(|_| {
            BistreError::with_detail(DiagnosticKey::ProviderStreamInterrupted, "ws_rx_len64")
        })?;
        len = u64::from_be_bytes(ext);
    }
    let len_usize = usize::try_from(len).unwrap_or(usize::MAX);
    if len_usize > MAX_WS_FRAME_BYTES {
        return Err(BistreError::with_detail(
            DiagnosticKey::ProviderStreamInterrupted,
            "ws_frame_too_large",
        ));
    }
    let mut mask_key = [0_u8; 4];
    if masked {
        reader.read_exact(&mut mask_key).await.map_err(|_| {
            BistreError::with_detail(DiagnosticKey::ProviderStreamInterrupted, "ws_rx_mask")
        })?;
    }
    let mut payload = vec![0_u8; len_usize];
    if len_usize > 0 {
        reader.read_exact(&mut payload).await.map_err(|_| {
            BistreError::with_detail(DiagnosticKey::ProviderStreamInterrupted, "ws_rx_body")
        })?;
    }
    if masked {
        for (i, b) in payload.iter_mut().enumerate() {
            *b ^= mask_key[i & 3];
        }
    }
    Ok(Some((opcode, payload)))
}
