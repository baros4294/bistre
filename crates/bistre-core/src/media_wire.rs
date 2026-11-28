//! The media protocol's wire shapes (ADR-0019, Spec 02 §7): one internal form for
//! generated images, audio, and video, read from every provider's reply shape.
//!
//! - In a chat reply: Chat Completions `delta.images[].image_url.url` (data URLs) and
//!   `delta.audio` (`data` as 24 kHz 16-bit mono PCM chunks, `transcript` as the reply text);
//!   Gemini `generateContent` `inlineData` parts and Interactions `step.delta` media deltas.
//!   Thought parts are never kept.
//! - Image models: `POST /images` (`OpenRouter`) or `/images/generations` (`OpenAI`-shaped),
//!   `data[]` with `b64_json` or `url`.
//! - Video models are jobs: `POST /videos` (`OpenRouter`-shaped) or
//!   `/contents/generations/tasks` (`ModelArk`-shaped), polled until a terminal status.
//!   Gemini answers an Interactions request with `response_format: video` in one reply.
//!
//! Every reply is bounded: at most [`MAX_MEDIA_ITEMS`] files and [`MAX_MEDIA_BYTES`] in all.

use base64::Engine as _;
use bistre_protocol::{NodeRecord, NodeRole, ProviderDialect, StoredAttachment};

use crate::attachments::parse_node_attachments;
use serde_json::{Value, json};

use crate::registry::{Modality, ModalitySet};

/// Most files one reply keeps.
pub(crate) const MAX_MEDIA_ITEMS: usize = 16;
/// Most bytes of media one reply keeps, all files together.
pub(crate) const MAX_MEDIA_BYTES: usize = 64 * 1024 * 1024;
/// Chat Completions streams spoken replies as 16-bit mono PCM at this rate.
pub(crate) const CHAT_AUDIO_RATE_HZ: u32 = 24_000;

/// One generated file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GeneratedMedia {
    pub(crate) mime_type: String,
    pub(crate) bytes: Vec<u8>,
}

/// Where a generated file is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum MediaRef {
    Inline(GeneratedMedia),
    /// To download; `None` lets the bytes name their type.
    Url {
        url: String,
        mime_type: Option<String>,
    },
}

fn decode_b64(data: &str) -> Option<Vec<u8>> {
    base64::engine::general_purpose::STANDARD
        .decode(data.trim())
        .map_err(|err| tracing::debug!(%err, "media part is not base64"))
        .ok()
}

/// A `data:<mime>;base64,<data>` URL as a file; any other URL is left to download.
pub(crate) fn media_ref_of_url(url: &str, mime_type: Option<&str>) -> Option<MediaRef> {
    if let Some(rest) = url.strip_prefix("data:") {
        let (head, data) = rest.split_once(',')?;
        let mime = head.strip_suffix(";base64")?;
        return Some(MediaRef::Inline(GeneratedMedia {
            mime_type: mime.to_owned(),
            bytes: decode_b64(data)?,
        }));
    }
    (url.starts_with("https://") || url.starts_with("http://")).then(|| MediaRef::Url {
        url: url.to_owned(),
        mime_type: mime_type.map(ToOwned::to_owned),
    })
}

fn inline(mime: Option<&str>, data: Option<&str>) -> Option<MediaRef> {
    let mime = mime?;
    let kind = mime.split('/').next()?;
    if !matches!(kind, "image" | "audio" | "video") {
        return None;
    }
    Some(MediaRef::Inline(GeneratedMedia {
        mime_type: mime.to_owned(),
        bytes: decode_b64(data?)?,
    }))
}

/// Collects the media of one streamed chat reply.
#[derive(Debug, Default)]
pub(crate) struct MediaCollector {
    items: Vec<GeneratedMedia>,
    pcm: Vec<u8>,
    bytes: usize,
    /// Whether a file was left out by the bounds.
    pub(crate) dropped: bool,
}

impl MediaCollector {
    fn room_for(&mut self, len: usize) -> bool {
        let fits =
            self.items.len() < MAX_MEDIA_ITEMS && self.bytes.saturating_add(len) <= MAX_MEDIA_BYTES;
        if fits {
            self.bytes += len;
        } else {
            self.dropped = true;
        }
        fits
    }

    fn keep(&mut self, found: Option<MediaRef>) {
        // A chat reply's media is inline; a URL in a chat reply is not fetched.
        if let Some(MediaRef::Inline(media)) = found
            && self.room_for(media.bytes.len())
        {
            self.items.push(media);
        }
    }

    /// Reads one stream frame; returns the spoken reply's transcript text, if any.
    pub(crate) fn absorb(&mut self, dialect: ProviderDialect, frame: &Value) -> Option<String> {
        match dialect {
            ProviderDialect::CustomOpenAi | ProviderDialect::OpenAi => self.absorb_chat(frame),
            ProviderDialect::GoogleGemini => {
                self.absorb_gemini(frame);
                None
            }
            ProviderDialect::Anthropic => None,
        }
    }

    fn absorb_chat(&mut self, frame: &Value) -> Option<String> {
        let mut transcript = String::new();
        for choice in frame.get("choices").and_then(Value::as_array)? {
            let Some(delta) = choice.get("delta").or_else(|| choice.get("message")) else {
                continue;
            };
            for image in delta
                .get("images")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                let url = image
                    .get("image_url")
                    .and_then(|u| u.get("url"))
                    .and_then(Value::as_str);
                self.keep(url.and_then(|u| media_ref_of_url(u, None)));
            }
            if let Some(audio) = delta.get("audio") {
                if let Some(chunk) = audio
                    .get("data")
                    .and_then(Value::as_str)
                    .and_then(decode_b64)
                    && self.room_for(chunk.len())
                {
                    self.pcm.extend_from_slice(&chunk);
                }
                if let Some(t) = audio.get("transcript").and_then(Value::as_str) {
                    transcript.push_str(t);
                }
            }
        }
        (!transcript.is_empty()).then_some(transcript)
    }

    fn absorb_gemini(&mut self, frame: &Value) {
        if frame.get("event_type").and_then(Value::as_str) == Some("step.delta")
            && let Some(delta) = frame.get("delta")
        {
            let mime = delta.get("mime_type").and_then(Value::as_str);
            self.keep(inline(mime, delta.get("data").and_then(Value::as_str)));
            return;
        }
        let parts = frame
            .get("candidates")
            .and_then(|c| c.get(0))
            .and_then(|c| c.get("content"))
            .and_then(|c| c.get("parts"))
            .and_then(Value::as_array);
        for part in parts.into_iter().flatten() {
            if part.get("thought").and_then(Value::as_bool) == Some(true) {
                continue;
            }
            if let Some(data) = part.get("inlineData") {
                let mime = data.get("mimeType").and_then(Value::as_str);
                self.keep(inline(mime, data.get("data").and_then(Value::as_str)));
            }
        }
    }

    /// The reply's files; streamed PCM becomes one WAV file.
    pub(crate) fn finish(mut self) -> Vec<GeneratedMedia> {
        if !self.pcm.is_empty() {
            self.items.push(GeneratedMedia {
                mime_type: "audio/wav".to_owned(),
                bytes: crate::voice::wrap_pcm16_as_wav(&self.pcm, CHAT_AUDIO_RATE_HZ),
            });
        }
        self.items
    }
}

/// Chat Completions fields that ask a model for image or spoken output besides text.
pub(crate) fn chat_output_fields(
    media_out: ModalitySet,
    writes_text: bool,
    voice: Option<&str>,
) -> Vec<(&'static str, Value)> {
    let mut modalities = Vec::new();
    if media_out.contains(Modality::Image) {
        modalities.push("image");
    }
    if media_out.contains(Modality::Audio) {
        modalities.push("audio");
    }
    if modalities.is_empty() {
        return Vec::new();
    }
    if writes_text {
        modalities.push("text");
    }
    let mut fields = vec![("modalities", json!(modalities))];
    if media_out.contains(Modality::Audio) {
        let voice =
            crate::voice::voice_or_default(ProviderDialect::CustomOpenAi, voice.unwrap_or(""));
        fields.push(("audio", json!({ "voice": voice, "format": "pcm16" })));
    }
    fields
}

/// The user's media settings (`media_gen::MEDIA_OPTIONS_KEY`), each kept
/// only when the current model's catalog entry offers that value, so a setting made for
/// one model is never sent to another that does not take it.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub(crate) struct MediaPick {
    pub(crate) aspect_ratio: Option<String>,
    pub(crate) resolution: Option<String>,
    pub(crate) duration_s: Option<u32>,
}

/// Where a [`MediaPick`] goes in a request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PickWire {
    /// `OpenRouter` `/images`: `aspect_ratio`, `resolution`.
    Images,
    /// `OpenRouter` Chat Completions: `image_config.{aspect_ratio, image_size}`.
    ChatImage,
    /// Gemini Interactions: `response_format.{type: "image", aspect_ratio, image_size}`;
    /// the reply still carries text.
    GeminiImage,
    /// Gemini `generateContent`: `generationConfig.imageConfig.{aspectRatio, imageSize}`.
    GeminiContentImage,
    /// `/videos`: `aspect_ratio`, `resolution`, `duration` (seconds).
    Videos,
    /// `/contents/generations/tasks`: `ratio`, `resolution`, `duration` (seconds).
    Tasks,
    /// Gemini Interactions video: `response_format.{aspect_ratio, resolution, duration}`
    /// with the length as `"<n>s"`.
    GeminiVideo,
}

impl MediaPick {
    /// The values the model's catalog entry offers; the rest is dropped.
    pub(crate) fn for_model(&self, offered: Option<&crate::registry::ModelExtras>) -> Self {
        let Some(offered) = offered else {
            return Self::default();
        };
        let keep = |v: &Option<String>, list: &[String]| v.clone().filter(|v| list.contains(v));
        Self {
            aspect_ratio: keep(&self.aspect_ratio, &offered.aspect_ratios),
            resolution: keep(&self.resolution, &offered.resolutions),
            duration_s: self.duration_s.filter(|d| offered.durations_s.contains(d)),
        }
    }

    /// Writes the picked values into `body` in `wire`'s field names.
    pub(crate) fn apply(&self, wire: PickWire, body: &mut Value) {
        let (ratio, size) = (self.aspect_ratio.as_deref(), self.resolution.as_deref());
        let mut fields: Vec<(&str, Value)> = Vec::new();
        let (ratio_key, size_key) = match wire {
            PickWire::Images | PickWire::Videos | PickWire::GeminiVideo => {
                ("aspect_ratio", "resolution")
            }
            PickWire::ChatImage | PickWire::GeminiImage => ("aspect_ratio", "image_size"),
            PickWire::GeminiContentImage => ("aspectRatio", "imageSize"),
            PickWire::Tasks => ("ratio", "resolution"),
        };
        if let Some(r) = ratio {
            fields.push((ratio_key, json!(r)));
        }
        if let Some(r) = size {
            fields.push((size_key, json!(r)));
        }
        if let Some(d) = self
            .duration_s
            .filter(|_| matches!(wire, PickWire::Videos | PickWire::Tasks))
        {
            fields.push(("duration", json!(d)));
        }
        if let Some(d) = self.duration_s.filter(|_| wire == PickWire::GeminiVideo) {
            fields.push(("duration", json!(format!("{d}s"))));
        }
        if fields.is_empty() {
            return;
        }
        if wire == PickWire::GeminiImage {
            fields.push(("type", json!("image")));
        }
        let path: &[&str] = match wire {
            PickWire::Images | PickWire::Videos | PickWire::Tasks => &[],
            PickWire::ChatImage => &["image_config"],
            PickWire::GeminiContentImage => &["generationConfig", "imageConfig"],
            PickWire::GeminiImage | PickWire::GeminiVideo => &["response_format"],
        };
        let mut target = body.as_object_mut();
        for key in path {
            target = target.and_then(|map| {
                map.entry((*key).to_owned())
                    .or_insert_with(|| json!({}))
                    .as_object_mut()
            });
        }
        if let Some(map) = target {
            for (k, v) in fields {
                map.insert(k.to_owned(), v);
            }
        }
    }
}

/// Sends each reply's generated files back to the model the one way every dialect takes
/// media: as attachments of the next user message, for the kinds the catalog says the
/// model reads. A reply with files and no text gets a note naming them, since several
/// providers reject an empty assistant turn.
pub(crate) fn carry_generated_media(history: &mut [NodeRecord], reads: Option<ModalitySet>) {
    for i in 0..history.len() {
        if history[i].role != NodeRole::Assistant {
            continue;
        }
        let made = parse_node_attachments(history[i].provider_meta_json.as_deref());
        if made.is_empty() {
            continue;
        }
        if history[i].content.trim().is_empty() {
            let names: Vec<&str> = made.iter().map(|a| a.name.as_str()).collect();
            history[i].content = format!("[Generated files: {}]", names.join(", "));
        }
        let carried: Vec<StoredAttachment> = made
            .into_iter()
            .filter(|a| reads.is_some_and(|r| kind_of(&a.mime_type).is_some_and(|k| r.contains(k))))
            .collect();
        if carried.is_empty() {
            continue;
        }
        let Some(next) = history[i + 1..]
            .iter_mut()
            .find(|n| n.role == NodeRole::User)
        else {
            continue;
        };
        let mut meta = serde_json::Map::new();
        if let Some(raw) = next.provider_meta_json.as_deref() {
            let Ok(Value::Object(map)) = serde_json::from_str::<Value>(raw) else {
                tracing::warn!(node = %next.id, "message metadata unreadable; generated files not resent");
                continue;
            };
            meta = map;
        }
        let mut all = carried;
        all.extend(parse_node_attachments(next.provider_meta_json.as_deref()));
        meta.insert("attachments".to_owned(), json!(all));
        next.provider_meta_json = Some(Value::Object(meta).to_string());
    }
}

/// The kind of file a MIME type names, for the catalog's modality lists.
fn kind_of(mime_type: &str) -> Option<Modality> {
    match mime_type.split('/').next()? {
        "image" => Some(Modality::Image),
        "audio" => Some(Modality::Audio),
        "video" => Some(Modality::Video),
        _ => None,
    }
}

/// Which image API a provider speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ImageApi {
    /// `POST /images` with `input_references`.
    OpenRouter,
    /// `POST /images/generations`.
    OpenAi,
}

/// The path and body of one image request; `references` are data URLs of input images.
pub(crate) fn image_request(
    api: ImageApi,
    model: &str,
    prompt: &str,
    references: &[String],
) -> (&'static str, Value) {
    match api {
        ImageApi::OpenRouter => {
            let mut body = json!({ "model": model, "prompt": prompt });
            if !references.is_empty() {
                body["input_references"] = references
                    .iter()
                    .map(|url| json!({ "type": "image_url", "image_url": { "url": url } }))
                    .collect();
            }
            ("/images", body)
        }
        ImageApi::OpenAi => (
            "/images/generations",
            json!({ "model": model, "prompt": prompt, "n": 1 }),
        ),
    }
}

/// The files of an image reply (`data[]` with `b64_json` or `url`).
pub(crate) fn image_reply_media(reply: &Value) -> Vec<MediaRef> {
    reply
        .get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|item| {
            let mime = item
                .get("media_type")
                .or_else(|| item.get("mime_type"))
                .and_then(Value::as_str);
            if let Some(b64) = item.get("b64_json").and_then(Value::as_str) {
                return Some(MediaRef::Inline(GeneratedMedia {
                    mime_type: mime.unwrap_or("image/png").to_owned(),
                    bytes: decode_b64(b64)?,
                }));
            }
            media_ref_of_url(item.get("url").and_then(Value::as_str)?, mime)
        })
        .take(MAX_MEDIA_ITEMS)
        .collect()
}

/// Which video job API a provider speaks; an `OpenAI`-shaped provider that answers 404 on
/// one is tried on the next.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum VideoApi {
    /// `POST /videos`, poll `GET /videos/{id}`.
    Videos,
    /// `POST /contents/generations/tasks`, poll `GET /contents/generations/tasks/{id}`.
    Tasks,
}

impl VideoApi {
    pub(crate) const ORDER: [Self; 2] = [Self::Videos, Self::Tasks];

    /// The path and body that start a job; `first_frame` is a data URL.
    pub(crate) fn submit(
        self,
        model: &str,
        prompt: &str,
        first_frame: Option<&str>,
    ) -> (&'static str, Value) {
        match self {
            Self::Videos => {
                let mut body = json!({ "model": model, "prompt": prompt });
                if let Some(url) = first_frame {
                    body["frame_images"] = json!([{
                        "type": "image_url",
                        "image_url": { "url": url },
                        "frame_type": "first_frame",
                    }]);
                }
                ("/videos", body)
            }
            Self::Tasks => {
                let mut content = vec![json!({ "type": "text", "text": prompt })];
                if let Some(url) = first_frame {
                    content.push(json!({
                        "type": "image_url",
                        "image_url": { "url": url },
                        "role": "first_frame",
                    }));
                }
                (
                    "/contents/generations/tasks",
                    json!({ "model": model, "content": content }),
                )
            }
        }
    }

    pub(crate) fn poll_path(self, job_id: &str) -> String {
        match self {
            Self::Videos => format!("/videos/{job_id}"),
            Self::Tasks => format!("/contents/generations/tasks/{job_id}"),
        }
    }

    /// Where a finished job's file is when its status names none.
    pub(crate) fn content_path(self, job_id: &str) -> Option<String> {
        (self == Self::Videos).then(|| format!("/videos/{job_id}/content"))
    }
}

/// A video job's state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum JobState {
    Pending,
    Done {
        media: Vec<MediaRef>,
        /// What the provider says the job cost, in micro-USD.
        cost_micros: Option<i64>,
    },
    /// The provider's own words, bounded.
    Failed(String),
}

/// The id of a started job (`id`, or `OpenRouter`'s `polling_url` tail).
pub(crate) fn job_id(reply: &Value) -> Option<String> {
    reply
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| {
            !id.is_empty()
                && id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
        })
        .map(ToOwned::to_owned)
}

fn reported_cost_micros(reply: &Value) -> Option<i64> {
    let cost = reply.get("usage")?.get("cost")?;
    let text = match cost {
        Value::Number(n) => n.to_string(),
        Value::String(s) => s.clone(),
        _ => return None,
    };
    crate::registry::parse_decimal_scaled(&text, 6)
}

/// Reads a job's status: `completed`/`succeeded` is done; `failed`, `cancelled`,
/// `canceled`, and `expired` are failures; any other status is still running.
pub(crate) fn job_state(reply: &Value) -> JobState {
    let status = reply
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    match status.as_str() {
        "completed" | "succeeded" => {
            let urls = ["unsigned_urls", "urls"]
                .iter()
                .filter_map(|k| reply.get(*k).and_then(Value::as_array))
                .flatten()
                .filter_map(Value::as_str)
                .chain(
                    reply
                        .get("content")
                        .and_then(|c| c.get("video_url"))
                        .and_then(Value::as_str),
                );
            let mut media: Vec<MediaRef> = Vec::new();
            for url in urls {
                if let Some(found) = media_ref_of_url(url, None)
                    && !media.contains(&found)
                {
                    media.push(found);
                }
            }
            media.truncate(MAX_MEDIA_ITEMS);
            JobState::Done {
                media,
                cost_micros: reported_cost_micros(reply),
            }
        }
        "failed" | "cancelled" | "canceled" | "expired" => {
            let reason = reply
                .get("error")
                .map(|e| match e {
                    Value::String(s) => s.clone(),
                    other => other
                        .get("message")
                        .and_then(Value::as_str)
                        .map_or_else(|| other.to_string(), ToOwned::to_owned),
                })
                .unwrap_or(status);
            JobState::Failed(
                reason
                    .chars()
                    .take(crate::finish::MAX_REASON_CHARS)
                    .collect(),
            )
        }
        _ => JobState::Pending,
    }
}

/// The body of a Gemini Interactions request for a video.
pub(crate) fn gemini_video_request(
    model: &str,
    prompt: &str,
    first_frame: Option<&GeneratedMedia>,
) -> Value {
    let input = match first_frame {
        Some(frame) => json!([
            {
                "type": "image",
                "mime_type": frame.mime_type,
                "data": base64::engine::general_purpose::STANDARD.encode(&frame.bytes),
            },
            { "type": "text", "text": prompt },
        ]),
        None => Value::String(prompt.to_owned()),
    };
    json!({
        "model": model.strip_prefix("models/").unwrap_or(model),
        "input": input,
        "response_format": { "type": "video" },
    })
}

/// The media of a Gemini Interactions reply (`steps[]` of type `model_output`).
pub(crate) fn gemini_interaction_media(reply: &Value) -> Vec<MediaRef> {
    reply
        .get("steps")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|s| s.get("type").and_then(Value::as_str) != Some("thought"))
        .filter_map(|s| s.get("content").and_then(Value::as_array))
        .flatten()
        .filter_map(|block| {
            let mime = block.get("mime_type").and_then(Value::as_str);
            if let Some(uri) = block.get("uri").and_then(Value::as_str) {
                return media_ref_of_url(uri, mime);
            }
            inline(mime, block.get("data").and_then(Value::as_str))
        })
        .take(MAX_MEDIA_ITEMS)
        .collect()
}

/// The file extension for a generated file's type.
pub(crate) fn extension_for(mime: &str) -> &'static str {
    match mime
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "image/png" => "png",
        "image/jpeg" | "image/jpg" => "jpg",
        "image/webp" => "webp",
        "image/gif" => "gif",
        "audio/wav" | "audio/x-wav" | "audio/wave" => "wav",
        "audio/mpeg" | "audio/mp3" => "mp3",
        "audio/ogg" => "ogg",
        "video/mp4" => "mp4",
        "video/webm" => "webm",
        "video/quicktime" => "mov",
        _ => "bin",
    }
}

#[cfg(test)]
#[path = "media_wire_tests.rs"]
mod tests;
