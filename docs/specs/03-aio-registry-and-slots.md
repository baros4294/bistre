# Spec 03 — Synthesized AIO Model Registry & Task Slots

## 1. Zero Hardcoded Models
Bistre ships zero hardcoded model IDs or pricing tables in application binaries. The registry synthesizer in `crates/bistre-core` merges live and signed Track-A catalog layers deterministically:
1. **Signed Baseline Catalog Pack (Track A)**: Offline `minisign`-verified snapshot shipped/updated independently of app binaries.
2. **Upstream Catalog Sources**:
   - OpenRouter (`/api/v1/models`) — capabilities, context length, pricing
   - `models.dev` (`api.json`, schema v2) — modalities, limits, release metadata
   - `fal.ai` Platform Models v1 + OpenAPI 3.1 queue schemas (`https://fal.ai/api/openapi/queue/openapi.json`) — typed image/video/audio input & output parameters
   - LiteLLM pricing metadata (`model_prices_and_context_window.json`) — fallback token pricing
3. **Local Endpoint Probes ($0 Priority)**:
   - Ollama (`/api/tags` + `/api/show`)
   - llama.cpp server (`/v1/models` + `/props`)
   - ComfyUI (`/object_info`)
4. **User Overrides**: Explicit per-model aliases, custom pricing (`MoneyMicros`), context limits, and endpoint overrides stored locally in SQLite.

## 2. Deterministic Merge Precedence
`User Override > Local Endpoint Probe > Live Provider /models > Upstream Aggregator > Signed Baseline Pack`.
All merged pricing is normalized into exact integer `MoneyMicros(i64)` per 1M tokens (or per media unit) at ingest time; invalid/NaN values are rejected.

## 3. Dedicated AIO Task Slots
Each workspace/profile binds models by capability slot rather than a single global dropdown:
- `chat_primary`, `code_agent`, `write_roleplay`, `fast_cheap`, `compaction_summarizer`, `inline_translate`
- Wave 2/3 AIO slots: `stt_transcribe`, `tts_speech`, `image_generate_edit`, `video_generate_edit`, `voice_full_duplex`.
When Wallet Shield "$0 Local Priority" is enabled, local probed models satisfying slot capabilities are ranked first.

## Live Pricing Registry (`crates/bistre-core/src/registry.rs`)
- Zero hardcoded model rates: cost comes from a single-flight, detached background sync of four public catalogs in priority order — OpenRouter `GET /api/v1/models` (`pricing.prompt|completion|input_cache_read|input_cache_write|input_cache_write_1h`, USD per token), Vercel AI Gateway `GET /v1/models` (`pricing.input|output`, plus the same cache fields when present `[UNVERIFIED]`), LiteLLM `model_prices_and_context_window.json` (`input_cost_per_token`, `output_cost_per_token`, `cache_read_input_token_cost`, `cache_creation_input_token_cost`, `cache_creation_input_token_cost_above_1hr`), and `models.dev/api.json` (`cost.input|output|cache_read|cache_write`, USD per 1M tokens). Formats verified live on 2026-11-23; cache-write fields verified live on 2026-11-25 (OpenRouter and LiteLLM docs).
- Within one refresh earlier sources win and later ones fill gaps; the refresh as a whole replaces the prices known before it (W8: "Update prices now" never changed a known price), and ids no source returned this time keep their old price (`RateTable::refreshed_from`, test `a_refresh_replaces_known_prices`); each source publishes incrementally via `tokio::sync::watch`. Freshness TTL `24 h` (`REGISTRY_TTL`; AGENTS: fetched at most once per 24 h), empty-sync cooldown `60 s`, at most a `2.5 s` wait for one model's rate (the download is never cancelled).
- Prices convert once, with integer decimal parsing only, to `MoneyMicros` per 1M tokens (JSON floats are re-read from their shortest decimal text, never multiplied as `f64`). Unknown models are `cost_known: false` (never a guessed rate); loopback providers are always `$0`.
- Catalog GETs run through `PublicWebTransport`, carry no identifiers, and start only when a non-loopback provider streams.

## Pricing Refresh Policy (2026-11-23)
- Public price lists (`PRICING_SOURCES` in `crates/bistre-core/src/registry.rs`) are fetched at most once per `24 h`: at engine start when `AppSettings.pricing_auto_refresh` is on (default), or when the user presses **Update prices now** (Settings → Safety & Budget). A run never starts a fetch.
- The merged table is cached in `<data_dir>/pricing_cache.json` with `PRICE_CACHE_FORMAT`; a cache from another format version is ignored and rebuilt, and a fresh cache counts as the last successful sync. Writes are atomic (temp → `sync_all` → rename).
- With automatic updates off and no cache, unknown prices show the quiet "price unavailable" info; while a spending cap is active such a request is blocked until the user allows it once (Spec 06 "Unknown prices").
- Each entry also records the model's conversation limit when its source reports one (`context_length`, `context_window`, `max_input_tokens`, `limit.context`); `EngineClient::model_context_tokens` serves it to the composer ring. The cache format is `2`.

## Reasoning Capability (2026-11-24)
`ModelRates.reasoning` records whether a model accepts a thinking effort, taken from each public list:
- `OpenRouter` `supported_parameters` contains `reasoning`;
- Vercel `tags` contains `reasoning`;
- `LiteLLM` `supports_reasoning`;
- models.dev `reasoning`.

Earlier sources win per field, and later sources fill fields an earlier one lacked. A lookup by `vendor/model` also fills missing fields from the plain `model` entry. The cache holds seven columns (input, output, cache read, context, reasoning, 5-minute cache write, 1-hour cache write), so `PRICE_CACHE_FORMAT` is 4 and older caches rebuild. Test: `registry::tests::reasoning_capability_comes_from_each_source_shape`.

## Model resolution order (owner decision 2026-11-26)
- A run's provider and model come from, in order: the chat's own (a provider pinned by the chat or its assistant must be usable or the run fails), the assistant's default, Settings > Default models, the model last picked in Settings > Providers, then the provider's default model. The chat's model picker sets the open chat's own model, so the Default-models setting stays the default for every other chat. The context breakdown resolves the model in the same order. Tests: `egress_tests::the_default_model_setting_wins_over_the_last_pick`, `apps/bistre_app/test/picker_sets_chat_model_test.dart`.
