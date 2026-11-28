# ADR-0019: One Media Protocol for Image, Audio, and Video Input and Output

- Status: Accepted
- Deciders: Bistre owner

## Context & Live-Verified Evidence
- Bistre sent images (and, on Gemini, audio and video) but kept only text from replies. A model that draws, speaks, or films had no route, and a media-only model was sent to a chat endpoint it does not serve.
- The catalog fetched `OpenRouter`'s bare `/api/v1/models`, which lists text models only: 477 entries against 741 with `?output_modalities=all`, 264 of them media-only. models.dev holds per-token costs only.
- A model's own catalog entry names what it reads and writes (`OpenRouter` `architecture.input_modalities|output_modalities`, `LiteLLM` `mode`, `supported_modalities`, `supported_output_modalities`) and its media units (`LiteLLM` `output_cost_per_image`, `output_cost_per_second*`, `input_cost_per_character`; `OpenRouter` `/api/v1/videos/models` `pricing_skus`).
- Live API shapes (Spec 02 §7): Chat Completions `modalities` with `delta.images` and `delta.audio`; Gemini `inlineData` parts and Interactions `response_format: video`; `/images` (`OpenRouter`) and `/images/generations` (`OpenAI`-shaped, `ModelArk` Seedream); video jobs on `/videos` (`OpenRouter`) and `/contents/generations/tasks` (`ModelArk` Seedance). The `OpenAI` Videos API and Gemini Imagen and Veo preview are shut down.

## Decision
1. Capabilities come from the catalog only: no model id, voice, or price is written in code. A model with no catalog entry is a text model.
2. One route rule: a model that writes text answers in chat, and the request asks for the other kinds it writes (`modalities`); a model that writes no text answers through its media API: video, else image, else speech. Gemini image models answer in chat. `OpenAI` Responses writes no audio, so a speaking model is sent to Chat Completions on the same host.
3. One internal form (`media_wire::GeneratedMedia`, `MediaRef`): every reply shape is read into it, bounded per reply (Spec 02 §7), and stored as content-addressed attachments on the assistant reply.
4. Video is a job: submit, poll, download (interval and limit: Spec 02 §7). An `OpenAI`-shaped provider that answers 404 or 405 on `/videos` is asked on the task API.
5. Wallet Shield (ADR-0009): the reservation, written before the request, is the catalog price of one image, the text read aloud, or the longest video at the dearest per-second rate; a provider-reported cost settles it. Once a request is sent, a failure or a stop books the reservation as `unconfirmed` or `cancelled`. Media requests are never retried.
6. A result URL on the provider's own host is fetched with its key; any other URL goes through `PublicWebTransport` with no credentials.
7. Format (picture shape, size, video length) is one setting for every chat, like the thinking level. Each value goes only to a model whose catalog entry lists it, in that API's field names; the composer offers only the listed values, shapes drawn at their true proportions. Controls follow what the model does: Thinking for a model that writes text, Format for one with listed choices, both for a model that thinks and draws.
8. A reply's generated files go back to the model with the next user message, the one form every dialect takes, for the kinds the model reads. A Gemini reply whose every picture part carried a `thoughtSignature` sends them back as its own parts instead, with those signatures, when the target may replay that reply's reasoning (Spec 02 §7).
9. A submitted video job is kept (`media_jobs.rs`, `kv_meta` `media.video_jobs`, at most 16) until it is fetched or the provider fails it. A launch books each job a crash cut off under its turn's request id, so one settled before the crash is not booked twice; Try again on the same message with the same model, within 24 h of the start, polls that job and reserves nothing more. A stop or a broken wait keeps the job the same way.

## Not Built
- In-app audio and video playback: WAV plays on Windows and Android; any other sound or video opens in its default app (on Android, the app the user picks).

## Rejected Alternatives
- A per-provider or per-model media table: it goes stale with every release and breaks "never hardcode".
- The fal.ai queue schemas as the shared shape: one aggregator's format, and no provider Bistre speaks uses it.
- A media player package: no such dependency without an owner request (AGENTS §3).

## Consequences & Verification
- `PRICE_CACHE_FORMAT` 8 (per-call fees and picture and sound token rates); Vercel and models.dev are no longer fetched.
- Tests: `media_wire::tests` (format settings per wire, carried files), `media_gen::tests` (image, video job, unpriced block, chat pictures, `try_again_fetches_a_broken_video_job_instead_of_paying_again`), `media_jobs::tests`, `gemini_signature_tests::{each_picture_part_keeps_its_signature, a_signed_picture_is_replayed_as_the_models_own_part}`, `registry::tests::{media_models_carry_their_modalities_and_units, media_models_list_their_choices_and_a_chosen_length_sets_the_price}`, `request_body::tests::picture_settings_reach_chat_requests_for_models_that_draw`, `mime_sniff::tests`, `registry::tests::picture_and_sound_tokens_in_a_reply_use_their_own_rates` (a reply's picture and sound tokens at LiteLLM `output_cost_per_image_token` and `output_cost_per_audio_token`, else the text rate), `apps/bistre_app/test/composer_media_options_test.dart`.
