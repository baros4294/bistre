# ADR-0018: MCP Over Streamable HTTP Without an SDK (Supersedes ADR-0006 §Decision 1)

- **Status**: Accepted
- **Date**: 2026-11-23
- **Deciders**: Bistre owner (hardening plan Q3)

## Context & Live-Verified Evidence
- ADR-0006 adopted `rmcp 3.11.0`, but the shipped client used it only to deserialize `rmcp::model::Tool`; all transport, negotiation, and session code was already Bistre's own (`crates/bistre-core/src/mcp.rs`). That single type pulled about 85 transitive crates (including a second `sha2`/`digest` major version) into every build.
- No stdio MCP transport exists yet, so the stdio helpers (stderr ring, stdout quarantine) had no production caller.
- The MCP `2026-07-28` specification (final on 2026-07-28) keeps the `Tool` object fields Bistre reads: `name`, `description`, `inputSchema`, and `ttlMs` (top level or in `_meta`).

## Decision
1. Drop `rmcp`. Parse tools with a private `WireTool` struct holding only the fields above; entries without a string `name` are skipped; the list is sorted and de-duplicated by name.
2. Keep ADR-0006 §Decision 2–4 (dual negotiation `2026-07-28` → `2025-11-25`, no deprecated features, bounded results, deterministic tool order) unchanged.
3. Remove the unused stdio helpers. When the stdio-MCP slice lands, it re-adds the 64 KiB stderr ring and stdout quarantine with its transport, and re-evaluates `rmcp` then (AGENTS.md §7 keeps those invariants as targets).

## Rejected Alternatives
- **Keep `rmcp` for one type**: about 85 crates and a duplicated hash stack for a five-field struct.
- **Adopt `rmcp` fully now**: pulls the stdio slice, OAuth, and MRTR into this change; out of scope for a hardening pass.

## Consequences & Verification
- `Cargo.lock` loses 205 lines of transitive crates; `cargo deny --locked check` passes.
- `crates/bistre-core/src/mcp.rs` tests cover sorting, nameless entries, `_meta.ttlMs`, the default `inputSchema`, and dual negotiation against a loopback server.
