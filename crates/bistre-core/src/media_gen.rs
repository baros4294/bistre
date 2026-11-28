//! Media-only models (ADR-0019, Spec 02 §7): a model the catalog says writes no text
//! answers a chat turn through its image, speech, or video API, and the files land on the
//! assistant reply as attachments.
//!
//! - The prompt is the latest user message; its images (or, when it has none, the images of
//!   the latest reply) go along when the catalog says the model reads images.
//! - Wallet Shield: the reservation is the catalog's price for one image, the text read
//!   aloud, or the longest video at the dearest per-second rate. An unpriced model follows
//!   the chat rule (blocked under a cap unless allowed once). Once a request is sent, a
//!   failure or a stop books the reservation: the provider may bill a job it accepted.
//! - A URL on the provider's own host is fetched with its key; any other URL goes through
//!   `PublicWebTransport` with no credentials.
//! - A video job is kept until it is fetched or the provider fails it (`media_jobs`): after a
//!   stop or a restart, Try again on the same message fetches that job, unbilled again.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, EngineEvent, MoneyMicros, NodeRole, ProviderDialect,
    ProviderProfile, RunStepKind, SpendPurpose, StoredAttachment, ToolRiskTier,
};
use bistre_storage::StorageHandle;
use serde_json::{Value, json};
use tokio::sync::broadcast;

use crate::credentials::{KeyRing, apply_auth_header, resolve_base_url};
use crate::engine_runs::StreamServices;
use crate::events::{emit, emit_logged, note_write};
use crate::media_wire::{
    GeneratedMedia, ImageApi, JobState, MAX_MEDIA_BYTES, MediaPick, MediaRef, PickWire, VideoApi,
    extension_for,
};
use crate::registry::{Modality, ModelRates};

/// How often a running video job is asked for its state.
const VIDEO_POLL_INTERVAL: Duration = Duration::from_secs(5);
/// Longest a video job may run before the turn gives up on it.
const VIDEO_JOB_DEADLINE: Duration = Duration::from_mins(30);
/// Longest one image, speech, or status request may take.
const MEDIA_REQUEST_TIMEOUT: Duration = Duration::from_mins(5);

/// Which media API answers a model that writes no text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MediaRoute {
    Image,
    Video,
    Speech,
}

impl MediaRoute {
    /// By what the model writes: video, else image, else audio. Gemini image models answer
    /// in chat (`generateContent` image parts), and Anthropic writes no media.
    pub(crate) fn of(dialect: ProviderDialect, rates: Option<&ModelRates>) -> Option<Self> {
        let out = rates?.output_modalities?;
        if out.contains(Modality::Text) || dialect == ProviderDialect::Anthropic {
            return None;
        }
        if out.contains(Modality::Video) {
            Some(Self::Video)
        } else if out.contains(Modality::Image) {
            (dialect != ProviderDialect::GoogleGemini).then_some(Self::Image)
        } else if out.contains(Modality::Audio) {
            Some(Self::Speech)
        } else {
            None
        }
    }
}

/// `OpenAI`'s Responses API writes no audio: a model that speaks is sent to Chat Completions
/// on the same host.
pub(crate) fn chat_wire_for(
    provider: ProviderProfile,
    rates: Option<&ModelRates>,
) -> ProviderProfile {
    let speaks = rates
        .and_then(|r| r.output_modalities)
        .is_some_and(|m| m.contains(Modality::Audio));
    if speaks && provider.dialect == ProviderDialect::OpenAi {
        let base_url = resolve_base_url(provider.dialect, &provider.base_url);
        return ProviderProfile {
            dialect: ProviderDialect::CustomOpenAi,
            base_url,
            ..provider
        };
    }
    provider
}

/// One media turn's fixed inputs.
pub(crate) struct MediaTurn<'a> {
    pub(crate) storage: &'a Arc<StorageHandle>,
    pub(crate) services: &'a StreamServices,
    pub(crate) events_tx: &'a broadcast::Sender<EngineEvent>,
    pub(crate) cancel_flag: &'a Arc<AtomicBool>,
    pub(crate) thread_id: &'a str,
    pub(crate) run_id: &'a str,
    pub(crate) parent_id: &'a str,
    pub(crate) provider: &'a ProviderProfile,
    pub(crate) keys: &'a KeyRing,
    pub(crate) model: &'a str,
    pub(crate) rates: ModelRates,
}

struct Request {
    prompt: String,
    /// The media settings this model offers.
    pick: MediaPick,
    /// Input images as `(mime, bytes)`.
    images: Vec<GeneratedMedia>,
}

/// Runs one media turn to its end and returns whether it was stopped.
pub(crate) async fn run(
    turn: &MediaTurn<'_>,
    route: MediaRoute,
) -> (bool, Option<String>, MoneyMicros) {
    let step = note_write(
        "run_step_record",
        turn.storage.record_run_step(
            turn.run_id.to_owned(),
            0,
            RunStepKind::LlmCall,
            turn.model.to_owned(),
            ToolRiskTier::Tier0ReadOnly,
            format!("{}:media:0", turn.run_id),
            "running".to_owned(),
            json!({ "model": turn.model, "provider": turn.provider.id, "route": format!("{route:?}") })
                .to_string(),
            "{}".to_owned(),
            0,
            None,
        ),
    );
    let started = std::time::Instant::now();
    let outcome = produce(turn, route).await;
    if route == MediaRoute::Video {
        note_video_job_end(turn, &outcome);
    }
    let (status, cancelled, failed, cost) = match outcome {
        Ok(Produced::Done(cost)) => ("completed", false, None, cost),
        Ok(Produced::Stopped(cost)) => ("cancelled", true, None, cost),
        Err((err, cost)) => {
            emit(
                turn.events_tx,
                EngineEvent::DiagnosticRaised {
                    key: err.key,
                    detail_code: err.detail_code.clone(),
                },
            );
            ("failed", false, Some(err.key.as_key().to_owned()), cost)
        }
    };
    if let Some(st) = step {
        note_write(
            "run_step_complete",
            turn.storage.complete_run_step(
                st.id,
                status.to_owned(),
                "{}".to_owned(),
                i64::try_from(started.elapsed().as_millis()).unwrap_or(i64::MAX),
            ),
        );
    }
    (cancelled, failed, cost)
}

enum Produced {
    Done(MoneyMicros),
    Stopped(MoneyMicros),
}

type Failure = (BistreError, MoneyMicros);

/// A fetched job, or one the provider failed, is dropped; a stopped or broken one is kept
/// as booked, since its cost was just settled, for Try again to fetch.
fn note_video_job_end(turn: &MediaTurn<'_>, outcome: &Result<Produced, Failure>) {
    let resolved = match outcome {
        Ok(Produced::Done(_)) => true,
        Ok(Produced::Stopped(_)) => false,
        Err((err, _)) => err
            .detail_code
            .as_deref()
            .is_some_and(|d| d.starts_with("media_job_failed")),
    };
    let noted = if resolved {
        crate::media_jobs::forget(turn.storage, turn.parent_id)
    } else {
        crate::media_jobs::mark_booked(turn.storage, turn.parent_id)
    };
    if let Err(err) = noted {
        tracing::warn!(key = err.key.as_key(), "video job record not updated");
    }
}

fn fail(key: DiagnosticKey, detail: impl Into<String>) -> BistreError {
    BistreError::with_detail(key, detail.into())
}

async fn produce(turn: &MediaTurn<'_>, route: MediaRoute) -> Result<Produced, Failure> {
    let request = build_request(turn).map_err(|e| (e, MoneyMicros::ZERO))?;
    let estimate = match route {
        MediaRoute::Image => turn.rates.image_cost(1),
        MediaRoute::Video => turn.rates.video_cost_for(request.pick.duration_s),
        MediaRoute::Speech => turn
            .rates
            .speech_cost(u64::try_from(request.prompt.chars().count()).unwrap_or(u64::MAX)),
    };
    // A kept job was booked when it was cut off: fetching it reserves nothing more.
    let resumed = if route == MediaRoute::Video {
        crate::media_jobs::resumable(
            turn.storage,
            turn.parent_id,
            &turn.provider.id,
            turn.model,
            crate::turn_context::utc_now_unix_ms(),
        )
        .map_err(|e| (e, MoneyMicros::ZERO))?
    } else {
        None
    };
    let reservation = match resumed {
        Some(_) => None,
        None => reserve(turn, estimate).map_err(|e| (e, MoneyMicros::ZERO))?,
    };
    let booked = resumed.as_ref().map_or_else(
        || estimate.unwrap_or(MoneyMicros::ZERO),
        |j| MoneyMicros::from_micros(j.booked_micros),
    );
    let key = turn
        .keys
        .rotation()
        .first()
        .copied()
        .unwrap_or("")
        .to_owned();
    if key.is_empty() && !crate::net::is_loopback_url(&turn.provider.base_url) {
        return Err((
            BistreError::new(DiagnosticKey::ProviderNotConfigured),
            MoneyMicros::ZERO,
        ));
    }
    let sent = AtomicBool::new(resumed.is_some());
    let work = generate(turn, route, &request, &key, &sent, resumed.as_ref());
    let result = tokio::select! {
        r = work => Some(r),
        () = crate::providers::until_cancelled(turn.cancel_flag) => None,
    };
    let mut reservation = reservation;
    let mut settle = |cost: MoneyMicros, status: &str| {
        if let Some(r) = reservation.take()
            && let Err(err) = r.settle_for_request(
                Some(format!("{}:media:0", turn.run_id)),
                cost,
                0,
                0,
                status.to_owned(),
            )
        {
            tracing::error!(key = err.key.as_key(), "wallet spend record failed");
        }
    };
    let was_sent = sent.load(Ordering::SeqCst);
    let sent_cost = if was_sent { booked } else { MoneyMicros::ZERO };
    match result {
        None => {
            if was_sent {
                settle(sent_cost, "cancelled");
            }
            Ok(Produced::Stopped(sent_cost))
        }
        Some(Err(err)) => {
            if was_sent {
                settle(sent_cost, "unconfirmed");
            }
            Err((err, sent_cost))
        }
        Some(Ok((media, reported))) => {
            let reported = reported.filter(|_| resumed.is_none());
            let cost = reported.unwrap_or(booked);
            let committed = store_media(turn, media).and_then(|stored| {
                commit_reply(
                    turn,
                    &stored,
                    cost,
                    estimate.is_some() || reported.is_some(),
                )
            });
            match committed {
                Ok(()) => {
                    settle(
                        cost,
                        if reported.is_some() {
                            "settled"
                        } else {
                            "estimated"
                        },
                    );
                    Ok(Produced::Done(cost))
                }
                Err(err) => {
                    settle(cost, "unconfirmed");
                    Err((err, cost))
                }
            }
        }
    }
}

/// The latest user message and its images (else the latest reply's images, so "make it
/// bluer" edits the last picture).
fn build_request(turn: &MediaTurn<'_>) -> BistreResult<Request> {
    let branch = turn.storage.list_branch(turn.thread_id, turn.parent_id)?;
    let user = branch
        .iter()
        .rev()
        .find(|n| n.role == NodeRole::User)
        .ok_or_else(|| fail(DiagnosticKey::InvalidInput, "media_prompt_missing"))?;
    let prompt = user.content.trim().to_owned();
    let reads_images = turn
        .rates
        .input_modalities
        .is_some_and(|m| m.contains(Modality::Image));
    let images_of = |node: &bistre_protocol::NodeRecord| -> Vec<GeneratedMedia> {
        crate::attachments::parse_node_attachments(node.provider_meta_json.as_deref())
            .iter()
            .filter(|a| a.mime_type.starts_with("image/"))
            .filter_map(|a| {
                let bytes = crate::off_worker::in_place(|| {
                    crate::attachments::read_attachment_bytes(
                        &turn.services.data_dir,
                        a,
                        crate::attachments::MAX_INLINE_BYTES,
                    )
                })?;
                Some(GeneratedMedia {
                    mime_type: a.mime_type.clone(),
                    bytes,
                })
            })
            .collect()
    };
    let mut images = Vec::new();
    if reads_images {
        images = images_of(user);
        if images.is_empty()
            && let Some(reply) = branch.iter().rev().find(|n| n.role == NodeRole::Assistant)
        {
            images = images_of(reply);
        }
    }
    if prompt.is_empty() && images.is_empty() {
        return Err(fail(DiagnosticKey::InvalidInput, "media_prompt_empty"));
    }
    let pick = load_media_pick(turn.storage)
        .for_model(turn.services.pricing.snapshot().extras(turn.model));
    Ok(Request {
        prompt,
        pick,
        images,
    })
}

/// Where the media settings are kept: one choice for every chat, like the thinking level.
pub(crate) const MEDIA_OPTIONS_KEY: &str = "settings.media_options";

/// The media settings as saved; a malformed value reads as none (provider defaults) and is
/// logged.
pub(crate) fn load_media_pick(storage: &StorageHandle) -> MediaPick {
    match storage.get_kv_meta(MEDIA_OPTIONS_KEY) {
        Ok(Some(raw)) => serde_json::from_str(&raw).unwrap_or_else(|err| {
            tracing::warn!(%err, "media settings unreadable; provider defaults used");
            MediaPick::default()
        }),
        Ok(None) => MediaPick::default(),
        Err(err) => {
            tracing::warn!(key = err.key.as_key(), "media settings lookup failed");
            MediaPick::default()
        }
    }
}

fn reserve(
    turn: &MediaTurn<'_>,
    estimate: Option<MoneyMicros>,
) -> BistreResult<Option<crate::wallet::SpendReservation>> {
    if crate::net::is_loopback_url(&turn.provider.base_url) {
        return Ok(None);
    }
    let settings = turn.storage.load_settings().map_err(|err| {
        BistreError::with_detail(DiagnosticKey::WalletCheckUnavailable, err.key.as_key())
    })?;
    let chat_cap = crate::provider_prefs::load_thread_spend_limit(turn.storage, turn.thread_id)?;
    let capped = settings.wallet_daily_ceiling_micros.is_some() || chat_cap.is_some();
    if estimate.is_none()
        && capped
        && !crate::turn_context::unpriced_allowed(turn.services, turn.thread_id)
    {
        return Err(fail(DiagnosticKey::WalletPriceUnknown, "price_unknown"));
    }
    crate::wallet::SpendReservation::reserve_with_chat_cap(
        turn.storage,
        Some(turn.thread_id.to_owned()),
        turn.provider.id.clone(),
        turn.model.to_owned(),
        estimate.unwrap_or(MoneyMicros::ZERO),
        settings.wallet_daily_ceiling_micros,
        crate::turn_context::utc_day_start_unix_ms(),
        chat_cap,
        SpendPurpose::Chat,
    )
    .map(Some)
}

fn data_url(media: &GeneratedMedia) -> String {
    use base64::Engine as _;
    format!(
        "data:{};base64,{}",
        media.mime_type,
        base64::engine::general_purpose::STANDARD.encode(&media.bytes)
    )
}

type Generated = (Vec<GeneratedMedia>, Option<MoneyMicros>);

async fn generate(
    turn: &MediaTurn<'_>,
    route: MediaRoute,
    request: &Request,
    key: &str,
    sent: &AtomicBool,
    resumed: Option<&crate::media_jobs::VideoJob>,
) -> BistreResult<Generated> {
    let provider = turn.provider;
    let base = resolve_base_url(provider.dialect, &provider.base_url);
    let openrouter = bistre_protocol::dialect::is_openrouter_base(&base);
    let first_frame = request.images.first();
    let refs: Vec<MediaRef> = match (route, provider.dialect) {
        (MediaRoute::Speech, _) => {
            let voice = turn
                .services
                .pricing
                .snapshot()
                .voice(turn.model)
                .map(ToOwned::to_owned);
            sent.store(true, Ordering::SeqCst);
            let audio = crate::voice::synthesize_speech(
                &turn.services.http,
                provider,
                turn.keys,
                turn.model,
                &request.prompt,
                voice.as_deref(),
            )
            .await?;
            vec![MediaRef::Inline(GeneratedMedia {
                mime_type: crate::mime_sniff::sniff(&audio)
                    .unwrap_or("audio/wav")
                    .to_owned(),
                bytes: audio,
            })]
        }
        (MediaRoute::Video, ProviderDialect::GoogleGemini) => {
            let root = ProviderDialect::GoogleGemini.api_root(&base);
            let mut body =
                crate::media_wire::gemini_video_request(turn.model, &request.prompt, first_frame);
            request.pick.apply(PickWire::GeminiVideo, &mut body);
            sent.store(true, Ordering::SeqCst);
            let reply = send_json(
                turn,
                key,
                &format!("{root}/v1beta/interactions"),
                Some(&body),
                VIDEO_JOB_DEADLINE,
            )
            .await?;
            crate::media_wire::gemini_interaction_media(&reply)
        }
        (MediaRoute::Video, _) => {
            let started = match resumed {
                Some(j) => (j.api, j.job.clone(), JobState::Pending),
                None => submit_video_job(turn, &base, key, request, openrouter, sent).await?,
            };
            return await_video_job(turn, &base, key, started).await;
        }
        (MediaRoute::Image, _) => {
            let api = if openrouter {
                ImageApi::OpenRouter
            } else {
                ImageApi::OpenAi
            };
            let references: Vec<String> = request.images.iter().map(data_url).collect();
            let (path, mut body) =
                crate::media_wire::image_request(api, turn.model, &request.prompt, &references);
            if api == ImageApi::OpenRouter {
                request.pick.apply(PickWire::Images, &mut body);
            }
            sent.store(true, Ordering::SeqCst);
            let reply = send_json(
                turn,
                key,
                &format!("{base}{path}"),
                Some(&body),
                MEDIA_REQUEST_TIMEOUT,
            )
            .await?;
            crate::media_wire::image_reply_media(&reply)
        }
    };
    let media = download_all(turn, key, refs).await?;
    Ok((media, None))
}

/// Starts a video job and keeps it (`media_jobs`) until its turn resolves it.
async fn submit_video_job(
    turn: &MediaTurn<'_>,
    base: &str,
    key: &str,
    request: &Request,
    openrouter: bool,
    sent: &AtomicBool,
) -> BistreResult<(VideoApi, String, JobState)> {
    let frame = request.images.first().map(data_url);
    let apis: &[VideoApi] = if openrouter {
        &VideoApi::ORDER[..1]
    } else {
        &VideoApi::ORDER
    };
    let mut started = None;
    for api in apis {
        let (path, mut body) = api.submit(turn.model, &request.prompt, frame.as_deref());
        let wire = match api {
            VideoApi::Videos => PickWire::Videos,
            VideoApi::Tasks => PickWire::Tasks,
        };
        request.pick.apply(wire, &mut body);
        sent.store(true, Ordering::SeqCst);
        match send_json(
            turn,
            key,
            &format!("{base}{path}"),
            Some(&body),
            MEDIA_REQUEST_TIMEOUT,
        )
        .await
        {
            Ok(reply) => {
                started = Some((*api, reply));
                break;
            }
            // Not this API: an `OpenAI`-shaped provider without `/videos` may speak the next.
            Err(err)
                if matches!(
                    err.detail_code.as_deref(),
                    Some("media_http_404" | "media_http_405")
                ) =>
            {
                sent.store(false, Ordering::SeqCst);
                tracing::debug!(?api, "video API not served; trying the next");
            }
            Err(err) => return Err(err),
        }
    }
    let (api, reply) = started.ok_or_else(|| {
        fail(
            DiagnosticKey::ProviderRequestFailed,
            "media_video_api_missing",
        )
    })?;
    let job = crate::media_wire::job_id(&reply)
        .ok_or_else(|| fail(DiagnosticKey::ProviderRequestFailed, "media_job_id_missing"))?;
    let kept = crate::media_jobs::keep(
        turn.storage,
        crate::media_jobs::VideoJob {
            run_id: turn.run_id.to_owned(),
            thread_id: turn.thread_id.to_owned(),
            parent_id: turn.parent_id.to_owned(),
            provider_id: turn.provider.id.clone(),
            model: turn.model.to_owned(),
            api,
            job: job.clone(),
            booked_micros: turn
                .rates
                .video_cost_for(request.pick.duration_s)
                .unwrap_or(MoneyMicros::ZERO)
                .as_micros(),
            started_ms: crate::turn_context::utc_now_unix_ms(),
            booked: false,
        },
    );
    if let Err(err) = kept {
        // The job still runs; only a restart before it ends would lose it.
        tracing::warn!(key = err.key.as_key(), "video job not kept");
    }
    Ok((api, job, crate::media_wire::job_state(&reply)))
}

/// Polls a started job until it ends, then fetches its files.
async fn await_video_job(
    turn: &MediaTurn<'_>,
    base: &str,
    key: &str,
    (api, job, mut state): (VideoApi, String, JobState),
) -> BistreResult<Generated> {
    let deadline = tokio::time::Instant::now() + VIDEO_JOB_DEADLINE;
    while state == JobState::Pending {
        if tokio::time::Instant::now() >= deadline {
            return Err(fail(
                DiagnosticKey::ProviderRequestFailed,
                "media_job_timeout",
            ));
        }
        tokio::time::sleep(VIDEO_POLL_INTERVAL).await;
        let status = send_json(
            turn,
            key,
            &format!("{base}{}", api.poll_path(&job)),
            None,
            MEDIA_REQUEST_TIMEOUT,
        )
        .await?;
        state = crate::media_wire::job_state(&status);
    }
    match state {
        JobState::Done {
            mut media,
            cost_micros,
        } => {
            if media.is_empty()
                && let Some(path) = api.content_path(&job)
            {
                media.push(MediaRef::Url {
                    url: format!("{base}{path}"),
                    mime_type: None,
                });
            }
            let files = download_all(turn, key, media).await?;
            Ok((files, cost_micros.map(MoneyMicros::from_micros)))
        }
        JobState::Failed(reason) => Err(fail(
            DiagnosticKey::ProviderRequestFailed,
            format!("media_job_failed;reason={reason}"),
        )),
        JobState::Pending => Err(fail(
            DiagnosticKey::ProviderRequestFailed,
            "media_job_timeout",
        )),
    }
}

fn provider_headers(turn: &MediaTurn<'_>, key: &str) -> reqwest::header::HeaderMap {
    let mut headers = reqwest::header::HeaderMap::new();
    apply_auth_header(turn.provider.dialect, key, &mut headers);
    headers
}

/// One JSON request to the provider (POST with a body, else GET); a non-2xx status is an
/// error named `media_http_<status>` with the provider's own words.
async fn send_json(
    turn: &MediaTurn<'_>,
    key: &str,
    url: &str,
    body: Option<&Value>,
    timeout: Duration,
) -> BistreResult<Value> {
    let http = &turn.services.http;
    let builder = match body {
        Some(b) => http.post(url).json(b),
        None => http.get(url),
    };
    let resp = builder
        .headers(provider_headers(turn, key))
        .timeout(timeout)
        .send()
        .await
        .map_err(|err| {
            tracing::debug!(%err, "media request failed to send");
            fail(DiagnosticKey::ProviderRequestFailed, "connect")
        })?;
    let status = resp.status().as_u16();
    let bytes = read_bounded(resp).await?;
    if !(200..300).contains(&status) {
        let words = crate::finish::provider_reason(&String::from_utf8_lossy(&bytes));
        let detail = match words {
            Some(w) => format!("media_http_{status};reason={w}"),
            None => format!("media_http_{status}"),
        };
        // The 404/405 API probe matches the bare code.
        let detail = if matches!(status, 404 | 405) {
            format!("media_http_{status}")
        } else {
            detail
        };
        return Err(fail(DiagnosticKey::ProviderRequestFailed, detail));
    }
    serde_json::from_slice(&bytes).map_err(|err| {
        tracing::debug!(%err, "media reply is not JSON");
        fail(
            DiagnosticKey::ProviderRequestFailed,
            "media_reply_unreadable",
        )
    })
}

async fn read_bounded(resp: reqwest::Response) -> BistreResult<Vec<u8>> {
    crate::http_clients::read_body_capped(
        resp,
        MAX_MEDIA_BYTES,
        fail(DiagnosticKey::ProviderStreamInterrupted, "media_read"),
        fail(DiagnosticKey::InvalidInput, "media_too_large"),
    )
    .await
}

fn same_host(a: &str, b: &str) -> bool {
    let host = |u: &str| {
        reqwest::Url::parse(u)
            .ok()
            .and_then(|u| u.host_str().map(str::to_ascii_lowercase))
    };
    host(a).is_some_and(|h| Some(h) == host(b))
}

async fn download_all(
    turn: &MediaTurn<'_>,
    key: &str,
    refs: Vec<MediaRef>,
) -> BistreResult<Vec<GeneratedMedia>> {
    let mut files = Vec::with_capacity(refs.len());
    let mut total = 0_usize;
    for r in refs {
        let file = match r {
            MediaRef::Inline(media) => media,
            MediaRef::Url { url, mime_type } => {
                let (bytes, served_type) = if same_host(&url, &turn.provider.base_url) {
                    let resp = turn
                        .services
                        .http
                        .get(&url)
                        .headers(provider_headers(turn, key))
                        .timeout(MEDIA_REQUEST_TIMEOUT)
                        .send()
                        .await
                        .map_err(|_| {
                            fail(DiagnosticKey::ProviderRequestFailed, "media_download")
                        })?;
                    if !resp.status().is_success() {
                        return Err(fail(
                            DiagnosticKey::ProviderRequestFailed,
                            format!("media_download_http_{}", resp.status().as_u16()),
                        ));
                    }
                    let served = resp
                        .headers()
                        .get(reqwest::header::CONTENT_TYPE)
                        .and_then(|v| v.to_str().ok())
                        .map(ToOwned::to_owned);
                    (read_bounded(resp).await?, served)
                } else {
                    let fetched = turn.services.web.get(&url, MAX_MEDIA_BYTES).await?;
                    if fetched.truncated || !(200..300).contains(&fetched.status) {
                        return Err(fail(
                            DiagnosticKey::ProviderRequestFailed,
                            format!("media_download_http_{}", fetched.status),
                        ));
                    }
                    (fetched.body, Some(fetched.content_type))
                };
                let sniffed = crate::mime_sniff::sniff(&bytes).map(ToOwned::to_owned);
                let mime_type = sniffed
                    .or(mime_type)
                    .or(served_type.filter(|t| !t.starts_with("application/")))
                    .unwrap_or_else(|| "application/octet-stream".to_owned());
                GeneratedMedia { mime_type, bytes }
            }
        };
        total = total.saturating_add(file.bytes.len());
        if total > MAX_MEDIA_BYTES {
            return Err(fail(DiagnosticKey::InvalidInput, "media_too_large"));
        }
        files.push(file);
    }
    if files.is_empty() {
        return Err(fail(
            DiagnosticKey::ProviderRequestFailed,
            "media_reply_empty",
        ));
    }
    Ok(files)
}

/// Stores generated files as attachments named by their content hash.
pub(crate) fn store_generated(
    data_dir: &std::path::Path,
    media: Vec<GeneratedMedia>,
) -> BistreResult<Vec<StoredAttachment>> {
    media
        .into_iter()
        .map(|m| {
            let hash = blake3::hash(&m.bytes).to_hex();
            let name = format!(
                "{}.{}",
                hash.get(..12).unwrap_or_default(),
                extension_for(&m.mime_type)
            );
            crate::attachments::store_attachment_bytes(data_dir, name, m.mime_type, &m.bytes)
        })
        .collect()
}

fn store_media(
    turn: &MediaTurn<'_>,
    media: Vec<GeneratedMedia>,
) -> BistreResult<Vec<StoredAttachment>> {
    store_generated(&turn.services.data_dir, media)
}

fn commit_reply(
    turn: &MediaTurn<'_>,
    attachments: &[StoredAttachment],
    cost: MoneyMicros,
    cost_known: bool,
) -> BistreResult<()> {
    let origin = crate::replay_policy::TurnOriginMeta {
        dialect: turn.provider.dialect,
        provider_id: turn.provider.id.clone(),
        model_id: turn.model.to_owned(),
        system_hash: String::new(),
        tools_hash: String::new(),
    };
    let meta = json!({
        "provider_id": turn.provider.id,
        "provider_name": turn.provider.name,
        "icon_slug": turn.provider.icon_slug,
        "model_id": turn.model,
        "cost_micros": cost.as_micros(),
        "cost_known": cost_known,
        "request_id": format!("{}:media:0", turn.run_id),
        "run_id": turn.run_id,
        "origin": origin,
        "attachments": attachments,
    });
    let node = turn.storage.append_node(
        turn.thread_id.to_owned(),
        Some(turn.parent_id.to_owned()),
        NodeRole::Assistant,
        String::new(),
        Some(meta.to_string()),
    )?;
    emit_logged(
        turn.storage,
        turn.events_tx,
        Some(turn.thread_id.to_owned()),
        EngineEvent::NodeCommitted { node },
    );
    Ok(())
}

#[cfg(test)]
#[path = "media_gen_tests.rs"]
mod tests;
