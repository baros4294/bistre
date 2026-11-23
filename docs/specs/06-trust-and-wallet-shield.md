# Spec 06 — Dual Trust Shield & Wallet Shield

## 1. Risk Tiers 0–3
Every tool invocation and side-effecting action is classified statically + dynamically before execution:
- **Tier 0 (Read-Only Auto-Run)**: `read`, `grep`, `glob`, `diff`, local FTS5 search, read-only MCP tools. Executes automatically in all presets.
- **Tier 1 (Reversible Workspace Edits)**: Hash-anchored workspace file edits inside capability-scoped workspace `Dir`. Captures pre-image snapshot before write, enabling instant 1-tap rewind.
- **Tier 2 (External / Destructive / Paid Actions — Inline Wax Seal Approval)**: Shell commands, git mutations, external network/MCP writes, paid image/video generation. Requires explicit inline Wax Seal user confirmation showing exact target, command, and estimated cost.
- **Tier 3 (Hard Secret / Exfiltration Block)**: Attempts to read or transmit OS secret vault files, `.env` credentials, private keys, or symlink escapes outside workspace root are unconditionally blocked with `DiagnosticKey::ToolEditHashMismatch` / security audit log.

## 2. Mode Presets
- **Parchment (Strict)**: Tier 0 auto; Tiers 1–2 require Wax Seal confirmation; Tier 3 hard-blocked.
- **Guided Craft (Default)**: Tiers 0–1 auto (with 1-tap rewind); Tier 2 requires Wax Seal confirmation; Tier 3 hard-blocked.
- **Unchained / Sandbox**: Tiers 0–2 auto inside isolated worktree/container boundary ONLY; Tier 3 and Wallet Shield hard ceilings remain active.

## 3. Wallet Shield (Unconditionally Overrides Self-Healing)
- All costs, reserves, and spend limits use exact `MoneyMicros(i64)` (`1 USD = 1_000_000`) persisted in `wallet_ledger` alongside real input/output token counts.
- **Unlimited or Custom Daily Spending Limit**: `AppSettings.wallet_daily_ceiling_micros` is `Option<MoneyMicros>`. Setting `None` enables **Unlimited spending** (zero artificial ceiling for heavy users or local/flat-rate plans); setting any positive `MoneyMicros` enforces a hard UTC-day spend check (`sum_wallet_spend_since_micros`) before every metered cloud request, blocking execution with `DiagnosticKey::WalletCeilingExceeded` once reached (loopback local providers such as Ollama/vLLM always cost `$0.00` and bypass cloud caps). "Loopback" is decided only by `bistre_core::net::is_loopback_url`, which parses the URL and accepts `http(s)` hosts `localhost` or a loopback IP; prefix tricks such as `http://localhost.evil.com` stay metered (shared with MCP).
- **Spend reservations (fail closed)**: before every paid request the run reserves an input-cost estimate in `wallet_ledger` (`status = reserved`) inside one writer transaction that also checks the ceiling against settled + reserved spend (`StorageHandle::reserve_wallet_spend`), so concurrent runs and sub-agents serialize and cannot overshoot together. `bistre_core::wallet::SpendReservation` is the only way to reserve; it settles to the exact cost on commit and releases on drop (failure, cancel before output, retry). Engine start releases orphaned reservations. A settings or ledger read failure denies the request with `diag.wallet.check_unavailable`. Tests: `crates/bistre-core/src/wallet.rs`.
- **Paid Media Gate & Retry Ceiling**: Paid media jobs require explicit Wax Seal confirmation above configurable threshold and cap automatic retries to `0` on indeterminate transport drops (`INDETERMINATE_HALT`).
- **$0 Local Priority**: Automatically ranks local Ollama/llama.cpp/ComfyUI models ahead of metered cloud models when slot-compatible.

## 4. Untrusted Imports & OS Hand-Off
- **`import_policy::with_imported_permissions`** runs on every imported character card (`.png`, `.json`, `.charx`): local filesystem, shell, web, and MCP grants in `extensions` are removed, MCP `command`/`args` are dropped, Windows UNC paths (`\\server\share`, `//server/share`, `\\?\UNC\…`) are cleared from every field, and media paths must be relative `media/<name>`.
- **OS open**: `process_util::is_blocked_open_path` / `validate_web_link` (25 blocked executable/script/shortcut extensions, UNC refusal, `http(s)` links only); the desktop `openFolder` bridge (`apps/bistre_app/lib/platform/desktop_host.dart` + `apps/bistre_app/windows/runner/flutter_window.cpp`) opens only existing local directories with the `explore` verb.
- **Pricing for the spending limit** comes only from the live registry (Spec 03); an unpriced reply counts as `$0` toward the limit (lower bound) and is marked `cost_known: false`; the chat shows a quiet info button with a breakdown popup instead of a price (Spec 08 §3).
