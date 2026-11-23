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
- Zero hardcoded model rates: cost comes from a single-flight, detached background sync of four public catalogs in priority order — OpenRouter `GET /api/v1/models` (`pricing.prompt|completion|input_cache_read`, USD per token), Vercel AI Gateway `GET /v1/models` (`pricing.input|output`), LiteLLM `model_prices_and_context_window.json` (`input_cost_per_token`, `output_cost_per_token`), and `models.dev/api.json` (`cost.input|output|cache_read`, USD per 1M tokens). Formats verified live on 2026-11-23.
- Earlier sources win; later ones fill gaps; each source publishes incrementally via `tokio::sync::watch`. Freshness TTL `30 min`, empty-sync cooldown `60 s`, at most a `2.5 s` wait for one model's rate (the download is never cancelled).
- Prices convert once, with integer decimal parsing only, to `MoneyMicros` per 1M tokens (JSON floats are re-read from their shortest decimal text, never multiplied as `f64`). Unknown models are `cost_known: false` (never a guessed rate); loopback providers are always `$0`.
- Catalog GETs run through `PublicWebTransport`, carry no identifiers, and start only when a non-loopback provider streams.

## Pricing Refresh Policy (2026-11-23)
- Public price lists (`PRICING_SOURCES` in `crates/bistre-core/src/registry.rs`) are fetched at most once per `24 h`: at engine start when `AppSettings.pricing_auto_refresh` is on (default), or when the user presses **Update prices now** (Settings → Safety & Budget). A run never starts a fetch.
- The merged table is cached in `<data_dir>/pricing_cache.json` with `PRICE_CACHE_FORMAT`; a cache from another format version is ignored and rebuilt, and a fresh cache counts as the last successful sync. Writes are atomic (temp → `sync_all` → rename).
- With automatic updates off and no cache, unknown prices show the quiet "price unavailable" info and count as `$0` toward the daily limit (Spec 06).
- Each entry also records the model's conversation limit when its source reports one (`context_length`, `context_window`, `max_input_tokens`, `limit.context`); `EngineClient::model_context_tokens` serves it to the composer ring. The cache format is `2`.

## Reasoning Capability (2026-11-24)
`ModelRates.reasoning` records whether a model accepts a thinking effort, taken from each public list:
- `OpenRouter` `supported_parameters` contains `reasoning`;
- Vercel `tags` contains `reasoning`;
- `LiteLLM` `supports_reasoning`;
- models.dev `reasoning`.

Earlier sources win per field, and later sources fill fields an earlier one lacked. A lookup by `vendor/model` also fills missing fields from the plain `model` entry. The cache gains a fifth column, so `PRICE_CACHE_FORMAT` is 3 and older caches rebuild. Test: `registry::tests::reasoning_capability_comes_from_each_source_shape`.
