# ADR-0005: Stateless Local-Canonical LLM Defaults & Reversible Branch-Safe Compaction

- Status: Accepted
- Deciders: Bistre Principal Architecture

## Context & Live-Verified Evidence
- Live API verification (Nov 2026):
  - Gemini Interactions API (`/v1beta/interactions`, GA June 2026) stores interactions by default (`store=true`: 55 days paid / 1 day free); `store=false` disables `previous_interaction_id` & `background=true`; explicit caching (`cachedContents`) is not yet available in Interactions.
  - OpenAI Responses API (`/v1/responses`) defaults `store: true` (30d TTL) and returns opaque encrypted compaction items (`not intended to be human-interpretable`).
  - Anthropic Messages API (`/v1/messages`) is stateless by default with automatic caching (Feb 2026), readable compaction (Sept 2026), and model-bound `thinking.signature` blocks that must be stripped on model switches.
  - Sept 2026 research (The Compaction Cliff, arXiv:2608.22752; Compaction as Epistemic Failure, arXiv:2607.13071) proves repeated lossy compaction erodes safety constraints and fabricates completion claims from killed commands.

## Decision
1. Default `store: false` across all provider dialects (OpenAI Responses with `include: ["reasoning.encrypted_content"]`, Gemini Interactions with canonical replay, Anthropic Messages).
2. Store reasoning/thinking signatures tagged with `(provider_id, model_id)` in `nodes.provider_meta_json` and automatically strip foreign signatures whenever switching providers or models.
3. Expose an explicit opt-in per-provider "Server State Cache" toggle (`store: true` + `previous_response_id`/`previous_interaction_id`) treated strictly as disposable cache acceleration with automatic stateless fallback on branch/edit/404/expiry.
4. Perform local reversible branch-safe compaction: write readable `compaction_summary` DAG nodes linked to immutable raw SQLite evidence; keep safety rules, tool approvals, and command receipts pinned outside summaries.
5. Recall stays lossless: a summary replaces earlier messages only in the prompt. While a summary leads the sent history, the model gets two Tier-0 tools (`history_recall.rs`): `history_search` finds the condensed messages (every query word, any case, up to 20 matches with ids) and `history_open` returns any saved message of the branch in full, 8,000 characters per part with an `offset` to read on. Both respect the context-start pin and a tool set to Off. This follows the lossless-context design (immutable store, summaries as a derived cache, retrieval tools); Bistre keeps one flat summary per compaction rather than a summary tree.
6. The user owns the summary: `/compact <words>` passes the words to the Summary model as what to keep (at most 1,000 characters; the offline summary cannot follow them), and Edit on the summary card replaces its text in place (`rewrite_compaction_summary`, trimmed, 1 to 24,000 characters; only `compaction_summary` rows can be rewritten, its kept-message link stays). Undo still removes the summary.

## Rejected Alternatives
- Relying solely on server-side `previous_response_id` / `previous_interaction_id`: Violates local-first ownership, breaks mid-conversation branching/provider switching, and retains private data on third-party servers by default.

## Consequences & Verification
- Full session inspection, export, cross-provider replay, and deletion remain 100% under user control.
- Verified via provider adapter unit tests asserting `store: false` default, cross-model signature stripping, and non-destructive compaction DAG nodes; recall and summary editing by `history_recall::tests`, `egress_tests::compaction_follows_the_users_words_and_the_edited_summary_is_sent`, `bistre-storage` `only_a_compaction_summary_can_be_rewritten`, and `apps/bistre_app/test/compaction_summary_test.dart`.
