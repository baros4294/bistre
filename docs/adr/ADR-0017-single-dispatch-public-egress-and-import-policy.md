# ADR-0017: Single Provider Dispatch, Public Egress Transport & Untrusted-Import Policy

- Status: Accepted
- Deciders: Bistre Principal Architecture

## Context
- Provider requests, model listing, web fetches, and remote MCP calls each built their own `reqwest` request: one key per provider, 401/403 failed instantly, the only HTTP 400 recovery was the Gemini downgrade, a single 45 s read timeout killed slow-first-token reasoning models, and an SSE stream that ended without its terminal event looked complete.
- `web_fetch` reused the provider client: it followed redirects, honored proxy environment variables, did no IP checks (DNS rebinding / cloud-metadata SSRF), and buffered whole bodies before truncating.
- Cost estimates came from a hardcoded model-name substring table, contradicting the zero-hardcoded-model rule.
- Imported character cards were trusted verbatim; the desktop open-folder bridge passed any path (including executables and `\\server\share` UNC paths that leak NTLM hashes) to `ShellExecuteW`.
- `bistre-core` must stay free of `unsafe` and of new third-party crates for these concerns.

## Decision
1. One dispatch path (`providers::dispatch`) for chat and `/models`: credential-free `WireRequest`s, round-robin multi-key rotation with instant 401/403/429 failover (`credentials.rs`), an ordered data-driven HTTP 400 heal ladder (`error_policy.rs`, `MAX_HTTP_400_HEALS = 6`), the Gemini downgrade as a one-time fallback, and typed failures carrying server retry hints.
2. `SseFramer` (`sse.rs`) replaces `SseFrameBuffer`, with 300 s / 90 s dual idle timeouts and terminal-event detection per dialect (`ProviderStreamInterrupted`, never silent truncation). The run loop owns retries: backoff with a `Notify`-backed `Retry now`, one in-flight reversible compaction on context overflow, and no retry after partial output.
3. `PublicWebTransport` (`ssrf.rs`) is the only client for model-directed and catalog traffic: DNS-time public-IP pinning, `.no_proxy()`, manual re-validated redirects, IANA special-purpose exclusions, streamed caps, fail-closed construction. MCP over HTTP routes loopback hosts to a no-redirect local client and everything else through it; an MCP listen stream uses a second client with the same rules and no read timeout, limited per request.
4. Live pricing registry (`registry.rs`): single-flight background sync of OpenRouter (every output kind, and its video price list) → LiteLLM (ADR-0019), integer-only conversion to `MoneyMicros`, unknown models are `cost_known: false`.
5. Untrusted imports pass `import_policy::with_imported_permissions`; OS hand-off goes through `process_util` (blocked extensions, `http(s)`-only links) and a directory-only native open-folder bridge.
6. Process creation is centralized in `process_util::no_window_command` (`CREATE_NO_WINDOW`, process group, scrubbed keys, tree kill on timeout), enforced by `just guard` and `clippy.toml` `disallowed-methods`.
7. Tool dispatch claims a one-use `ToolExecutionPermit` from `approval::ToolApprovalBroker`; settings changes revoke all permits synchronously.

## Rejected Alternatives
- A third-party SSRF/egress crate or `hickory` resolver: adds dependency weight for logic that fits in one audited module over `reqwest`'s `Resolve` trait.
- Win32 Job Objects inside `bistre-core`: requires `unsafe`; deferred to an audited shim crate (tracked open gap in Spec 04 and `SECURITY.md`).
- Shipping a bundled price table: rots within weeks and silently mis-bills; a live registry with explicit "unknown" is honest.
- Floating-point registry math: violates the `MoneyMicros` invariant; decimal text is parsed exactly instead.

## Consequences & Verification
- Catalog GETs contact four public hosts (no identifiers) while a non-local provider streams; documented in `SECURITY.md`.
- Private-LAN MCP servers are refused (loopback and public hosts only).
- Verified by `cargo nextest` suites in `crates/bistre-core` (`credentials`, `error_policy`, `sse`, `ssrf`, `registry`, `import_policy`, `approval`, `process_util`, `providers::tests::dispatch_fails_over_keys_then_heals_http_400_once_per_step`, `mcp`, `ota`, `tools`, `compaction`) and the `just guard` process-spawn / mmap gates.
