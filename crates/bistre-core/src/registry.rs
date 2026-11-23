//! Live model pricing registry (Spec 03 / Spec 06): zero hardcoded model rates.
//!
//! - Single-flight, detached background sync: `OpenRouter` → Vercel AI Gateway → `LiteLLM` →
//!   `models.dev`. Earlier sources win; later sources only fill gaps. Each source is published
//!   incrementally through a `tokio::sync::watch` channel.
//! - `24 h` freshness TTL, `60 s` cooldown after a sync that produced nothing. Syncs start only
//!   at engine start (when `pricing_auto_refresh` is on) or on an explicit refresh, never from
//!   a run, and the merged table is cached on disk with a format version.
//! - Callers may wait up to `2.5 s` for one model's rate; waiting never cancels the download.
//! - Every price is converted once, with integer math only, into `MoneyMicros` per one million
//!   tokens; JSON floats are re-read from their shortest decimal text, never multiplied as `f64`.
//! - Catalog GETs carry no identifiers and go through `PublicWebTransport`.

use bistre_protocol::lock_or_recover;
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bistre_protocol::MoneyMicros;
use serde::Deserialize;
use serde::de::IgnoredAny;
use tokio::sync::watch;

use crate::ssrf::PublicWebTransport;

/// Freshness window for a successful sync.
pub const REGISTRY_TTL: Duration = Duration::from_hours(24);
/// Version of the on-disk price cache; a different version is ignored and rebuilt.
pub const PRICE_CACHE_FORMAT: u32 = 3;
/// Cooldown after a sync that yielded no rates.
pub const REGISTRY_FAILURE_COOLDOWN: Duration = Duration::from_secs(60);
/// Maximum wait for one model's rate.
pub const REGISTRY_MODEL_WAIT: Duration = Duration::from_millis(2_500);
const MAX_CATALOG_BYTES: usize = 32 * 1024 * 1024;

/// Ordered pricing sources: (name, URL).
pub const PRICING_SOURCES: [(&str, &str); 4] = [
    ("openrouter", "https://openrouter.ai/api/v1/models"),
    ("vercel", "https://ai-gateway.vercel.sh/v1/models"),
    (
        "litellm",
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json",
    ),
    ("models_dev", "https://models.dev/api.json"),
];

/// Integer rates in micro-USD per one million tokens.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ModelRates {
    pub input_per_mtok: i64,
    pub output_per_mtok: i64,
    /// Cached-input rate when the source reports one.
    pub cached_input_per_mtok: Option<i64>,
    /// The model's conversation limit (context window) in tokens, when the source reports one.
    pub context_tokens: Option<u32>,
    /// Whether the model accepts a reasoning/thinking effort, when the source reports it.
    pub reasoning: Option<bool>,
}

impl ModelRates {
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
    let shift = i32::try_from(scale).ok()? + exp - frac_len;
    let significant = digits.trim_start_matches('0');
    let mut value: i128 = if significant.is_empty() {
        0
    } else {
        significant.parse::<i128>().ok()?
    };
    if shift >= 0 {
        for _ in 0..shift {
            value = value.checked_mul(10)?;
        }
    } else {
        for _ in 0..(-shift) {
            value /= 10;
            if value == 0 {
                break;
            }
        }
    }
    i64::try_from(value).ok()
}

// Typed views of the four public price lists. Only the fields used here are read; every other
// field is skipped without allocating, so a multi-megabyte list never becomes a full
// `serde_json::Value` tree (which held hundreds of MB in worker malloc arenas on Linux).

/// A field or entry of unexpected shape is skipped instead of failing the whole list.
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

/// Per-token USD price → micro-USD per 1M tokens (`× 10^12`).
fn per_token(f: Field<Decimal>) -> Option<i64> {
    field(f).and_then(|d| d.scaled(12))
}

/// Per-1M-token USD price → micro-USD per 1M tokens (`× 10^6`).
fn per_mtok(f: Field<Decimal>) -> Option<i64> {
    field(f).and_then(|d| d.scaled(6))
}

/// A non-negative JSON integer that fits `u32` (context limits).
fn count(f: Field<u64>) -> Option<u32> {
    field(f).and_then(|n| u32::try_from(n).ok())
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
    context_window: Field<u64>,
    /// `OpenRouter`: request parameters the model accepts (`"reasoning"` when it can think).
    supported_parameters: Field<Vec<String>>,
    /// Vercel AI Gateway: capability tags (`"reasoning"`).
    tags: Field<Vec<String>>,
}

#[derive(Deserialize)]
struct ListPricing {
    prompt: Field<Decimal>,
    completion: Field<Decimal>,
    input: Field<Decimal>,
    output: Field<Decimal>,
    input_cache_read: Field<Decimal>,
}

#[derive(Deserialize)]
struct LiteSpec {
    input_cost_per_token: Field<Decimal>,
    output_cost_per_token: Field<Decimal>,
    cache_read_input_token_cost: Field<Decimal>,
    max_input_tokens: Field<u64>,
    max_tokens: Field<u64>,
    supports_reasoning: Field<bool>,
}

#[derive(Deserialize)]
struct DevProvider {
    models: Field<BTreeMap<String, Lenient<DevModel>>>,
}

#[derive(Deserialize)]
struct DevModel {
    cost: Field<DevCost>,
    limit: Field<DevLimit>,
    reasoning: Field<bool>,
}

#[derive(Deserialize)]
struct DevCost {
    input: Field<Decimal>,
    output: Field<Decimal>,
    cache_read: Field<Decimal>,
}

#[derive(Deserialize)]
struct DevLimit {
    context: Field<u64>,
}

/// Parses one source's raw JSON into `(model_id, rates)` pairs; an unreadable list yields none.
pub fn parse_source(source: &str, body: &[u8]) -> Vec<(String, ModelRates)> {
    let parsed = match source {
        "openrouter" | "vercel" => parse_list(source == "openrouter", body),
        "litellm" => parse_litellm(body),
        "models_dev" => parse_models_dev(body),
        _ => return Vec::new(),
    };
    parsed.unwrap_or_else(|err| {
        tracing::warn!(source, %err, "price list unreadable");
        Vec::new()
    })
}

fn parse_list(openrouter: bool, body: &[u8]) -> serde_json::Result<Vec<(String, ModelRates)>> {
    let doc: ListDoc = serde_json::from_slice(body)?;
    Ok(doc
        .data
        .into_iter()
        .filter_map(Lenient::get)
        .filter_map(|item| {
            let p = field(item.pricing)?;
            let (input, output) = if openrouter {
                (per_token(p.prompt)?, per_token(p.completion)?)
            } else {
                (per_token(p.input)?, per_token(p.output)?)
            };
            let context = if openrouter {
                item.context_length
            } else {
                item.context_window
            };
            let flags = if openrouter {
                field(item.supported_parameters)
            } else {
                field(item.tags)
            };
            let reasoning = flags.map(|f| f.iter().any(|t| t == "reasoning"));
            Some((
                item.id,
                ModelRates {
                    input_per_mtok: input,
                    output_per_mtok: output,
                    cached_input_per_mtok: per_token(p.input_cache_read),
                    context_tokens: count(context),
                    reasoning,
                },
            ))
        })
        .collect())
}

fn parse_litellm(body: &[u8]) -> serde_json::Result<Vec<(String, ModelRates)>> {
    let doc: BTreeMap<String, Lenient<LiteSpec>> = serde_json::from_slice(body)?;
    Ok(doc
        .into_iter()
        .filter_map(|(id, spec)| {
            let spec = spec.get()?;
            Some((
                id,
                ModelRates {
                    input_per_mtok: per_token(spec.input_cost_per_token)?,
                    output_per_mtok: per_token(spec.output_cost_per_token)?,
                    cached_input_per_mtok: per_token(spec.cache_read_input_token_cost),
                    context_tokens: count(spec.max_input_tokens).or(count(spec.max_tokens)),
                    reasoning: field(spec.supports_reasoning),
                },
            ))
        })
        .collect())
}

fn parse_models_dev(body: &[u8]) -> serde_json::Result<Vec<(String, ModelRates)>> {
    let doc: BTreeMap<String, Lenient<DevProvider>> = serde_json::from_slice(body)?;
    Ok(doc
        .into_values()
        .filter_map(Lenient::get)
        .filter_map(|p| field(p.models))
        .flatten()
        .filter_map(|(id, model)| {
            let model = model.get()?;
            let cost = field(model.cost)?;
            Some((
                id,
                ModelRates {
                    input_per_mtok: per_mtok(cost.input)?,
                    output_per_mtok: per_mtok(cost.output)?,
                    cached_input_per_mtok: per_mtok(cost.cache_read),
                    context_tokens: field(model.limit).and_then(|l| count(l.context)),
                    reasoning: field(model.reasoning),
                },
            ))
        })
        .collect())
}

fn normalize_id(id: &str) -> String {
    id.trim().to_ascii_lowercase()
}

/// Immutable snapshot of known rates.
#[derive(Debug, Clone, Default)]
pub struct RateTable {
    rates: HashMap<String, ModelRates>,
}

impl RateTable {
    pub fn len(&self) -> usize {
        self.rates.len()
    }

    pub fn is_empty(&self) -> bool {
        self.rates.is_empty()
    }

    /// Fills gaps only: an id already present keeps its earlier-source rate.
    pub fn merge_gaps(&mut self, entries: Vec<(String, ModelRates)>) {
        for (id, rates) in entries {
            let full = normalize_id(&id);
            let short = full.rsplit('/').next().unwrap_or(&full).to_owned();
            for key in [full, short] {
                self.rates
                    .entry(key)
                    .and_modify(|known| {
                        known.cached_input_per_mtok =
                            known.cached_input_per_mtok.or(rates.cached_input_per_mtok);
                        known.context_tokens = known.context_tokens.or(rates.context_tokens);
                        known.reasoning = known.reasoning.or(rates.reasoning);
                    })
                    .or_insert(rates);
            }
        }
    }

    /// Exact id first, then the id without its `vendor/` prefix.
    pub fn lookup(&self, model: &str) -> Option<ModelRates> {
        let full = normalize_id(model);
        let short = full.rsplit('/').next().unwrap_or(&full);
        let by_short = self.rates.get(short).copied();
        // A vendor-prefixed entry keeps its own prices; fields it lacks come from the plain id
        // (sources disagree on prefixes, e.g. `openai/gpt-x` vs `gpt-x`).
        self.rates
            .get(&full)
            .copied()
            .map(|mut known| {
                if let Some(other) = by_short {
                    known.cached_input_per_mtok =
                        known.cached_input_per_mtok.or(other.cached_input_per_mtok);
                    known.context_tokens = known.context_tokens.or(other.context_tokens);
                    known.reasoning = known.reasoning.or(other.reasoning);
                }
                known
            })
            .or(by_short)
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
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct PriceCache {
    format: u32,
    fetched_at_ms: i64,
    /// `id -> [input, output, cached_input or -1, context tokens or -1, reasoning 1/0/-1]`
    /// (micro-USD per million tokens for the first three).
    rates: HashMap<String, [i64; 5]>,
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
        }
    }

    /// A registry backed by an on-disk cache: a fresh cache (same format, under 24 h old)
    /// is loaded immediately and counts as the last successful sync.
    pub fn with_cache(path: PathBuf) -> Self {
        let mut registry = Self::new();
        if let Some(cache) = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<PriceCache>(&bytes).ok())
            .filter(|c| c.format == PRICE_CACHE_FORMAT)
        {
            let age_ms =
                u64::try_from(unix_now_ms().saturating_sub(cache.fetched_at_ms)).unwrap_or(0);
            let entries = cache
                .rates
                .into_iter()
                .map(|(id, [input, output, cached, context, reasoning])| {
                    let rates = ModelRates {
                        input_per_mtok: input,
                        output_per_mtok: output,
                        cached_input_per_mtok: (cached >= 0).then_some(cached),
                        context_tokens: u32::try_from(context).ok(),
                        reasoning: (reasoning >= 0).then_some(reasoning == 1),
                    };
                    (id, rates)
                })
                .collect();
            registry.publish(entries);
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
            rates: table
                .rates
                .iter()
                .map(|(id, r)| {
                    let cached = r.cached_input_per_mtok.unwrap_or(-1);
                    let context = r.context_tokens.map_or(-1, i64::from);
                    let reasoning = r.reasoning.map_or(-1, i64::from);
                    (
                        id.clone(),
                        [
                            r.input_per_mtok,
                            r.output_per_mtok,
                            cached,
                            context,
                            reasoning,
                        ],
                    )
                })
                .collect(),
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
    pub fn publish(&self, entries: Vec<(String, ModelRates)>) {
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
        runtime.spawn(async move {
            let mut any = false;
            for (name, url) in PRICING_SOURCES {
                let Ok(fetched) = web.get(url, MAX_CATALOG_BYTES).await else {
                    continue;
                };
                if fetched.truncated || !(200..300).contains(&fetched.status) {
                    continue;
                }
                let entries = parse_source(name, &fetched.body);
                any |= !entries.is_empty();
                registry.publish(entries);
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
    }

    /// Rate for `model`, waiting up to [`REGISTRY_MODEL_WAIT`] for an in-flight sync to publish it.
    pub async fn rates_for(&self, model: &str) -> Option<ModelRates> {
        if let Some(r) = self.snapshot().lookup(model) {
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
                if let Some(r) = rx.borrow().lookup(model) {
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
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn parse(source: &str, doc: &Value) -> Vec<(String, ModelRates)> {
        parse_source(source, doc.to_string().as_bytes())
    }

    #[test]
    fn decimal_scaling_is_exact_integer_math() {
        assert_eq!(parse_decimal_scaled("0.000000075", 12), Some(75_000));
        assert_eq!(parse_decimal_scaled("7.5e-8", 12), Some(75_000));
        assert_eq!(parse_decimal_scaled("0.0000025", 12), Some(2_500_000));
        assert_eq!(parse_decimal_scaled("2.5", 6), Some(2_500_000));
        assert_eq!(parse_decimal_scaled("15", 6), Some(15_000_000));
        assert_eq!(parse_decimal_scaled("1e-13", 12), Some(0));
        assert_eq!(parse_decimal_scaled("-1", 6), None);
        assert_eq!(parse_decimal_scaled("abc", 6), None);
    }

    #[test]
    fn parses_all_four_source_shapes_and_earlier_sources_win() {
        let openrouter = json!({"data": [{"id": "vendor/model-a", "pricing": {"prompt": "0.000001", "completion": "0.000002", "input_cache_read": "0.0000001"}}]});
        let vercel = json!({"data": [{"id": "vendor/model-a", "pricing": {"input": "0.000009", "output": "0.000009"}}, {"id": "vendor/model-b", "pricing": {"input": "0.0000005", "output": "0.0000015"}}]});
        let litellm = json!({"sample_spec": {}, "model-c": {"input_cost_per_token": 3e-6, "output_cost_per_token": 1.5e-5}});
        let models_dev = json!({"prov": {"models": {"model-d": {"cost": {"input": 0.5, "output": 1.5, "cache_read": 0.05}}}}});

        let registry = PricingRegistry::new();
        registry.publish(parse("openrouter", &openrouter));
        registry.publish(parse("vercel", &vercel));
        registry.publish(parse("litellm", &litellm));
        registry.publish(parse("models_dev", &models_dev));
        let table = registry.snapshot();

        let a = table.lookup("vendor/model-a");
        assert_eq!(
            a.map(|r| r.input_per_mtok),
            Some(1_000_000),
            "OpenRouter must win over Vercel"
        );
        assert_eq!(
            table.lookup("MODEL-A").map(|r| r.output_per_mtok),
            Some(2_000_000)
        );
        assert_eq!(
            table.lookup("model-b").map(|r| r.input_per_mtok),
            Some(500_000)
        );
        assert_eq!(
            table.lookup("model-c").map(|r| r.output_per_mtok),
            Some(15_000_000)
        );
        assert_eq!(
            table
                .lookup("model-d")
                .and_then(|r| r.cached_input_per_mtok),
            Some(50_000)
        );
        assert!(table.lookup("unknown").is_none());
    }

    #[test]
    fn cost_bills_cached_input_at_cached_rate() {
        let rates = ModelRates {
            input_per_mtok: 3_000_000,
            output_per_mtok: 15_000_000,
            cached_input_per_mtok: Some(300_000),
            context_tokens: None,
            reasoning: None,
        };
        // 1M fresh input = $3, 1M cached = $0.30, 100k output = $1.50.
        let cost = rates.cost(2_000_000, 1_000_000, 100_000);
        assert_eq!(cost.as_micros(), 4_800_000);
    }

    #[tokio::test]
    async fn waiting_for_an_unknown_model_without_a_sync_returns_immediately() {
        let registry = PricingRegistry::new();
        let started = Instant::now();
        assert!(registry.rates_for("nothing").await.is_none());
        assert!(started.elapsed() < Duration::from_millis(100));
    }

    #[test]
    fn price_cache_round_trips_and_ignores_other_formats() -> Result<(), Box<dyn std::error::Error>>
    {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("pricing_cache.json");
        let registry = PricingRegistry::with_cache(path.clone());
        registry.publish(vec![(
            "vendor/model-a".to_owned(),
            ModelRates {
                input_per_mtok: 1_000_000,
                output_per_mtok: 2_000_000,
                cached_input_per_mtok: Some(100_000),
                context_tokens: None,
                reasoning: None,
            },
        )]);
        registry.save_cache();

        // A new process loads the cache and treats it as a fresh sync (no download needed).
        let reloaded = PricingRegistry::with_cache(path.clone());
        assert_eq!(
            reloaded
                .snapshot()
                .lookup("model-a")
                .map(|r| r.cached_input_per_mtok),
            Some(Some(100_000))
        );
        assert!(!reloaded.sync_due());

        // A cache written by another format version is ignored and rebuilt.
        std::fs::write(&path, r#"{"format":999,"fetched_at_ms":0,"rates":{}}"#)?;
        let other = PricingRegistry::with_cache(path);
        assert!(other.snapshot().lookup("model-a").is_none());
        assert!(other.sync_due());
        Ok(())
    }

    #[test]
    fn context_limits_come_from_each_source_shape() {
        let openrouter = json!({"data": [{"id": "v/a", "context_length": 128_000, "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]});
        let litellm = json!({"b": {"input_cost_per_token": 0.000_001, "output_cost_per_token": 0.000_002, "max_input_tokens": 200_000}});
        let models_dev = json!({"p": {"models": {"c": {"cost": {"input": 1, "output": 2}, "limit": {"context": 64000}}}}});
        let ctx =
            |src: &str, doc: &Value| parse(src, doc).first().and_then(|(_, r)| r.context_tokens);
        assert_eq!(ctx("openrouter", &openrouter), Some(128_000));
        assert_eq!(ctx("litellm", &litellm), Some(200_000));
        assert_eq!(ctx("models_dev", &models_dev), Some(64_000));
    }

    #[test]
    fn one_malformed_entry_never_drops_the_rest_of_a_list() {
        let openrouter = json!({"data": ["junk", {"id": "x/bad", "pricing": "free"}, {"id": "x/ok", "context_length": "big", "pricing": {"prompt": "0.000001", "completion": {"odd": 1}}}, {"id": "x/good", "pricing": {"prompt": 1e-6, "completion": "0.000002"}}]});
        let litellm = json!({"sample_spec": {"max_tokens": "legacy", "input_cost_per_token": "n/a"}, "broken": "text", "m": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6, "max_tokens": 8192}});
        let models_dev = json!({"p1": "text", "p2": {"models": {"m1": 5, "m2": {"cost": {"input": 1, "output": 2}, "limit": {"context": -1}}}}});
        let ids =
            |v: Vec<(String, ModelRates)>| v.into_iter().map(|(id, _)| id).collect::<Vec<_>>();
        assert_eq!(ids(parse("openrouter", &openrouter)), vec!["x/good"]);
        let lite = parse("litellm", &litellm);
        assert_eq!(lite.len(), 1);
        assert_eq!(lite.first().and_then(|(_, r)| r.context_tokens), Some(8192));
        let dev = parse("models_dev", &models_dev);
        assert_eq!(ids(dev.clone()), vec!["m2"]);
        assert_eq!(dev.first().and_then(|(_, r)| r.context_tokens), None);
        assert_eq!(parse_source("openrouter", b"not json"), Vec::new());
    }

    #[test]
    fn reasoning_capability_comes_from_each_source_shape() {
        let openrouter = json!({"data": [{"id": "v/think", "supported_parameters": ["reasoning", "tools"], "pricing": {"prompt": "0.000001", "completion": "0.000002"}}, {"id": "v/plain", "supported_parameters": ["tools"], "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]});
        let vercel = json!({"data": [{"id": "v/tag", "tags": ["reasoning"], "pricing": {"input": "0.000001", "output": "0.000002"}}]});
        let litellm = json!({"lite": {"input_cost_per_token": 0.000_001, "output_cost_per_token": 0.000_002, "supports_reasoning": true}});
        let models_dev = json!({"p": {"models": {"dev": {"cost": {"input": 1, "output": 2}, "reasoning": false}}}});
        let flag = |src: &str, doc: &Value, id: &str| {
            parse(src, doc)
                .into_iter()
                .find(|(i, _)| i == id)
                .and_then(|(_, r)| r.reasoning)
        };
        assert_eq!(flag("openrouter", &openrouter, "v/think"), Some(true));
        assert_eq!(flag("openrouter", &openrouter, "v/plain"), Some(false));
        assert_eq!(flag("vercel", &vercel, "v/tag"), Some(true));
        assert_eq!(flag("litellm", &litellm, "lite"), Some(true));
        assert_eq!(flag("models_dev", &models_dev, "dev"), Some(false));

        // A later source fills a field the earlier one lacked, but never overrides it.
        let registry = PricingRegistry::new();
        registry.publish(parse("openrouter", &json!({"data": [{"id": "x/m", "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]})));
        registry.publish(parse("models_dev", &json!({"p": {"models": {"m": {"cost": {"input": 9, "output": 9}, "reasoning": true, "limit": {"context": 1000}}}}})));
        let merged = registry.snapshot().lookup("x/m");
        assert_eq!(merged.map(|r| r.input_per_mtok), Some(1_000_000));
        assert_eq!(merged.and_then(|r| r.reasoning), Some(true));
        assert_eq!(merged.and_then(|r| r.context_tokens), Some(1000));
    }
}
