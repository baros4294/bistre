# ADR-0006: MCP `2026-07-28` Stateless Core via `rmcp` with Legacy Dual-Negotiation

- Status: Accepted; §Decision 1 (`rmcp`) superseded by `ADR-0018`
- Deciders: Bistre Principal Architecture

## Context & Live-Verified Evidence
- MCP specification revision `2026-07-28` (`modelcontextprotocol.io/specification/2026-07-28/changelog`) fundamentally redesigned MCP into a stateless protocol: removed `initialize`/`notifications/initialized` handshake, `Mcp-Session-Id`, `ping`, and SSE `Last-Event-ID`; added `server/discover`, `subscriptions/listen`, MRTR `resultType: "input_required"`, `Mcp-Method`/`Mcp-Name` headers, `ttlMs`/`cacheScope`, and `io.modelcontextprotocol/tasks`; deprecated Roots, Sampling, Logging, HTTP+SSE, and OAuth DCR.
- Official Rust SDK `rmcp 3.11.0` (`modelcontextprotocol/rust-sdk`) implements `2026-07-28` natively, including non-blocking `stdio_pipes` and abandoned call cancellation.
- Many existing community MCP servers still speak `2025-11-25` or `2025-03-26`, and poorly behaved stdio servers print log lines to `stdout`.

## Decision
1. Adopt official `rmcp 3.11.0` in `crates/bistre-core` targeting `2026-07-28` as primary transport (stdio + Streamable HTTP).
2. Auto-negotiate version via `server/discover` probe first, falling back transparently to `2025-11-25` / `2025-03-26` initialization handshake for legacy servers.
3. Do not implement deprecated Roots, Sampling, Logging, or HTTP+SSE transports.
4. Drain child `stderr` continuously into a bounded ring buffer, quarantine non-JSON `stdout` lines into server diagnostics instead of failing framing, cap tool outputs (both bounds: Spec 04), and sort tool lists deterministically for LLM prompt-cache hits.

## Rejected Alternatives
- Targeting only 2025-03-26/2025-11-25: Immediately obsolete against 2026 stateless servers and MRTR tool workflows.
- Hand-rolling JSON-RPC from scratch: Duplicates `rmcp`'s OAuth/MRTR/schema validation maintenance surface.

## Consequences & Verification
- Supports both modern stateless `2026-07-28` servers and legacy community MCP servers.
- Verified via mock stdio/HTTP integration tests covering `server/discover`, legacy fallback, MRTR `input_required`, and noisy `stdout`/`stderr` flood resilience.
