//! Typed views of the public model catalogs (Spec 03).
//!
//! Only the fields used here are read; every other field is skipped without allocating, so a
//! multi-megabyte list never becomes a full `serde_json::Value` tree. An entry or field of
//! unexpected shape is skipped instead of failing the whole list.

use std::collections::BTreeMap;

use serde::Deserialize;
use serde::de::IgnoredAny;

use crate::registry::{
    CatalogEntry, MAX_MEDIA_CHOICES, Modality, ModalitySet, ModelExtras, ModelRates,
    parse_decimal_scaled,
};

#[derive(Deserialize)]
#[serde(untagged)]
enum Lenient<T> {
    Parsed(T),
    Skipped(IgnoredAny),
}

impl<T> Lenient<T> {
    fn get(self) -> Option<T> {
        match self {
            Self::Parsed(v) => Some(v),
            Self::Skipped(_) => None,
        }
    }
}

type Field<T> = Option<Lenient<T>>;

fn field<T>(f: Field<T>) -> Option<T> {
    f.and_then(Lenient::get)
}

/// A price as JSON text or number; numbers are re-read from their shortest decimal text.
#[derive(Deserialize)]
#[serde(untagged)]
enum Decimal {
    Text(String),
    Number(serde_json::Number),
}

impl Decimal {
    fn scaled(&self, scale: u32) -> Option<i64> {
        match self {
            Self::Text(s) => parse_decimal_scaled(s, scale),
            Self::Number(n) => parse_decimal_scaled(&n.to_string(), scale),
        }
    }
}

/// Per-token USD price → micro-USD per 1M tokens (`× 10^12`); the same scale turns a
/// per-character price into micro-USD per 1M characters.
fn per_million(f: Field<Decimal>) -> Option<i64> {
    field(f).and_then(|d| d.scaled(12))
}

/// A USD price per unit (one image, one second) → micro-USD per unit (`× 10^6`).
fn per_unit(f: Field<Decimal>) -> Option<i64> {
    field(f).and_then(|d| d.scaled(6))
}

/// A non-negative JSON integer that fits `u32` (context limits).
fn count(f: Field<u64>) -> Option<u32> {
    field(f).and_then(|n| u32::try_from(n).ok())
}

fn modalities(names: Option<Vec<String>>) -> Option<ModalitySet> {
    names.map(|n| n.iter().map(String::as_str).collect())
}

#[derive(Deserialize)]
struct ListDoc {
    #[serde(default)]
    data: Vec<Lenient<ListItem>>,
}

#[derive(Deserialize)]
struct ListItem {
    id: String,
    pricing: Field<ListPricing>,
    context_length: Field<u64>,
    architecture: Field<Architecture>,
    top_provider: Field<TopProvider>,
    /// Request parameters the model accepts (`"reasoning"` when it can think).
    supported_parameters: Field<Vec<String>>,
    supported_voices: Field<Vec<String>>,
}

#[derive(Deserialize)]
struct Architecture {
    input_modalities: Field<Vec<String>>,
    output_modalities: Field<Vec<String>>,
}

#[derive(Deserialize)]
struct TopProvider {
    max_completion_tokens: Field<u64>,
}

#[derive(Deserialize)]
struct ListPricing {
    prompt: Field<Decimal>,
    completion: Field<Decimal>,
    input_cache_read: Field<Decimal>,
    input_cache_write: Field<Decimal>,
    input_cache_write_1h: Field<Decimal>,
}

#[derive(Deserialize)]
struct VideoDoc {
    #[serde(default)]
    data: Vec<Lenient<VideoItem>>,
}

#[derive(Deserialize)]
struct VideoItem {
    id: String,
    pricing_skus: Field<BTreeMap<String, Lenient<Decimal>>>,
    supported_durations: Field<Vec<i64>>,
    supported_aspect_ratios: Field<Vec<String>>,
    supported_resolutions: Field<Vec<String>>,
}

#[derive(Deserialize)]
struct ImageDoc {
    #[serde(default)]
    data: Vec<Lenient<ImageItem>>,
}

#[derive(Deserialize)]
struct ImageItem {
    id: String,
    architecture: Field<Architecture>,
    supported_parameters: Field<ImageParams>,
}

#[derive(Deserialize)]
struct ImageParams {
    aspect_ratio: Field<EnumParam>,
    resolution: Field<EnumParam>,
}

#[derive(Deserialize)]
struct EnumParam {
    values: Field<Vec<String>>,
}

/// A catalog's picture shape: `<w>:<h>` with plain decimals (`9:19.5`).
fn is_aspect_ratio(v: &str) -> bool {
    let number = |s: &str| {
        !s.is_empty()
            && s.len() <= 6
            && s.bytes().all(|b| b.is_ascii_digit() || b == b'.')
            && s.parse::<f64>().is_ok_and(|n| n > 0.0)
    };
    v.split_once(':')
        .is_some_and(|(w, h)| number(w) && number(h))
}

/// A catalog's size tier: letters, digits, and dots, at most 8 (`1K`, `1.5K`, `720p`).
fn is_resolution(v: &str) -> bool {
    !v.is_empty() && v.len() <= 8 && v.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.')
}

/// Keeps the valid values once each, in the catalog's order, bounded.
fn choices(values: Option<Vec<String>>, valid: fn(&str) -> bool) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for v in values.into_iter().flatten() {
        let v = v.trim().to_owned();
        if valid(&v) && !out.contains(&v) && out.len() < MAX_MEDIA_CHOICES {
            out.push(v);
        }
    }
    out
}

#[derive(Deserialize)]
struct LiteSpec {
    litellm_provider: Field<String>,
    mode: Field<String>,
    input_cost_per_token: Field<Decimal>,
    output_cost_per_token: Field<Decimal>,
    cache_read_input_token_cost: Field<Decimal>,
    cache_creation_input_token_cost: Field<Decimal>,
    cache_creation_input_token_cost_above_1hr: Field<Decimal>,
    input_cost_per_character: Field<Decimal>,
    /// USD per provider web search by search size (`search_context_size_low` and so on).
    search_context_cost_per_query: Field<BTreeMap<String, Decimal>>,
    code_interpreter_cost_per_session: Field<Decimal>,
    output_cost_per_image_token: Field<Decimal>,
    output_cost_per_audio_token: Field<Decimal>,
    output_cost_per_image: Field<Decimal>,
    output_cost_per_second: Field<Decimal>,
    output_cost_per_video_per_second: Field<Decimal>,
    #[serde(rename = "output_cost_per_second_480p")]
    per_second_480p: Field<Decimal>,
    #[serde(rename = "output_cost_per_second_720p")]
    per_second_720p: Field<Decimal>,
    #[serde(rename = "output_cost_per_second_1080p")]
    per_second_1080p: Field<Decimal>,
    #[serde(rename = "output_cost_per_second_2k")]
    per_second_2k: Field<Decimal>,
    #[serde(rename = "output_cost_per_second_4k")]
    per_second_4k: Field<Decimal>,
    max_input_tokens: Field<u64>,
    max_tokens: Field<u64>,
    max_output_tokens: Field<u64>,
    supports_reasoning: Field<bool>,
    supports_vision: Field<bool>,
    supports_audio_input: Field<bool>,
    supports_audio_output: Field<bool>,
    supports_pdf_input: Field<bool>,
    supported_modalities: Field<Vec<String>>,
    supported_output_modalities: Field<Vec<String>>,
}

/// Parses one source's raw JSON; an unreadable list yields none.
pub fn parse_source(source: &str, body: &[u8]) -> Vec<CatalogEntry> {
    let parsed = match source {
        "openrouter" => parse_openrouter(body),
        "openrouter_videos" => parse_openrouter_videos(body),
        "openrouter_images" => parse_openrouter_images(body),
        "litellm" => parse_litellm(body),
        _ => return Vec::new(),
    };
    parsed.unwrap_or_else(|err| {
        tracing::warn!(source, %err, "price list unreadable");
        Vec::new()
    })
}

/// A model with no text output may lack token prices (it is billed per image, second, or
/// character); a model that writes text needs both token prices to be priced at all.
fn token_rates(
    output: Option<ModalitySet>,
    input: Option<i64>,
    out: Option<i64>,
) -> Option<(i64, i64)> {
    match (input, out) {
        (Some(i), Some(o)) => Some((i, o)),
        _ if output.is_some_and(|m| !m.contains(Modality::Text)) => {
            Some((input.unwrap_or(0), out.unwrap_or(0)))
        }
        _ => None,
    }
}

fn parse_openrouter(body: &[u8]) -> serde_json::Result<Vec<CatalogEntry>> {
    let doc: ListDoc = serde_json::from_slice(body)?;
    Ok(doc
        .data
        .into_iter()
        .filter_map(Lenient::get)
        .filter_map(|item| {
            let p = field(item.pricing)?;
            let arch = field(item.architecture);
            let (input_mods, output_mods) = arch.map_or((None, None), |a| {
                (
                    modalities(field(a.input_modalities)),
                    modalities(field(a.output_modalities)),
                )
            });
            let (input, output) = token_rates(
                output_mods,
                per_million(p.prompt),
                per_million(p.completion),
            )?;
            let reasoning =
                field(item.supported_parameters).map(|f| f.iter().any(|t| t == "reasoning"));
            let rates = ModelRates {
                input_per_mtok: input,
                output_per_mtok: output,
                cached_input_per_mtok: per_million(p.input_cache_read),
                cache_write_per_mtok: per_million(p.input_cache_write),
                cache_write_1h_per_mtok: per_million(p.input_cache_write_1h),
                context_tokens: count(item.context_length).filter(|&c| c > 0),
                reasoning,
                max_output_tokens: field(item.top_provider)
                    .and_then(|t| count(t.max_completion_tokens))
                    .filter(|&c| c > 0),
                input_modalities: input_mods,
                output_modalities: output_mods,
                ..ModelRates::default()
            };
            Some(CatalogEntry {
                namespace: Some("openrouter".to_owned()),
                id: item.id,
                rates,
                extras: ModelExtras {
                    voice: field(item.supported_voices).and_then(|v| v.into_iter().next()),
                    ..ModelExtras::default()
                },
            })
        })
        .collect())
}

/// Per-second SKUs are the keys naming a second; `cents_` keys are in US cents. The reserve
/// uses the dearest one (an upper bound over resolutions and audio on or off).
fn dearest_per_second_micros(skus: BTreeMap<String, Lenient<Decimal>>) -> Option<i64> {
    skus.into_iter()
        .filter(|(key, _)| key.contains("second"))
        .filter_map(|(key, value)| {
            let price = value.get()?;
            if key.starts_with("cents_") {
                price.scaled(4)
            } else {
                price.scaled(6)
            }
        })
        .max()
}

fn parse_openrouter_videos(body: &[u8]) -> serde_json::Result<Vec<CatalogEntry>> {
    let doc: VideoDoc = serde_json::from_slice(body)?;
    Ok(doc
        .data
        .into_iter()
        .filter_map(Lenient::get)
        .map(|item| {
            // A negative length (`-1`) means the model picks; it is no choice.
            let mut lengths: Vec<u32> = field(item.supported_durations)
                .into_iter()
                .flatten()
                .filter_map(|s| u32::try_from(s).ok().filter(|&s| s > 0))
                .collect();
            lengths.sort_unstable();
            lengths.dedup();
            lengths.truncate(MAX_MEDIA_CHOICES);
            let longest = lengths.last().copied();
            CatalogEntry {
                namespace: Some("openrouter".to_owned()),
                id: item.id,
                rates: ModelRates {
                    per_video_second_micros: field(item.pricing_skus)
                        .and_then(dearest_per_second_micros),
                    max_video_seconds: longest,
                    output_modalities: Some(ModalitySet::of(&[Modality::Video])),
                    ..ModelRates::default()
                },
                extras: ModelExtras {
                    aspect_ratios: choices(field(item.supported_aspect_ratios), is_aspect_ratio),
                    resolutions: choices(field(item.supported_resolutions), is_resolution),
                    durations_s: lengths,
                    voice: None,
                },
            }
        })
        .collect())
}

fn parse_openrouter_images(body: &[u8]) -> serde_json::Result<Vec<CatalogEntry>> {
    let doc: ImageDoc = serde_json::from_slice(body)?;
    Ok(doc
        .data
        .into_iter()
        .filter_map(Lenient::get)
        .map(|item| {
            let arch = field(item.architecture);
            let (input_mods, output_mods) = arch.map_or((None, None), |a| {
                (
                    modalities(field(a.input_modalities)),
                    modalities(field(a.output_modalities)),
                )
            });
            let params = field(item.supported_parameters);
            let values = |p: Option<EnumParam>| p.and_then(|e| field(e.values));
            let (ratios, sizes) = params.map_or((None, None), |p| {
                (values(field(p.aspect_ratio)), values(field(p.resolution)))
            });
            // This list has no prices: a model that also writes text gets only its choices
            // here, never a zero token price.
            let media_only = output_mods.is_some_and(|m| !m.contains(Modality::Text));
            let rates = if media_only {
                ModelRates {
                    input_modalities: input_mods,
                    output_modalities: output_mods,
                    ..ModelRates::default()
                }
            } else {
                ModelRates::default()
            };
            CatalogEntry {
                namespace: Some("openrouter".to_owned()),
                id: item.id,
                rates,
                extras: ModelExtras {
                    aspect_ratios: choices(ratios, is_aspect_ratio),
                    resolutions: choices(sizes, is_resolution),
                    ..ModelExtras::default()
                },
            }
        })
        .collect())
}

/// Output kinds from `LiteLLM`'s `mode` when the entry has no modality list.
fn litellm_mode_output(mode: &str, audio_out: bool) -> Option<ModalitySet> {
    let one = |m| Some(ModalitySet::of(&[m]));
    match mode {
        "chat" | "responses" | "completion" if audio_out => {
            Some(ModalitySet::of(&[Modality::Text, Modality::Audio]))
        }
        "chat" | "responses" | "completion" | "audio_transcription" => one(Modality::Text),
        "image_generation" | "image_edit" => one(Modality::Image),
        "video_generation" => one(Modality::Video),
        "audio_speech" => one(Modality::Audio),
        _ => None,
    }
}

fn litellm_entry(key: String, spec: LiteSpec) -> Option<CatalogEntry> {
    let flag = |f: Field<bool>| field(f) == Some(true);
    let audio_out = flag(spec.supports_audio_output);
    let output_mods = modalities(field(spec.supported_output_modalities)).or_else(|| {
        field(spec.mode)
            .as_deref()
            .and_then(|m| litellm_mode_output(m, audio_out))
    });
    let input_mods = modalities(field(spec.supported_modalities)).or_else(|| {
        let mut set = ModalitySet::of(&[Modality::Text]);
        for (on, m) in [
            (flag(spec.supports_vision), Modality::Image),
            (flag(spec.supports_audio_input), Modality::Audio),
            (flag(spec.supports_pdf_input), Modality::File),
        ] {
            if on {
                set.insert(m);
            }
        }
        Some(set)
    });
    let (input, output) = token_rates(
        output_mods,
        per_million(spec.input_cost_per_token),
        per_million(spec.output_cost_per_token),
    )?;
    let per_second = [
        spec.output_cost_per_second,
        spec.output_cost_per_video_per_second,
        spec.per_second_480p,
        spec.per_second_720p,
        spec.per_second_1080p,
        spec.per_second_2k,
        spec.per_second_4k,
    ]
    .into_iter()
    .filter_map(per_unit)
    .max();
    let video = output_mods.is_some_and(|m| m.contains(Modality::Video));
    let namespace = field(spec.litellm_provider).map(|p| p.to_ascii_lowercase());
    Some(CatalogEntry {
        namespace,
        id: key,
        rates: ModelRates {
            input_per_mtok: input,
            output_per_mtok: output,
            cached_input_per_mtok: per_million(spec.cache_read_input_token_cost),
            cache_write_per_mtok: per_million(spec.cache_creation_input_token_cost),
            cache_write_1h_per_mtok: per_million(spec.cache_creation_input_token_cost_above_1hr),
            context_tokens: count(spec.max_input_tokens).or(count(spec.max_tokens)),
            reasoning: field(spec.supports_reasoning),
            max_output_tokens: count(spec.max_output_tokens),
            input_modalities: input_mods,
            output_modalities: output_mods,
            per_image_micros: per_unit(spec.output_cost_per_image),
            per_video_second_micros: per_second.filter(|_| video),
            per_mchar_micros: per_million(spec.input_cost_per_character),
            per_search_micros: field(spec.search_context_cost_per_query)
                .and_then(|sizes| sizes.values().filter_map(|d| d.scaled(6)).max()),
            per_code_session_micros: per_unit(spec.code_interpreter_cost_per_session),
            image_output_per_mtok: per_million(spec.output_cost_per_image_token),
            audio_output_per_mtok: per_million(spec.output_cost_per_audio_token),
            ..ModelRates::default()
        },
        extras: ModelExtras::default(),
    })
}

fn parse_litellm(body: &[u8]) -> serde_json::Result<Vec<CatalogEntry>> {
    let doc: BTreeMap<String, Lenient<LiteSpec>> = serde_json::from_slice(body)?;
    Ok(doc
        .into_iter()
        .filter_map(|(id, spec)| litellm_entry(id, spec.get()?))
        .collect())
}
