//! Unit tests for `registry.rs`.

use super::*;
use serde_json::{Value, json};

fn parse(source: &str, doc: &Value) -> Vec<CatalogEntry> {
    parse_source(source, doc.to_string().as_bytes())
}

use crate::test_support::provider;

const ANY: &CatalogScope = &CatalogScope::ANY;

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

/// An untrusted exponent can neither overflow the scale math nor spin the loops.
#[test]
fn decimal_scaling_bounds_huge_exponents() {
    assert_eq!(parse_decimal_scaled("1e2147483647", 12), None);
    assert_eq!(parse_decimal_scaled("1e-2147483648", 12), Some(0));
    assert_eq!(parse_decimal_scaled("0e2147483000", 12), Some(0));
    assert_eq!(parse_decimal_scaled("5e-2147483000", 12), Some(0));
    assert_eq!(parse_decimal_scaled("1e40", 12), None);
}

#[test]
fn both_source_shapes_parse_and_earlier_sources_win() {
    let openrouter = json!({"data": [{"id": "vendor/model-a", "pricing": {"prompt": "0.000001", "completion": "0.000002", "input_cache_read": "0.0000001"}}]});
    let litellm = json!({"sample_spec": {}, "model-a": {"input_cost_per_token": 9e-6, "output_cost_per_token": 9e-6, "max_input_tokens": 64_000}, "model-c": {"input_cost_per_token": 3e-6, "output_cost_per_token": 1.5e-5}});

    let registry = PricingRegistry::new();
    registry.publish(parse("openrouter", &openrouter));
    registry.publish(parse("litellm", &litellm));
    let table = registry.snapshot();

    let a = table.lookup(ANY, "vendor/model-a");
    assert_eq!(
        a.map(|r| r.input_per_mtok),
        Some(1_000_000),
        "OpenRouter must win over LiteLLM"
    );
    assert_eq!(a.and_then(|r| r.context_tokens), Some(64_000));
    assert_eq!(
        table.lookup(ANY, "MODEL-A").map(|r| r.output_per_mtok),
        Some(2_000_000)
    );
    assert_eq!(
        table.lookup(ANY, "model-c").map(|r| r.output_per_mtok),
        Some(15_000_000)
    );
    assert!(table.lookup(ANY, "unknown").is_none());
}

/// A reseller's prefixed entry listed before the maker's own (`LiteLLM` sorts
/// `azure/eu/...` first) used to claim the bare id: native `gpt-x` got the reseller's
/// price and context window.
#[test]
fn a_resellers_entry_never_prices_the_makers_model() {
    let litellm = json!({
        "azure/eu/gpt-x": {"litellm_provider": "azure", "input_cost_per_token": 1.375e-6, "output_cost_per_token": 1.1e-5, "max_input_tokens": 128_000},
        "gpt-x": {"litellm_provider": "openai", "input_cost_per_token": 1.25e-6, "output_cost_per_token": 1e-5, "max_input_tokens": 272_000},
        "groq/llama-y": {"litellm_provider": "groq", "input_cost_per_token": 5.9e-7, "output_cost_per_token": 7.9e-7}
    });
    let mut table = RateTable::default();
    table.merge_gaps(parse("litellm", &litellm));
    let openai = CatalogScope::of(&provider(
        ProviderDialect::OpenAi,
        "https://api.openai.com/v1",
    ));
    let native = table.lookup(&openai, "gpt-x");
    assert_eq!(native.map(|r| r.input_per_mtok), Some(1_250_000));
    assert_eq!(native.and_then(|r| r.context_tokens), Some(272_000));
    assert_eq!(
        table.lookup(ANY, "gpt-x").map(|r| r.input_per_mtok),
        Some(1_250_000)
    );
    let azure = CatalogScope::of(&provider(
        ProviderDialect::CustomOpenAi,
        "https://my-resource.openai.azure.com/openai",
    ));
    assert_eq!(
        table.lookup(&azure, "eu/gpt-x").map(|r| r.input_per_mtok),
        Some(1_375_000)
    );
    // A model only a host lists is found under that host, and as the last resort.
    let groq = CatalogScope::of(&provider(
        ProviderDialect::CustomOpenAi,
        "https://api.groq.com/openai/v1",
    ));
    assert_eq!(
        table.lookup(&groq, "llama-y").map(|r| r.input_per_mtok),
        Some(590_000)
    );
    assert_eq!(
        table.lookup(ANY, "llama-y").map(|r| r.input_per_mtok),
        Some(590_000)
    );
}

/// The same model costs what the provider serving it charges: free on the Gemini API,
/// paid on `OpenRouter`; a `~vendor/x` alias never becomes the maker's id.
#[test]
fn the_serving_provider_prices_its_own_models() {
    let openrouter = json!({"data": [
        {"id": "google/gemma-z", "pricing": {"prompt": "0.0000001", "completion": "0.0000002"}},
        {"id": "~google/flash-latest", "pricing": {"prompt": "0.000009", "completion": "0.000009"}}
    ]});
    let litellm = json!({"gemini/gemma-z": {"litellm_provider": "gemini", "input_cost_per_token": 0, "output_cost_per_token": 0},
        "gemini/flash-latest": {"litellm_provider": "gemini", "input_cost_per_token": 3e-7, "output_cost_per_token": 2.5e-6}});
    let mut table = RateTable::default();
    table.merge_gaps(parse("openrouter", &openrouter));
    table.merge_gaps(parse("litellm", &litellm));
    let gemini = CatalogScope::of(&provider(
        ProviderDialect::GoogleGemini,
        "https://generativelanguage.googleapis.com",
    ));
    let openrouter_scope = CatalogScope::of(&provider(
        ProviderDialect::CustomOpenAi,
        bistre_protocol::dialect::OPENROUTER_BASE_URL,
    ));
    assert_eq!(
        table
            .lookup(&gemini, "models/gemma-z")
            .map(|r| r.input_per_mtok),
        Some(0)
    );
    assert_eq!(
        table
            .lookup(&openrouter_scope, "google/gemma-z")
            .map(|r| r.input_per_mtok),
        Some(100_000)
    );
    assert_eq!(
        table.lookup(ANY, "flash-latest").map(|r| r.input_per_mtok),
        Some(300_000),
        "the moving alias must not claim the bare id"
    );
}

#[test]
fn media_models_carry_their_modalities_and_units() {
    let openrouter = json!({"data": [
        {"id": "maker/painter", "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["image"]}, "pricing": {"prompt": "0", "completion": "0"}},
        {"id": "maker/chat-painter", "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["image", "text"]}, "pricing": {"prompt": "0.0000003", "completion": "0.0000025"}, "top_provider": {"max_completion_tokens": 32_768}},
        {"id": "maker/filmer", "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["video"]}, "pricing": {"prompt": "0", "completion": "0"}},
        {"id": "maker/speaker", "architecture": {"input_modalities": ["text"], "output_modalities": ["speech"]}, "pricing": {"prompt": "0.00002"}, "supported_voices": ["v1", "v2"]},
        {"id": "maker/half-priced-chat", "architecture": {"output_modalities": ["text"]}, "pricing": {"prompt": "0.000001"}}
    ]});
    let videos = json!({"data": [{"id": "maker/filmer", "supported_durations": [-1, 4, 8, 12], "pricing_skus": {"duration_seconds_720p": "0.10", "duration_seconds_with_audio_4k": "0.30", "cents_per_image_input": "5", "video_tokens": "0.000007"}},
        {"id": "maker/cents", "supported_durations": [5], "pricing_skus": {"cents_per_video_output_second_1080p": "12.5"}}]});
    let litellm = json!({
        "painter": {"litellm_provider": "maker", "mode": "image_generation", "output_cost_per_image": 0.04},
        "seed-video": {"litellm_provider": "maker", "mode": "video_generation", "output_cost_per_second_720p": 0.05, "output_cost_per_second_1080p": 0.12, "supported_modalities": ["text", "image"], "supported_output_modalities": ["video"]},
        "tts-x": {"litellm_provider": "maker", "mode": "audio_speech", "input_cost_per_character": 1.5e-5},
        "audio-chat": {"litellm_provider": "maker", "mode": "chat", "input_cost_per_token": 2.5e-6, "output_cost_per_token": 1e-5, "supports_audio_output": true, "supports_audio_input": true}
    });
    let mut table = RateTable::default();
    table.merge_gaps(parse("openrouter", &openrouter));
    table.merge_gaps(parse("openrouter_videos", &videos));
    table.merge_gaps(parse("litellm", &litellm));

    let painter = table.lookup(ANY, "maker/painter");
    assert_eq!(painter.map(|r| r.writes_text()), Some(false));
    assert_eq!(
        painter
            .and_then(|r| r.image_cost(2))
            .map(MoneyMicros::as_micros),
        Some(80_000)
    );
    let chat_painter = table.lookup(ANY, "maker/chat-painter");
    assert_eq!(chat_painter.map(|r| r.writes_text()), Some(true));
    assert_eq!(
        chat_painter
            .and_then(|r| r.output_modalities)
            .map(|m| m.contains(Modality::Image)),
        Some(true)
    );
    assert_eq!(chat_painter.and_then(|r| r.max_output_tokens), Some(32_768));

    let filmer = table.lookup(ANY, "maker/filmer");
    assert_eq!(
        filmer.and_then(|r| r.per_video_second_micros),
        Some(300_000)
    );
    assert_eq!(filmer.and_then(|r| r.max_video_seconds), Some(12));
    assert_eq!(
        filmer
            .and_then(|r| r.video_cost_for(None))
            .map(MoneyMicros::as_micros),
        Some(3_600_000)
    );
    assert_eq!(
        table
            .lookup(ANY, "maker/cents")
            .and_then(|r| r.per_video_second_micros),
        Some(125_000),
        "cents per second are converted to dollars"
    );
    let seed = table.lookup(ANY, "seed-video");
    assert_eq!(seed.and_then(|r| r.per_video_second_micros), Some(120_000));
    assert_eq!(
        seed.and_then(|r| r.input_modalities)
            .map(|m| m.contains(Modality::Image)),
        Some(true)
    );

    let speaker = table.lookup(ANY, "maker/speaker");
    assert_eq!(
        speaker
            .and_then(|r| r.output_modalities)
            .map(|m| m.contains(Modality::Audio)),
        Some(true)
    );
    assert_eq!(table.voice("maker/speaker"), Some("v1"));
    assert_eq!(
        speaker
            .and_then(|r| r.speech_cost(1_000))
            .map(MoneyMicros::as_micros),
        Some(20_000)
    );
    assert_eq!(
        table
            .lookup(ANY, "tts-x")
            .and_then(|r| r.speech_cost(1_000))
            .map(MoneyMicros::as_micros),
        Some(15_000)
    );
    let audio_chat = table.lookup(ANY, "audio-chat");
    assert_eq!(
        audio_chat
            .and_then(|r| r.output_modalities)
            .map(|m| (m.contains(Modality::Text), m.contains(Modality::Audio))),
        Some((true, true))
    );
    assert_eq!(
        audio_chat
            .and_then(|r| r.input_modalities)
            .map(|m| m.contains(Modality::Audio)),
        Some(true)
    );
    assert!(
        table.lookup(ANY, "maker/half-priced-chat").is_none(),
        "a text model without both token prices is unpriced"
    );
}

#[test]
fn the_catalog_lists_every_output_modality() {
    assert!(
        PRICING_SOURCES
            .iter()
            .any(|(name, url)| *name == "openrouter" && url.ends_with("?output_modalities=all"))
    );
    assert!(
        PRICING_SOURCES
            .iter()
            .any(|(name, _)| *name == "openrouter_videos")
    );
}

/// Gemini reports thinking apart from the visible answer and bills both as output
/// (generateContent `thoughtsTokenCount`, Interactions `total_thought_tokens`); `OpenAI`'s
/// `reasoning_tokens` are already inside `output_tokens` and must not count twice.
#[test]
fn gemini_thinking_is_billed_as_output_and_openai_reasoning_is_not_double_counted() {
    use bistre_protocol::{ProviderDialect, UsageMetrics};
    let rates = ModelRates {
        input_per_mtok: 1_000_000,
        output_per_mtok: 10_000_000,
        ..ModelRates::default()
    };
    let usage = UsageMetrics {
        input_tokens: 0,
        output_tokens: 100_000,
        reasoning_tokens: 900_000,
        ..UsageMetrics::default()
    };
    // Gemini: 100k answer + 900k thinking = 1M output tokens = $10.
    assert_eq!(
        rates
            .cost_for_dialect(ProviderDialect::GoogleGemini, &usage)
            .map(MoneyMicros::as_micros),
        Some(10_000_000)
    );
    // OpenAI reports reasoning inside output_tokens: only the 100k output is billed.
    assert_eq!(
        rates
            .cost_for_dialect(ProviderDialect::OpenAi, &usage)
            .map(MoneyMicros::as_micros),
        Some(1_000_000)
    );
}

#[test]
fn cost_bills_cached_input_at_cached_rate() {
    let rates = ModelRates {
        input_per_mtok: 3_000_000,
        output_per_mtok: 15_000_000,
        cached_input_per_mtok: Some(300_000),
        ..ModelRates::default()
    };
    // 1M fresh input = $3, 1M cached = $0.30, 100k output = $1.50.
    let cost = rates.cost(2_000_000, 1_000_000, 100_000);
    assert_eq!(cost.as_micros(), 4_800_000);
}

#[tokio::test(start_paused = true)]
async fn waiting_for_an_unknown_model_without_a_sync_returns_immediately() {
    let registry = PricingRegistry::new();
    // Paused clock: any timed wait would advance virtual time by `REGISTRY_MODEL_WAIT`.
    let started = tokio::time::Instant::now();
    assert!(registry.rates_for(ANY, "nothing").await.is_none());
    assert_eq!(started.elapsed(), Duration::ZERO);
}

#[test]
fn price_cache_round_trips_and_ignores_other_formats() -> Result<(), Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("pricing_cache.json");
    let registry = PricingRegistry::with_cache(path.clone());
    registry.publish(parse(
        "openrouter",
        &json!({"data": [{"id": "vendor/model-a", "architecture": {"output_modalities": ["image", "text"]}, "supported_voices": ["v"], "pricing": {"prompt": "0.000001", "completion": "0.000002", "input_cache_read": "0.0000001"}}]}),
    ));
    registry.save_cache();

    // A new process loads the cache and treats it as a fresh sync (no download needed).
    let reloaded = PricingRegistry::with_cache(path.clone());
    assert_eq!(
        reloaded
            .snapshot()
            .lookup(ANY, "model-a")
            .map(|r| (r.cached_input_per_mtok, r.output_modalities)),
        Some((
            Some(100_000),
            Some(ModalitySet::of(&[Modality::Text, Modality::Image]))
        ))
    );
    let openrouter_scope = CatalogScope::of(&provider(
        ProviderDialect::CustomOpenAi,
        bistre_protocol::dialect::OPENROUTER_BASE_URL,
    ));
    assert!(
        reloaded
            .snapshot()
            .lookup(&openrouter_scope, "vendor/model-a")
            .is_some()
    );
    assert_eq!(reloaded.snapshot().voice("vendor/model-a"), Some("v"));
    assert!(!reloaded.sync_due());

    // A cache written by another format version is ignored and rebuilt.
    std::fs::write(&path, r#"{"format":999,"fetched_at_ms":0,"rates":{}}"#)?;
    let other = PricingRegistry::with_cache(path);
    assert!(other.snapshot().lookup(ANY, "model-a").is_none());
    assert!(other.sync_due());
    Ok(())
}

/// A refresh replaces a known price; a price no source returned stays.
#[test]
fn a_refresh_replaces_known_prices() {
    let mut old = RateTable::default();
    old.merge_gaps(parse(
        "litellm",
        &json!({
            "a": {"input_cost_per_token": 0.000_001, "output_cost_per_token": 0.000_002},
            "only-old": {"input_cost_per_token": 0.000_003, "output_cost_per_token": 0.000_004}
        }),
    ));
    let mut fresh = RateTable::default();
    fresh.merge_gaps(parse(
        "litellm",
        &json!({
            "a": {"input_cost_per_token": 0.000_005, "output_cost_per_token": 0.000_006}
        }),
    ));
    let next = old.refreshed_from(&fresh);
    assert_eq!(
        next.lookup(ANY, "a").map(|r| r.input_per_mtok),
        Some(5_000_000)
    );
    assert_eq!(
        next.lookup(ANY, "only-old").map(|r| r.input_per_mtok),
        Some(3_000_000)
    );
}

/// Each model's output limit comes from the catalog and survives the on-disk cache.
#[test]
fn output_limits_come_from_the_registry() -> Result<(), Box<dyn std::error::Error>> {
    let litellm = json!({"b": {"input_cost_per_token": 0.000_001, "output_cost_per_token": 0.000_002, "max_input_tokens": 200_000, "max_output_tokens": 64_000}});
    assert_eq!(
        parse("litellm", &litellm)
            .first()
            .and_then(|e| e.rates.max_output_tokens),
        Some(64_000)
    );
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("prices.json");
    let registry = PricingRegistry::with_cache(path.clone());
    registry.publish(parse("litellm", &litellm));
    registry.save_cache();
    let reloaded = PricingRegistry::with_cache(path);
    assert_eq!(
        reloaded
            .snapshot()
            .lookup(ANY, "b")
            .and_then(|r| r.max_output_tokens),
        Some(64_000)
    );
    Ok(())
}

#[test]
fn context_limits_come_from_each_source_shape() {
    let openrouter = json!({"data": [{"id": "v/a", "context_length": 128_000, "pricing": {"prompt": "0.000001", "completion": "0.000002"}}, {"id": "v/zero", "context_length": 0, "pricing": {"prompt": "0", "completion": "0"}}]});
    let litellm = json!({"b": {"input_cost_per_token": 0.000_001, "output_cost_per_token": 0.000_002, "max_input_tokens": 200_000}});
    let ctx = |src: &str, doc: &Value, id: &str| {
        parse(src, doc)
            .into_iter()
            .find(|e| e.id == id)
            .and_then(|e| e.rates.context_tokens)
    };
    assert_eq!(ctx("openrouter", &openrouter, "v/a"), Some(128_000));
    assert_eq!(
        ctx("openrouter", &openrouter, "v/zero"),
        None,
        "0 means unreported"
    );
    assert_eq!(ctx("litellm", &litellm, "b"), Some(200_000));
}

#[test]
fn one_malformed_entry_never_drops_the_rest_of_a_list() {
    let openrouter = json!({"data": ["junk", {"id": "x/bad", "pricing": "free"}, {"id": "x/ok", "context_length": "big", "pricing": {"prompt": "0.000001", "completion": {"odd": 1}}}, {"id": "x/good", "architecture": "odd", "pricing": {"prompt": 1e-6, "completion": "0.000002"}}]});
    let litellm = json!({"sample_spec": {"max_tokens": "legacy", "input_cost_per_token": "n/a"}, "broken": "text", "m": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6, "max_tokens": 8192, "mode": 3}});
    let videos = json!({"data": [7, {"id": "v/ok", "pricing_skus": {"duration_seconds": "x", "duration_seconds_720p": "0.1"}, "supported_durations": "all"}]});
    let ids = |v: Vec<CatalogEntry>| v.into_iter().map(|e| e.id).collect::<Vec<_>>();
    assert_eq!(ids(parse("openrouter", &openrouter)), vec!["x/good"]);
    let lite = parse("litellm", &litellm);
    assert_eq!(lite.len(), 1);
    assert_eq!(
        lite.first().and_then(|e| e.rates.context_tokens),
        Some(8192)
    );
    let video = parse("openrouter_videos", &videos);
    assert_eq!(
        video
            .first()
            .map(|e| (e.rates.per_video_second_micros, e.rates.max_video_seconds)),
        Some((Some(100_000), None))
    );
    assert_eq!(parse_source("openrouter", b"not json"), Vec::new());
}

#[test]
fn reasoning_capability_comes_from_each_source_shape() {
    let openrouter = json!({"data": [{"id": "v/think", "supported_parameters": ["reasoning", "tools"], "pricing": {"prompt": "0.000001", "completion": "0.000002"}}, {"id": "v/plain", "supported_parameters": ["tools"], "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]});
    let litellm = json!({"lite": {"input_cost_per_token": 0.000_001, "output_cost_per_token": 0.000_002, "supports_reasoning": true}});
    let flag = |src: &str, doc: &Value, id: &str| {
        parse(src, doc)
            .into_iter()
            .find(|e| e.id == id)
            .and_then(|e| e.rates.reasoning)
    };
    assert_eq!(flag("openrouter", &openrouter, "v/think"), Some(true));
    assert_eq!(flag("openrouter", &openrouter, "v/plain"), Some(false));
    assert_eq!(flag("litellm", &litellm, "lite"), Some(true));

    // A later source fills a field the earlier one lacked, but never overrides it.
    let registry = PricingRegistry::new();
    registry.publish(parse("openrouter", &json!({"data": [{"id": "x/m", "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]})));
    registry.publish(parse("litellm", &json!({"m": {"input_cost_per_token": 9e-6, "output_cost_per_token": 9e-6, "supports_reasoning": true, "max_input_tokens": 1000}})));
    let merged = registry.snapshot().lookup(ANY, "x/m");
    assert_eq!(merged.map(|r| r.input_per_mtok), Some(1_000_000));
    assert_eq!(merged.and_then(|r| r.reasoning), Some(true));
    assert_eq!(merged.and_then(|r| r.context_tokens), Some(1000));
}

fn anthropic_rates() -> ModelRates {
    ModelRates {
        input_per_mtok: 10_000_000,                // $10 / 1M
        output_per_mtok: 20_000_000,               // $20 / 1M
        cached_input_per_mtok: Some(1_000_000),    // $1 / 1M
        cache_write_per_mtok: Some(12_500_000),    // $12.50 / 1M (5-minute TTL)
        cache_write_1h_per_mtok: Some(20_000_000), // $20 / 1M (1-hour TTL)
        reasoning_per_mtok: None,
        context_tokens: Some(200_000),
        reasoning: Some(true),
        ..ModelRates::default()
    }
}

#[test]
fn anthropic_cache_cost_is_additive_and_prices_cache_creation() {
    let rates = anthropic_rates();
    let usage = bistre_protocol::UsageMetrics {
        input_tokens: 100_000,                // $1.00 fresh
        cached_input_tokens: 1_000_000,       // $1.00 cache read
        cache_creation_input_tokens: 400_000, // 0.4M * $12.50 = $5.00 cache write (5m)
        output_tokens: 100_000,               // $2.00 output
        ..bistre_protocol::UsageMetrics::default()
    };
    // Anthropic: additive ($1 + $1 + $5 + $2 = $9.00 = 9_000_000 micros).
    let anth = rates.cost_for_dialect(ProviderDialect::Anthropic, &usage);
    assert_eq!(anth.map(MoneyMicros::as_micros), Some(9_000_000));

    // OpenAI: input_tokens includes cached_input_tokens.
    let oai_usage = bistre_protocol::UsageMetrics {
        input_tokens: 1_000_000,
        cached_input_tokens: 800_000, // 200k fresh ($2) + 800k cached ($0.80)
        output_tokens: 100_000,       // $2.00
        ..bistre_protocol::UsageMetrics::default()
    };
    let oai = rates.cost_for_dialect(ProviderDialect::OpenAi, &oai_usage);
    assert_eq!(oai.map(MoneyMicros::as_micros), Some(4_800_000));
}

/// 1-hour cache writes are billed at the 1-hour rate from the registry, split by the
/// `usage.cache_creation` TTL breakdown; an unknown write rate makes the cost unknown.
#[test]
fn anthropic_one_hour_cache_writes_use_their_own_rate_or_fail_closed() {
    let mut usage = bistre_protocol::UsageMetrics::default();
    crate::wire_parse::merge_sse_usage(
        ProviderDialect::Anthropic,
        r#"{"type":"message_start","message":{"usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":400000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":400000}}}}"#,
        &mut usage,
    );
    assert_eq!(usage.cache_creation_1h_input_tokens, 400_000);
    let rates = anthropic_rates();
    // 0.4M * $20 = $8.00, not 0.4M * $12.50 = $5.00.
    assert_eq!(
        rates
            .cost_for_dialect(ProviderDialect::Anthropic, &usage)
            .map(MoneyMicros::as_micros),
        Some(8_000_000)
    );
    let no_1h_rate = ModelRates {
        cache_write_1h_per_mtok: None,
        ..rates
    };
    assert_eq!(
        no_1h_rate.cost_for_dialect(ProviderDialect::Anthropic, &usage),
        None,
        "an unknown 1-hour write rate is an unknown price, never a guessed multiplier"
    );
    // An unknown read rate bills reads at the full input rate (upper bound, no guess).
    let reads = bistre_protocol::UsageMetrics {
        cached_input_tokens: 1_000_000,
        ..bistre_protocol::UsageMetrics::default()
    };
    let no_read_rate = ModelRates {
        cached_input_per_mtok: None,
        ..rates
    };
    assert_eq!(
        no_read_rate
            .cost_for_dialect(ProviderDialect::Anthropic, &reads)
            .map(MoneyMicros::as_micros),
        Some(10_000_000)
    );
}

#[test]
fn every_source_reports_cache_write_rates() {
    let openrouter = json!({"data": [{"id": "a/m", "pricing": {"prompt": "0.00001", "completion": "0.00002", "input_cache_write": "0.0000125", "input_cache_write_1h": "0.00002"}}]});
    let litellm = json!({"l": {"input_cost_per_token": 1e-5, "output_cost_per_token": 2e-5, "cache_creation_input_token_cost": 1.25e-5, "cache_creation_input_token_cost_above_1hr": 2e-5}});
    let write = |v: &[CatalogEntry]| {
        v.first().map(|e| {
            (
                e.rates.cache_write_per_mtok,
                e.rates.cache_write_1h_per_mtok,
            )
        })
    };
    assert_eq!(
        write(&parse("openrouter", &openrouter)),
        Some((Some(12_500_000), Some(20_000_000)))
    );
    assert_eq!(
        write(&parse("litellm", &litellm)),
        Some((Some(12_500_000), Some(20_000_000)))
    );
}

#[test]
fn media_models_list_their_choices_and_a_chosen_length_sets_the_price() {
    let images = json!({"data": [
        {"id": "maker/chat-painter", "architecture": {"output_modalities": ["image", "text"]}, "supported_parameters": {"aspect_ratio": {"type": "enum", "values": ["auto", "1:1", "9:19.5", "1:1", "wide", "16:9"]}, "resolution": {"type": "enum", "values": ["1K", "4K", "<b>"]}}},
        {"id": "maker/painter", "architecture": {"output_modalities": ["image"]}, "supported_parameters": {"aspect_ratio": {"type": "enum", "values": ["1:1"]}}},
        {"id": "maker/odd", "supported_parameters": {"aspect_ratio": {"type": "number"}}}
    ]});
    let videos = json!({"data": [{"id": "maker/filmer", "supported_durations": [-1, 8, 4, 8], "supported_aspect_ratios": ["16:9", "9:16"], "supported_resolutions": ["720p"], "pricing_skus": {"duration_seconds_720p": "0.10"}}]});
    let chat = json!({"data": [{"id": "maker/chat-painter", "architecture": {"output_modalities": ["image", "text"]}, "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]});
    let mut table = RateTable::default();
    table.merge_gaps(parse("openrouter", &chat));
    table.merge_gaps(parse("openrouter_images", &images));
    table.merge_gaps(parse("openrouter_videos", &videos));

    let chat_painter = table.extras("maker/chat-painter");
    assert_eq!(
        chat_painter.map(|e| e.aspect_ratios.clone()),
        Some(vec![
            "1:1".to_owned(),
            "9:19.5".to_owned(),
            "16:9".to_owned()
        ]),
        "auto and malformed shapes are dropped, repeats kept once"
    );
    assert_eq!(
        chat_painter.map(|e| e.resolutions.clone()),
        Some(vec!["1K".to_owned(), "4K".to_owned()])
    );
    assert_eq!(
        table
            .lookup(ANY, "maker/chat-painter")
            .map(|r| r.output_per_mtok),
        Some(2_000_000),
        "the choice list never replaces token prices"
    );
    assert_eq!(
        table.extras("painter").map(|e| e.aspect_ratios.len()),
        Some(1)
    );
    assert_eq!(table.extras("maker/odd"), None);

    let filmer = table.extras("maker/filmer");
    assert_eq!(
        filmer.map(|e| e.durations_s.clone()),
        Some(vec![4, 8]),
        "-1 (model decides) is no choice"
    );
    assert_eq!(
        filmer.map(|e| e.resolutions.clone()),
        Some(vec!["720p".to_owned()])
    );
    let rates = table.lookup(ANY, "maker/filmer");
    assert_eq!(
        rates
            .and_then(|r| r.video_cost_for(Some(4)))
            .map(MoneyMicros::as_micros),
        Some(400_000)
    );
    assert_eq!(
        rates
            .and_then(|r| r.video_cost_for(None))
            .map(MoneyMicros::as_micros),
        Some(800_000)
    );
}

/// A reply's picture and sound tokens are billed at the catalog's own rates for them, the
/// rest of the reply at the text rate; without those rates the text rate holds.
#[test]
fn picture_and_sound_tokens_in_a_reply_use_their_own_rates() {
    let doc = json!({"img-model": {"input_cost_per_token": 0, "output_cost_per_token": 1e-6,
        "output_cost_per_image_token": 3e-5, "output_cost_per_audio_token": 2e-5}});
    let rates = parse("litellm", &doc).first().map_or_default(|e| e.rates);
    assert_eq!(rates.image_output_per_mtok, Some(30_000_000));
    let mut usage = bistre_protocol::UsageMetrics::default();
    crate::wire_parse::merge_sse_usage(
        ProviderDialect::GoogleGemini,
        r#"{"usageMetadata":{"promptTokenCount":0,"candidatesTokenCount":2000,"candidatesTokensDetails":[{"modality":"TEXT","tokenCount":1000},{"modality":"IMAGE","tokenCount":1000}]}}"#,
        &mut usage,
    );
    assert_eq!(usage.output_image_tokens, 1000);
    // 1,000 text tokens at $1/M plus 1,000 picture tokens at $30/M.
    assert_eq!(
        rates
            .cost_for_dialect(ProviderDialect::GoogleGemini, &usage)
            .map(MoneyMicros::as_micros),
        Some(31_000)
    );
    let mut voice = bistre_protocol::UsageMetrics::default();
    crate::wire_parse::merge_sse_usage(
        ProviderDialect::CustomOpenAi,
        r#"{"usage":{"prompt_tokens":0,"completion_tokens":1000,"completion_tokens_details":{"audio_tokens":600}}}"#,
        &mut voice,
    );
    assert_eq!(voice.output_audio_tokens, 600);
    assert_eq!(
        rates
            .cost_for_dialect(ProviderDialect::CustomOpenAi, &voice)
            .map(MoneyMicros::as_micros),
        Some(12_400)
    );
    let text_only = ModelRates {
        image_output_per_mtok: None,
        ..rates
    };
    assert_eq!(
        text_only
            .cost_for_dialect(ProviderDialect::GoogleGemini, &usage)
            .map(MoneyMicros::as_micros),
        Some(2_000)
    );
}
