# ADR-0003: Unified `EngineClient` Trait, Resident Desktop Daemon & mTLS Remote Bridge

- **Status**: Accepted
- **Date**: 2026-11-21
- **Deciders**: Bistre Principal Architecture

## Context & Live-Verified Evidence
- Keeping a hidden Flutter/Impeller window alive on desktop consumes 80–200 MB GPU/Dart RAM.
- On Linux KDE Plasma 6 Wayland, `libayatana-appindicator` and legacy tray wrappers frequently fail to register with `StatusNotifierWatcher` or break Wayland window focus.
- Over LAN and Tailscale WireGuard networks, raw UDP QUIC encounters corporate UDP filtering and WireGuard-over-UDP MTU fragmentation.

## Decision
1. Define a single async `EngineClient` trait in `crates/bistre-core` behind one FRB v2 API in `crates/bistre-ffi`, with three interchangeable backends: `InProcessEngine` (Android embedded and standalone desktop), `LocalIpcEngine` (Desktop UDS / Windows Named Pipe), and `RemoteBridgeEngine` (LAN/Tailscale).
2. On desktop, run a dedicated resident `bistre-daemon` binary (~15–30 MB RSS) owning single-instance kernel locks (`flock` / Win32 mutex), SQLite WAL writer, active LLM/agent/MCP runs, Wayland clipboard serving, and system tray (`ksni 0.3.7` pure-Rust D-Bus on Linux, Win32 `Shell_NotifyIconW` on Windows). Closing the window exits the Flutter UI process completely (0 MB GUI idle RAM).
3. Use TLS 1.3 mTLS WebSocket over TCP with QR-exchanged certificate fingerprint pinning, monotonic `u64` cursor replay, and single-writer lease fencing for Remote Bridge.

## Rejected Alternatives
- **Hide Flutter window to tray**: Violates ≤30 MB idle RAM budget and ties background agent survivability to GPU/compositor stability.
- **QUIC-only Remote Bridge**: Fragile under enterprise firewalls and Tailscale WireGuard encapsulation.

## Consequences & Verification
- Flutter UI stays 100% topology-agnostic across Android, Desktop Daemon, and Remote Bridge.
- Verified via `bistre-daemon --health-check` (RSS ≤30 MB) and single-instance lock contention tests.
