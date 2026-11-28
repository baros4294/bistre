//! Live model catalog (Spec 03 / Spec 06): prices, limits, and modalities, never hardcoded.
//!
//! - Sources, in order: `OpenRouter`'s full model list (every output modality), its video
//!   price list, then `LiteLLM`. Earlier sources win; later ones only fill gaps. Each source is
//!   published incrementally through a `tokio::sync::watch` channel.
//! - Lookups are scoped to the provider that serves the model: its own catalog namespace
//!   (`openrouter`, `gemini`, or the API host's name, which is how `LiteLLM` names providers)
//!   comes first, then the plain id, then the id without its `vendor/` prefix as the model's
//!   maker lists it. A reseller's entry (`azure/eu/x`) never prices a model it does not serve.
//! - `24 h` freshness TTL, `60 s` cooldown after a sync that produced nothing. Syncs start only
//!   at engine start (when `pricing_auto_refresh` is on) or on an explicit refresh, never from
//!   a run, and the merged table is cached on disk with a format version.
//! - Callers may wait up to `2.5 s` for one model's rate; waiting never cancels the download.
//! - Every price is converted once, with integer math only, into `MoneyMicros` per one million
//!   tokens (or characters), per image, or per second; JSON floats are re-read from their
//!   shortest decimal text, never multiplied as `f64`.
//! - Catalog GETs carry no identifiers and go through `PublicWebTransport`.

use bistre_protocol::lock_or_recover;
use std::collections::{BTreeSet, HashMap};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bistre_protocol::{MoneyMicros, ProviderDialect, ProviderProfile};
use tokio::sync::watch;

pub use crate::registry_parse::parse_source;
use crate::ssrf::PublicWebTransport;

/// Freshness window for a successful sync.
pub const REGISTRY_TTL: Duration = Duration::from_hours(24);
/// Version of the on-disk price cache; a different version is ignored and rebuilt.
pub const PRICE_CACHE_FORMAT: u32 = 9;
/// Cooldown after a sync that yielded no rates.
pub const REGISTRY_FAILURE_COOLDOWN: Duration = Duration::from_secs(60);
/// Maximum wait for one model's rate.
pub const REGISTRY_MODEL_WAIT: Duration = Duration::from_millis(2_500);
const MAX_CATALOG_BYTES: usize = 32 * 1024 * 1024;

/// Ordered catalog sources: (name, URL). `output_modalities=all` lists image, video, speech,
/// and transcription models too (the bare list holds text models only).
pub const PRICING_SOURCES: [(&str, &str); 4] = [
    (
        "openrouter",
        "https://openrouter.ai/api/v1/models?output_modalities=all",
    ),
    (
        "openrouter_images",
        "https://openrouter.ai/api/v1/images/models",
    ),
    (
        "openrouter_videos",
        "https://openrouter.ai/api/v1/videos/models",
    ),
    (
        "litellm",
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json",
    ),
];

/// One kind of content a model reads or writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Modality {
    Text,
    Image,
    Audio,
    Video,
    File,
}

impl Modality {
    const fn bit(self) -> u8 {
        match self {
            Self::Text => 1,
            Self::Image => 2,
            Self::Audio => 4,
            Self::Video => 8,
            Self::File => 16,
        }
    }

    /// A catalog's name for it (`speech` is spoken audio); other names (`embeddings`,
    /// `rerank`) are not content.
    fn from_catalog_name(name: &str) -> Option<Self> {
        match name.trim().to_ascii_lowercase().as_str() {
            "text" => Some(Self::Text),
            "image" => Some(Self::Image),
            "audio" | "speech" => Some(Self::Audio),
            "video" => Some(Self::Video),
            "file" | "pdf" => Some(Self::File),
            _ => None,
        }
    }
}

/// A set of [`Modality`] values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(transparent)]
pub struct ModalitySet(u8);

impl ModalitySet {
    #[must_use]
    pub fn of(items: &[Modality]) -> Self {
        let mut set = Self::default();
        for m in items {
            set.insert(*m);
        }
        set
    }

    pub fn insert(&mut self, m: Modality) {
        self.0 |= m.bit();
    }

    #[must_use]
    pub const fn contains(self, m: Modality) -> bool {
        self.0 & m.bit() != 0
    }
}

impl<'a> FromIterator<&'a str> for ModalitySet {
    fn from_iter<I: IntoIterator<Item = &'a str>>(names: I) -> Self {
        let mut set = Self::default();
        for m in names.into_iter().filter_map(Modality::from_catalog_name) {
            set.insert(m);
        }
        set
    }
}

/// Integer rates in micro-USD (per one million tokens unless the field says otherwise),
/// limits, and modalities of one model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct ModelRates {
    pub input_per_mtok: i64,
    pub output_per_mtok: i64,
    /// Cached-input (cache read) rate when the source reports one.
    pub cached_input_per_mtok: Option<i64>,
    /// Cache-write rate for the default (5-minute) TTL, when the source reports one.
    pub cache_write_per_mtok: Option<i64>,
    /// Cache-write rate for the 1-hour TTL, when the source reports one.
    pub cache_write_1h_per_mtok: Option<i64>,
    /// Separate reasoning-token rate when explicitly overridden per model.
    pub reasoning_per_mtok: Option<i64>,
    /// The model's conversation limit (context window) in tokens, when the source reports one.
    pub context_tokens: Option<u32>,
    /// Whether the model accepts a reasoning/thinking effort, when the source reports it.
    pub reasoning: Option<bool>,
    /// The thinking-effort levels the model accepts, when the source lists them.
    pub effort_levels: Option<crate::effort_levels::EffortSet>,
    /// The most tokens one reply may have, when the source reports it (Anthropic's
    /// required `max_tokens` comes from here, not a fixed number).
    pub max_output_tokens: Option<u32>,
    /// What the model reads, when the source says.
    pub input_modalities: Option<ModalitySet>,
    /// What the model writes, when the source says; it picks the request route (Spec 02 §7).
    pub output_modalities: Option<ModalitySet>,
    /// Micro-USD per generated image.
    pub per_image_micros: Option<i64>,
    /// Micro-USD per second of generated video (the dearest resolution).
    pub per_video_second_micros: Option<i64>,
    /// The longest video the model makes, in seconds.
    pub max_video_seconds: Option<u32>,
    /// Micro-USD per one million characters of text read aloud.
    pub per_mchar_micros: Option<i64>,
    /// Rate of a reply's picture tokens, when the source lists one apart from text.
    pub image_output_per_mtok: Option<i64>,
    /// Rate of a reply's sound tokens, when the source lists one apart from text.
    pub audio_output_per_mtok: Option<i64>,
    /// Micro-USD per provider web search (the dearest search size the source lists).
    pub per_search_micros: Option<i64>,
    /// Micro-USD per provider code session (`OpenAI` code interpreter container).
    pub per_code_session_micros: Option<i64>,
}

impl ModelRates {
    /// Fills fields this entry lacks from `other` (a later source or a prefix-less id).
    fn fill_gaps(&mut self, other: &Self) {
        self.cached_input_per_mtok = self.cached_input_per_mtok.or(other.cached_input_per_mtok);
        self.cache_write_per_mtok = self.cache_write_per_mtok.or(other.cache_write_per_mtok);
        self.cache_write_1h_per_mtok = self
            .cache_write_1h_per_mtok
            .or(other.cache_write_1h_per_mtok);
        self.reasoning_per_mtok = self.reasoning_per_mtok.or(other.reasoning_per_mtok);
        self.context_tokens = self.context_tokens.or(other.context_tokens);
        self.max_output_tokens = self.max_output_tokens.or(other.max_output_tokens);
        self.reasoning = self.reasoning.or(other.reasoning);
        self.effort_levels = self.effort_levels.or(other.effort_levels);
        self.input_modalities = self.input_modalities.or(other.input_modalities);
        self.output_modalities = self.output_modalities.or(other.output_modalities);
        self.per_image_micros = self.per_image_micros.or(other.per_image_micros);
        self.per_video_second_micros = self
            .per_video_second_micros
            .or(other.per_video_second_micros);
        self.max_video_seconds = self.max_video_seconds.or(other.max_video_seconds);
        self.per_mchar_micros = self.per_mchar_micros.or(other.per_mchar_micros);
        self.per_search_micros = self.per_search_micros.or(other.per_search_micros);
        self.image_output_per_mtok = self.image_output_per_mtok.or(other.image_output_per_mtok);
        self.audio_output_per_mtok = self.audio_output_per_mtok.or(other.audio_output_per_mtok);
        self.per_code_session_micros = self
            .per_code_session_micros
            .or(other.per_code_session_micros);
    }

    /// Whether the model writes text (an unknown model is treated as a text model).
    #[must_use]
    pub fn writes_text(&self) -> bool {
        self.output_modalities
            .is_none_or(|m| m.contains(Modality::Text))
    }

    /// Micro-USD for `images` generated images, when the catalog prices images.
    #[must_use]
    pub fn image_cost(&self, images: u32) -> Option<MoneyMicros> {
        self.per_image_micros
            .map(|p| MoneyMicros::from_micros(p.saturating_mul(i64::from(images))))
    }

    /// The most one video can cost: the dearest per-second rate times the chosen length,
    /// else the longest one.
    #[must_use]
    pub fn video_cost_for(&self, seconds: Option<u32>) -> Option<MoneyMicros> {
        let per_second = self.per_video_second_micros?;
        let seconds = seconds.or(self.max_video_seconds)?;
        Some(MoneyMicros::from_micros(
            per_second.saturating_mul(i64::from(seconds)),
        ))
    }

    /// Micro-USD to read `chars` characters aloud. A per-token price is applied per character,
    /// an upper bound (a token is at least one character).
    #[must_use]
    pub fn speech_cost(&self, chars: u64) -> Option<MoneyMicros> {
        let rate = self
            .per_mchar_micros
            .or(Some(self.input_per_mtok))
            .filter(|&r| r > 0)?;
        let total = u128::from(chars) * u128::try_from(rate).ok()? / 1_000_000;
        Some(MoneyMicros::from_micros(
            i64::try_from(total).unwrap_or(i64::MAX),
        ))
    }

    /// Exact cost; cached input tokens are billed at the cached rate when known.
    pub fn cost(
        &self,
        input_tokens: u64,
        cached_input_tokens: u64,
        output_tokens: u64,
    ) -> MoneyMicros {
        let cached = cached_input_tokens.min(input_tokens);
        let fresh = input_tokens - cached;
        let rate = |r: i64| u128::try_from(r).unwrap_or(0);
        let total = u128::from(fresh) * rate(self.input_per_mtok)
            + u128::from(cached) * rate(self.cached_input_per_mtok.unwrap_or(self.input_per_mtok))
            + u128::from(output_tokens) * rate(self.output_per_mtok);
        MoneyMicros::from_micros(i64::try_from(total / 1_000_000).unwrap_or(i64::MAX))
    }

    /// `tokens` of a reply at the output rate, except its picture and sound tokens, which use
    /// their own rates when the catalog lists them (else the output rate, as before).
    fn output_cost(&self, tokens: u64, usage: &bistre_protocol::UsageMetrics) -> u128 {
        let rate = |r: i64| u128::try_from(r).unwrap_or(0);
        let image = usage.output_image_tokens.min(tokens);
        let audio = usage.output_audio_tokens.min(tokens - image);
        let text = tokens - image - audio;
        let own = |r: Option<i64>| rate(r.unwrap_or(self.output_per_mtok));
        u128::from(text) * rate(self.output_per_mtok)
            + u128::from(image) * own(self.image_output_per_mtok)
            + u128::from(audio) * own(self.audio_output_per_mtok)
    }

    /// Dialect-accurate exact micro-USD cost, or `None` when a rate it needs is unknown.
    ///
    /// - Anthropic's `input_tokens` **excludes** `cache_read_input_tokens` and
    ///   `cache_creation_input_tokens` (additive billing). Cache writes are billed per TTL at the
    ///   registry's 5-minute / 1-hour write rates; an unknown write rate makes the cost unknown
    ///   (fail closed, never a guessed multiplier).
    /// - `OpenAI`, Gemini, and `CustomOpenAi` report `input_tokens` **inclusive** of cached tokens.
    /// - Gemini thinking tokens are billed as output on top of `output_tokens`.
    /// - An unknown cache-read rate bills cached tokens at the full input rate (an upper bound).
    pub fn cost_for_dialect(
        &self,
        dialect: ProviderDialect,
        usage: &bistre_protocol::UsageMetrics,
    ) -> Option<MoneyMicros> {
        use bistre_protocol::ProviderDialect;
        let rate = |r: i64| u128::try_from(r).unwrap_or(0);
        let base_in = rate(self.input_per_mtok);
        let read_rate = rate(self.cached_input_per_mtok.unwrap_or(self.input_per_mtok));
        // Gemini bills thinking as output but reports it apart from the answer
        // (`thoughtsTokenCount` / `total_thought_tokens`); other dialects already include it.
        // When a per-model override gives a separate reasoning rate, bill reasoning tokens at it.
        let out_cost = if let Some(reason_rate) = self.reasoning_per_mtok {
            let r_cost = u128::from(usage.reasoning_tokens) * rate(reason_rate);
            let non_reason_out = if dialect == ProviderDialect::GoogleGemini {
                usage.output_tokens
            } else {
                usage.output_tokens.saturating_sub(usage.reasoning_tokens)
            };
            r_cost + self.output_cost(non_reason_out, usage)
        } else {
            let billed_output = if dialect == ProviderDialect::GoogleGemini {
                usage.output_tokens.saturating_add(usage.reasoning_tokens)
            } else {
                usage.output_tokens
            };
            self.output_cost(billed_output, usage)
        };
        let total = if dialect == ProviderDialect::Anthropic {
            let one_hour_writes = usage
                .cache_creation_1h_input_tokens
                .min(usage.cache_creation_input_tokens);
            let five_minute_writes = usage.cache_creation_input_tokens - one_hour_writes;
            let write_cost = |tokens: u64, r: Option<i64>| -> Option<u128> {
                if tokens == 0 {
                    Some(0)
                } else {
                    r.map(|r| u128::from(tokens) * rate(r))
                }
            };
            u128::from(usage.input_tokens) * base_in
                + u128::from(usage.cached_input_tokens) * read_rate
                + write_cost(five_minute_writes, self.cache_write_per_mtok)?
                + write_cost(one_hour_writes, self.cache_write_1h_per_mtok)?
                + out_cost
        } else {
            let cached = usage.cached_input_tokens.min(usage.input_tokens);
            let fresh = usage.input_tokens - cached;
            u128::from(fresh) * base_in + u128::from(cached) * read_rate + out_cost
        };
        // Per-call fees are micro-USD per call; `total` is micro-USD per million tokens.
        let fee = |calls: u64, r: Option<i64>| -> Option<u128> {
            if calls == 0 {
                Some(0)
            } else {
                r.map(|r| u128::from(calls) * rate(r) * 1_000_000)
            }
        };
        let fees = fee(usage.web_searches, self.per_search_micros)?
            + fee(usage.code_sessions, self.per_code_session_micros)?;
        Some(MoneyMicros::from_micros(
            i64::try_from((total + fees) / 1_000_000).unwrap_or(i64::MAX),
        ))
    }
}
/// Parses a decimal (`"0.000000075"`, `"7.5e-8"`, `"2.5"`) times `10^scale` into an integer,
/// truncating below one unit. Returns `None` for negatives, NaN-like text, or overflow.
pub fn parse_decimal_scaled(text: &str, scale: u32) -> Option<i64> {
    let t = text.trim();
    if t.is_empty() || t.starts_with('-') {
        return None;
    }
    let (mantissa, exp) = match t.find(['e', 'E']) {
        Some(i) => (&t[..i], t[i + 1..].parse::<i32>().ok()?),
        None => (t, 0),
    };
    let (int_part, frac_part) = mantissa.split_once('.').unwrap_or((mantissa, ""));
    if !int_part
        .bytes()
        .chain(frac_part.bytes())
        .all(|b| b.is_ascii_digit())
    {
        return None;
    }
    let digits = format!("{int_part}{frac_part}");
    let frac_len = i32::try_from(frac_part.len()).ok()?;
    // A catalog number's exponent is untrusted: overflow makes the price unknown.
    let shift = i32::try_from(scale)
        .ok()?
        .checked_add(exp)?
        .checked_sub(frac_len)?;
    let significant = digits.trim_start_matches('0');
    let mut value: i128 = if significant.is_empty() {
        0
    } else {
        significant.parse::<i128>().ok()?
    };
    // Zero never overflows or reaches zero, so the loops below would run `shift` times.
    if value == 0 {
        return Some(0);
    }
    if shift >= 0 {
        for _ in 0..shift {
            value = value.checked_mul(10)?;
        }
    } else {
        for _ in 0..shift.unsigned_abs() {
            value /= 10;
            if value == 0 {
                break;
            }
        }
    }
    i64::try_from(value).ok()
}

/// One model as one source lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogEntry {
    /// The provider the source lists it under (`openrouter`, `openai`, `azure`), if any.
    pub namespace: Option<String>,
    pub id: String,
    pub rates: ModelRates,
    pub extras: ModelExtras,
}

/// Most values kept per media choice list.
pub const MAX_MEDIA_CHOICES: usize = 32;

/// What a media model lets the user pick, as the catalog lists it. Empty means the model
/// offers no choice the catalog names (the provider's default applies).
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct ModelExtras {
    /// The first voice the source names for a speech model.
    pub voice: Option<String>,
    /// Picture shapes (`16:9`, `9:19.5`); `auto` is left out (it is the default).
    pub aspect_ratios: Vec<String>,
    /// Output sizes (`1K`, `2K`, `720p`).
    pub resolutions: Vec<String>,
    /// Video lengths in seconds.
    pub durations_s: Vec<u32>,
}

impl ModelExtras {
    fn fill_gaps(&mut self, other: &Self) {
        if self.voice.is_none() {
            self.voice.clone_from(&other.voice);
        }
        for (mine, theirs) in [
            (&mut self.aspect_ratios, &other.aspect_ratios),
            (&mut self.resolutions, &other.resolutions),
        ] {
            if mine.is_empty() {
                mine.clone_from(theirs);
            }
        }
        if self.durations_s.is_empty() {
            self.durations_s.clone_from(&other.durations_s);
        }
    }

    fn is_empty(&self) -> bool {
        self == &Self::default()
    }
}

/// Which catalog namespace a provider is billed under: `gemini` for the Gemini dialect,
/// else the second-to-last label of its API host (`api.deepseek.com` → `deepseek`), which
/// matches a namespace exactly or as `<label>_...` (`api.together.xyz` → `together_ai`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CatalogScope {
    label: Option<String>,
}

impl CatalogScope {
    /// No provider: plain and maker ids only.
    pub const ANY: Self = Self { label: None };

    #[must_use]
    pub fn of(provider: &ProviderProfile) -> Self {
        if provider.dialect == ProviderDialect::GoogleGemini {
            return Self {
                label: Some("gemini".to_owned()),
            };
        }
        let host = reqwest::Url::parse(provider.base_url.trim())
            .ok()
            .and_then(|u| u.host_str().map(str::to_ascii_lowercase))
            .filter(|h| h.parse::<std::net::IpAddr>().is_err() && !h.starts_with('['));
        let label = host.and_then(|h| {
            let mut labels = h.rsplit('.');
            labels.next();
            labels.next().map(str::to_owned)
        });
        Self { label }
    }
}

fn normalize_id(id: &str) -> String {
    id.trim().to_ascii_lowercase()
}

fn short_id(full: &str) -> &str {
    full.rsplit('/').next().unwrap_or(full)
}

/// Key prefix of the last-resort tier: any source's entry by its id without prefix.
const ANY_SHORT: &str = "~";

/// Immutable snapshot of known models.
#[derive(Debug, Clone, Default)]
pub struct RateTable {
    rates: HashMap<String, ModelRates>,
    extras: HashMap<String, ModelExtras>,
    namespaces: BTreeSet<String>,
}

impl RateTable {
    pub fn len(&self) -> usize {
        self.rates.len()
    }

    pub fn is_empty(&self) -> bool {
        self.rates.is_empty()
    }

    fn put(&mut self, key: String, rates: &ModelRates) {
        self.rates
            .entry(key)
            .and_modify(|known| known.fill_gaps(rates))
            .or_insert(*rates);
    }

    /// Fills gaps only: a key already present keeps its earlier-source rate.
    ///
    /// Keys: `<namespace>:<id>` (the id without the namespace's own prefix), the plain id,
    /// the maker's id without its `vendor/` prefix (from `OpenRouter`, whose ids are
    /// `maker/model` at the maker's price, and from unprefixed `LiteLLM` ids, which are the
    /// makers' own APIs), and `~<id without prefix>` from any source as the last resort.
    pub fn merge_gaps(&mut self, entries: Vec<CatalogEntry>) {
        for entry in entries {
            let full = normalize_id(&entry.id);
            let short = short_id(&full).to_owned();
            if !entry.extras.is_empty() {
                for key in [full.clone(), short.clone()] {
                    self.extras
                        .entry(key)
                        .and_modify(|known| known.fill_gaps(&entry.extras))
                        .or_insert_with(|| entry.extras.clone());
                }
            }
            // An entry that carries only choices adds no rates.
            if entry.rates == ModelRates::default() {
                continue;
            }
            let openrouter = entry.namespace.as_deref() == Some("openrouter");
            if let Some(ns) = &entry.namespace {
                let own = full
                    .strip_prefix(ns.as_str())
                    .and_then(|rest| rest.strip_prefix('/'))
                    .unwrap_or(&full);
                self.put(format!("{ns}:{own}"), &entry.rates);
                self.namespaces.insert(ns.clone());
            }
            self.put(full.clone(), &entry.rates);
            // `~vendor/x` ids on OpenRouter are moving aliases, never a maker's own id.
            let alias = full.starts_with('~');
            let maker = (openrouter && !alias) || !full.contains('/');
            if maker && short != full {
                self.put(short.clone(), &entry.rates);
            }
            if !alias {
                self.put(format!("{ANY_SHORT}{short}"), &entry.rates);
            }
        }
    }

    /// A refresh's prices replace what was known ("Update prices now" never changed a
    /// known price: syncs only filled gaps); ids no source returned this time keep their
    /// old price, so one failed source does not lose prices.
    #[must_use]
    pub fn refreshed_from(&self, fresh: &Self) -> Self {
        let mut next = fresh.clone();
        for (id, old) in &self.rates {
            next.rates.entry(id.clone()).or_insert(*old);
        }
        for (id, old) in &self.extras {
            next.extras.entry(id.clone()).or_insert_with(|| old.clone());
        }
        next.namespaces.extend(self.namespaces.iter().cloned());
        next
    }

    fn namespace_of(&self, scope: &CatalogScope) -> Option<&str> {
        let label = scope.label.as_deref()?;
        if let Some(ns) = self.namespaces.get(label) {
            return Some(ns);
        }
        let prefix = format!("{label}_");
        self.namespaces
            .iter()
            .find(|ns| ns.starts_with(&prefix))
            .map(String::as_str)
    }

    /// The scoped entry first, then the plain id, the maker's id, and the last resort; each
    /// later match only fills fields the earlier one lacks.
    pub fn lookup(&self, scope: &CatalogScope, model: &str) -> Option<ModelRates> {
        let full = normalize_id(model);
        let short = short_id(&full);
        let mut keys = Vec::with_capacity(5);
        if let Some(ns) = self.namespace_of(scope) {
            let own = full
                .strip_prefix(ns)
                .and_then(|rest| rest.strip_prefix('/'))
                .unwrap_or(&full);
            keys.push(format!("{ns}:{own}"));
            keys.push(format!("{ns}:{short}"));
        }
        keys.push(full.clone());
        keys.push(short.to_owned());
        keys.push(format!("{ANY_SHORT}{short}"));
        let mut found = keys.iter().filter_map(|k| self.rates.get(k));
        let mut rates = *found.next()?;
        for other in found {
            rates.fill_gaps(other);
        }
        Some(rates)
    }

    /// The voice and media choices the catalog lists for `model` (by its id, else the
    /// maker's id without prefix).
    pub fn extras(&self, model: &str) -> Option<&ModelExtras> {
        let full = normalize_id(model);
        self.extras
            .get(&full)
            .or_else(|| self.extras.get(short_id(&full)))
    }

    /// The first voice the catalog names for a speech model.
    pub fn voice(&self, model: &str) -> Option<&str> {
        self.extras(model)?.voice.as_deref()
    }
}

#[derive(Debug, Default)]
struct SyncClock {
    last_success: Option<Instant>,
    last_empty: Option<Instant>,
}

/// Process-wide single-flight pricing registry.
#[derive(Debug)]
pub struct PricingRegistry {
    table_tx: watch::Sender<Arc<RateTable>>,
    syncing: AtomicBool,
    clock: Mutex<SyncClock>,
    /// Where the merged table is cached between launches (`None` in tests).
    cache_path: Option<PathBuf>,
    /// The running refresh, stopped and awaited by [`Self::stop_sync`] so no download or
    /// cache write outlives the engine (it writes into the data folder).
    sync_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct PriceCache {
    format: u32,
    fetched_at_ms: i64,
    /// Keyed as in [`RateTable::merge_gaps`].
    rates: HashMap<String, ModelRates>,
    extras: HashMap<String, ModelExtras>,
    namespaces: BTreeSet<String>,
}

fn unix_now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

impl Default for PricingRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl PricingRegistry {
    pub fn new() -> Self {
        let (table_tx, _) = watch::channel(Arc::new(RateTable::default()));
        Self {
            table_tx,
            syncing: AtomicBool::new(false),
            clock: Mutex::new(SyncClock::default()),
            cache_path: None,
            sync_task: Mutex::new(None),
        }
    }

    /// A registry backed by an on-disk cache: a fresh cache (same format, under 24 h old)
    /// is loaded immediately and counts as the last successful sync.
    pub fn with_cache(path: PathBuf) -> Self {
        let mut registry = Self::new();
        let cache = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice::<PriceCache>(&bytes)
                .map_err(|err| tracing::debug!(%err, "price cache unreadable; rebuilt on sync"))
                .ok(),
            Err(err) => {
                tracing::debug!(%err, "no price cache yet");
                None
            }
        };
        if let Some(cache) = cache.filter(|c| c.format == PRICE_CACHE_FORMAT) {
            let age_ms =
                u64::try_from(unix_now_ms().saturating_sub(cache.fetched_at_ms)).unwrap_or(0);
            registry.table_tx.send_replace(Arc::new(RateTable {
                rates: cache.rates,
                extras: cache.extras,
                namespaces: cache.namespaces,
            }));
            lock_or_recover(&registry.clock, "clock").last_success =
                Instant::now().checked_sub(Duration::from_millis(age_ms));
        }
        registry.cache_path = Some(path);
        registry
    }

    fn save_cache(&self) {
        let Some(path) = &self.cache_path else { return };
        let table = self.snapshot();
        let cache = PriceCache {
            format: PRICE_CACHE_FORMAT,
            fetched_at_ms: unix_now_ms(),
            rates: table.rates.clone(),
            extras: table.extras.clone(),
            namespaces: table.namespaces.clone(),
        };
        let written = serde_json::to_vec(&cache)
            .map_err(std::io::Error::other)
            .and_then(|bytes| {
                use std::io::Write as _;
                let tmp = path.with_extension("json.tmp");
                let mut file = std::fs::File::create(&tmp)?;
                file.write_all(&bytes)?;
                // `sync_all` needs a writable handle on Windows.
                file.sync_all()?;
                drop(file);
                std::fs::rename(&tmp, path)
            });
        if let Err(err) = written {
            tracing::warn!(error = %err, "price cache write failed; prices refresh again next start");
        }
    }

    /// Current snapshot (never blocks).
    pub fn snapshot(&self) -> Arc<RateTable> {
        Arc::clone(&self.table_tx.borrow())
    }

    /// Publishes a merged snapshot (used by the sync task and tests).
    pub fn publish(&self, entries: Vec<CatalogEntry>) {
        let mut next = (*self.snapshot()).clone();
        next.merge_gaps(entries);
        self.table_tx.send_replace(Arc::new(next));
    }

    fn sync_due(&self) -> bool {
        let clock = lock_or_recover(&self.clock, "clock");
        let fresh = clock
            .last_success
            .is_some_and(|t| t.elapsed() < REGISTRY_TTL);
        let cooling = clock
            .last_empty
            .is_some_and(|t| t.elapsed() < REGISTRY_FAILURE_COOLDOWN);
        !fresh && !cooling
    }

    /// Starts one detached background sync when stale (single-flight; returns immediately).
    pub fn ensure_fresh(self: &Arc<Self>, web: &PublicWebTransport) {
        if self.sync_due() {
            self.start_sync(web);
        }
    }

    /// Starts a sync now regardless of age (the user's "Update prices now").
    pub fn force_refresh(self: &Arc<Self>, web: &PublicWebTransport) {
        self.start_sync(web);
    }

    fn start_sync(self: &Arc<Self>, web: &PublicWebTransport) {
        // Outside a Tokio runtime there is nothing to run the download on.
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            tracing::warn!("price refresh skipped: no async runtime");
            return;
        };
        if self
            .syncing
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return;
        }
        let registry = Arc::clone(self);
        let web = web.clone();
        let task = runtime.spawn(async move {
            let mut any = false;
            let base = registry.snapshot();
            let mut fresh = RateTable::default();
            for (name, url) in PRICING_SOURCES {
                let Ok(fetched) = web.get(url, MAX_CATALOG_BYTES).await else {
                    continue;
                };
                if fetched.truncated || !(200..300).contains(&fetched.status) {
                    continue;
                }
                let entries = parse_source(name, &fetched.body);
                any |= !entries.is_empty();
                // Within one refresh an earlier source wins and later ones fill its gaps; the
                // refresh as a whole wins over the prices known before it.
                fresh.merge_gaps(entries);
                registry
                    .table_tx
                    .send_replace(Arc::new(base.refreshed_from(&fresh)));
            }
            {
                let mut clock = lock_or_recover(&registry.clock, "clock");
                if any {
                    clock.last_success = Some(Instant::now());
                } else {
                    clock.last_empty = Some(Instant::now());
                }
            }
            if any {
                registry.save_cache();
            }
            registry.syncing.store(false, Ordering::Release);
        });
        *lock_or_recover(&self.sync_task, "sync_task") = Some(task);
    }

    /// Stops a running refresh and waits until it has ended. The cache write has no await
    /// point, so a stop never cuts it in half.
    pub async fn stop_sync(&self) {
        let task = lock_or_recover(&self.sync_task, "sync_task").take();
        if let Some(task) = task {
            task.abort();
            match task.await {
                Ok(()) => {}
                Err(err) if err.is_cancelled() => {}
                Err(err) => tracing::warn!(%err, "price refresh ended with a panic"),
            }
        }
        self.syncing.store(false, Ordering::Release);
    }

    /// Rate for `model` as `scope`'s provider serves it, waiting up to
    /// [`REGISTRY_MODEL_WAIT`] for an in-flight sync to publish it.
    pub async fn rates_for(&self, scope: &CatalogScope, model: &str) -> Option<ModelRates> {
        if let Some(r) = self.snapshot().lookup(scope, model) {
            return Some(r);
        }
        if !self.syncing.load(Ordering::Acquire) {
            return None;
        }
        let mut rx = self.table_tx.subscribe();
        let wait = async {
            loop {
                if rx.changed().await.is_err() {
                    return None;
                }
                if let Some(r) = rx.borrow().lookup(scope, model) {
                    return Some(r);
                }
            }
        };
        tokio::time::timeout(REGISTRY_MODEL_WAIT, wait)
            .await
            .ok()
            .flatten()
    }
}

#[cfg(test)]
#[path = "registry_tests.rs"]
mod tests;
