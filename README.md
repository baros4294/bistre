<p align="center">
  <img src="assets/brand/bistre-icon.svg" width="96" height="96" alt="Bistre icon" />
</p>

<h1 align="center">Bistre</h1>

<p align="center">
  A fast, local-first, zero-telemetry AI client for Windows, Linux, and Android.<br/>
  One pure-Rust core paired with a lightweight Flutter UI.
</p>

<p align="center">
  <a href="https://github.com/baros4294/bistre/actions/workflows/ci.yml"><img src="https://github.com/baros4294/bistre/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-8B5014" alt="MIT License" /></a>
  <a href="SECURITY.md"><img src="https://img.shields.io/badge/telemetry-none-2B5E3F" alt="Zero Telemetry" /></a>
</p>

## Why Bistre

Bistre is built for people who want one calm, responsive AI workspace across desktop and mobile without cloud lock-in, analytics, or bloated browser shells.

- Local-first & zero telemetry: Conversations, search indexes, attachments, and settings live on your device in an ACID SQLite WAL database. Requests default to stateless mode (`store: false`) with zero tracking or analytics.
- Multi-provider by design: Connect OpenAI, Google Gemini, Anthropic, OpenRouter, or any Custom OpenAI-compatible server. Models, prices, and limits come from a catalog refreshed daily instead of a hardcoded list, and a provider's settings can be shared as a code without its API key.
- Pure-Rust engine (`crates/`): Streaming SSE framing, multi-key rotation and self-healing retries, exact integer spending limits (`MoneyMicros`), offline BPE tokenization, reversible context compaction, sandboxed workspace tools, MCP support, and Ed25519-signed updates all run in Rust. On desktop a background engine keeps replies and scheduled runs going after the window closes.
- Lightweight Flutter UI (`apps/bistre_app`): Built strictly on `package:flutter/widgets.dart` with zero Material/Cupertino kits or webviews. Supports warm light/dark and curated color presets, Bubbles and Document layouts, GFM tables, offline LaTeX math, Mermaid diagrams, inline SVG preview, 200% text scaling, and full RTL support (`en`, `vi`, `ar`).
- Projects & agents: Group chats into projects with their own folder, instructions, and hooks; run any number of chats at once, each with its own approvals; and schedule runs that skip, sandbox in a worktree, or wait for approval when nobody is watching. Opt-in computer use on desktop and phone use on Android ask before every action.
- Files & media: A file viewer, paste and drop of files and pictures, every file of a chat in one list, and replies with pictures and speech from image, speech, and video models.
- Writing & Coding workflows: Branching conversation trees, pinned replies, chat goals and side questions, cross-chat memory, `SKILL.md` skills installed from GitHub, workspace diff & 1-tap rewind, Story Bible & Lorebook V3 with chronological progressions, and a long-form manuscript canvas with scene planning, chapter summaries that flag contradictions, and in-place rewrite tools.

## Platforms

| Platform | Distribution | Highlights |
|---|---|---|
| Windows | Direct GitHub Release | Per-user installer (`-setup.exe`) & portable `.zip`, native Win11 DWM frame, system file dialogs, a shortcut that opens a new chat from any app. Builds are not code-signed, so SmartScreen may warn on first run; check the published SHA-256 sums and build attestations |
| Linux | Direct GitHub Release | `.AppImage`, `.deb`, `.rpm`, & portable `.tar.gz`, native Wayland/X11 desktop build, active-scoped daemon |
| Android | Direct GitHub APK (`arm64-v8a`) | Edge-to-edge layout, 16 KB page alignment, Keystore-backed vault, a foreground service that keeps live replies going, opt-in phone use |

## Install

Download the installer for your platform from [GitHub Releases](https://github.com/baros4294/bistre/releases). Installed builds check for signed updates in Settings > Updates & Storage. What changed in each version: [`changelog.md`](changelog.md).

## Architecture

```text
apps/bistre_app        Thin pure-Widgets Flutter UI (zero HTTP, SQL, or domain logic)
crates/bistre-ffi      flutter_rust_bridge v2 DTO bridge & 16 ms delta coalescing
crates/bistre-core     Providers, SSE, tokenizer, compaction, tools, MCP, Story Studio, Wallet Shield
crates/bistre-storage  Single-writer SQLite WAL actor, Expand-Contract migrations, FTS5 search
crates/bistre-crypto   Offline Ed25519 signature verification & OS secret vault traits
crates/bistre-protocol Shared domain types, MoneyMicros, and typed DiagnosticKey codes
crates/bistre-daemon   Active-scoped desktop daemon (IPC, housekeeping, OS sleep guard)
```

- Architecture & live implementation status: [`docs/specs/00-architecture.md`](docs/specs/00-architecture.md)
- Detailed specifications: [`docs/specs/`](docs/specs/) · Architecture Decision Records: [`docs/adr/`](docs/adr/)
- Design system & tokens: [`docs/design/design.md`](docs/design/design.md)

## Quick Start (Development)

### Prerequisites

- Rust 1.100.0 (pinned in `rust-toolchain.toml`) + `cargo-nextest` + `cargo-deny`
- Flutter 3.50.1 (pinned in `.github/workflows/ci.yml`)
- Android NDK 30.0.16248370 (for Android builds; pinned in `apps/bistre_app/android/app/build.gradle.kts`)
- just command runner (`cargo install just` or OS package manager)

### Run & Verify

```bash
# Run the desktop app in debug mode (uses isolated .bistre-dev/ storage)
cd apps/bistre_app && flutter run -d windows   # or -d linux

# Run all formatting, architecture guard, lint, i18n, Rust, and Flutter gates
just check-all

# Render UI gallery screenshots (desktop, phone, 200% text, RTL)
just ui-gallery

# Print or raise the app version (see CONTRIBUTING.md, Versions and Releases)
just version
just bump minor

# Check local build cache budgets; keep only the debug and Android caches
just disk
just prune
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full developer workflow, translation guide, and CI overview.

## Localization

Bistre ships with hot-loadable ICU message catalogs under [`l10n/catalog/`](l10n/catalog/) (`en`, `vi`, and RTL `ar`) with zero hardcoded UI strings. To add a language:

1. Copy [`l10n/catalog/en.bistre-l10n.json`](l10n/catalog/en.bistre-l10n.json) to `l10n/catalog/<bcp47>.bistre-l10n.json`.
2. Set `"locale"` and `"direction"` (`ltr` or `rtl`) and translate each `entries.<key>.message` following its `context`, `tone`, and `max_chars`.
3. Run `just i18n-gen` and `just i18n-check`.

## Security, Community & License

- Security: See [`SECURITY.md`](SECURITY.md) for vulnerability reporting and our cryptographic release verification model.
- Contributing: See [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`AGENTS.md`](AGENTS.md) for engineering invariants.
- Code of Conduct: Participation is governed by our [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
- License: Released under the [MIT License](LICENSE). Third-party attributions live in [`third-party-notices.md`](third-party-notices.md).
