# ADR-0005: Stateless Local-Canonical LLM Defaults & Reversible Branch-Safe Compaction

- **Status**: Accepted
- **Date**: 2026-11-21
- **Deciders**: Bistre Principal Architecture

## Context & Live-Verified Evidence
- Live API verification (Nov 2026):
  - **Gemini Interactions API** (`/v1beta/interactions`, GA June 2026) stores interactions by default (`store=true`: 55 days paid / 1 day free); `store=false` disables `previous_interaction_id` & `background=true`; explicit caching (`cachedContents`) is not yet available in Interactions.
  - **OpenAI Responses API** (`/v1/responses`) defaults `store: true` (30d TTL) and returns opaque encrypted compaction items (`not intended to be human-interpretable`).
  - **Anthropic Messages API** (`/v1/messages`) is stateless by default with automatic caching (Feb 2026), readable compaction (Sept 2026), and model-bound `thinking.signature` blocks that must be stripped on model switches.
  - Sept 2026 research (*The Compaction Cliff*, arXiv:2608.22752; *Compaction as Epistemic Failure*, arXiv:2607.13071) proves repeated lossy compaction erodes safety constraints and fabricates completion claims from killed commands.

## Decision
1. Default **`store: false`** across all provider dialects (OpenAI Responses with `include: ["reasoning.encrypted_content"]`, Gemini Interactions with canonical replay, Anthropic Messages).
2. Store reasoning/thinking signatures tagged with `(provider_id, model_id)` in `nodes.provider_meta_json` and automatically strip foreign signatures whenever switching providers or models.
3. Expose an explicit opt-in per-provider **"Server State Cache"** toggle (`store: true` + `previous_response_id`/`previous_interaction_id`) treated strictly as disposable cache acceleration with automatic stateless fallback on branch/edit/404/expiry.
4. Perform **local reversible branch-safe compaction**: write readable `compaction_summary` DAG nodes linked to immutable raw SQLite evidence; keep safety rules, tool approvals, and command receipts pinned outside summaries.

## Rejected Alternatives
- **Relying solely on server-side `previous_response_id` / `previous_interaction_id`**: Violates local-first ownership, breaks mid-conversation branching/provider switching, and retains private data on third-party servers by default.

## Consequences & Verification
- Full session inspection, export, cross-provider replay, and deletion remain 100% under user control.
- Verified via provider adapter unit tests asserting `store: false` default, cross-model signature stripping, and non-destructive compaction DAG nodes.
