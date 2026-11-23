# ADR-0012: Run-Scoped Android 15+ Foreground Services & Modern BLE Audio Routing

- **Status**: Accepted (Updated for Wave A Sleep Immunity & Direct GitHub Distribution)
- **Date**: 2026-11-22
- **Deciders**: Bistre Principal Architecture

## Context & Live-Verified Evidence
- Android 15+ (API 35+, verified `developer.android.com/develop/background-work/services/fgs/timeout`, Nov 2026) limits `dataSync` and `mediaProcessing` foreground services to a **cumulative 6 hours per 24-hour period**, calling `Service.onTimeout(int, int)` on exhaustion and raising an **ANR** if the service fails to call `stopSelf()` within seconds.
- Bistre distributes its Android APK directly via GitHub Releases (`arm64-v8a`, 16KB aligned, zero Play/F-Droid store flavors), allowing run-scoped `FOREGROUND_SERVICE_SPECIAL_USE` (`specialUse`) paired with `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` and `PARTIAL_WAKE_LOCK` + `WifiLock` for long-horizon user-initiated AI agent sessions without prematurely hitting the 6h `dataSync` cap.
- `AudioManager.startBluetoothSco()` is deprecated on Android 12+ (`API 31+`) and incompatible with Bluetooth LE Audio hearables; `AudioManager.setCommunicationDevice()` is the required modern API (`developer.android.com/develop/connectivity/bluetooth/ble-audio/audio-manager`).

## Decision
1. Start Android foreground service `BistreAgentService` (`FOREGROUND_SERVICE_SPECIAL_USE` for long-horizon agent runs; `FOREGROUND_SERVICE_MICROPHONE` for Fireside voice) **strictly while `active_runs > 0`**, acquiring a bounded `PARTIAL_WAKE_LOCK` + `WifiLock`, and stopping immediately when the active queue hits `0` (zero idle FGS drain).
2. Implement `Service.onTimeout(int, int)` and `AgentRecoveryWorker` (`WorkManager` expedited recovery) to checkpoint active run state to SQLite WAL (`sleep_paused`), notify the user cleanly, and call `stopSelf()` immediately before Android's ANR deadline.
3. Provide an explicit **optional Termux Bridge** (`TermuxBridge.kt` declaring `com.termux.permission.RUN_COMMAND` + `<queries>` + guided `allow-external-apps = true` setup) for Android users who opt into local shell automation alongside in-process Rust workspace tools.
4. Expose an opt-in Android Battery Optimization exemption button (`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) in Settings → Agent & Sleep without ever nagging or blocking normal chat usage.
5. For Wave 2/3 voice, route Bluetooth Classic/BLE Audio exclusively via `AudioManager.setCommunicationDevice()` + `OnCommunicationDeviceChangedListener` paired with Oboe low-latency duplex streams, hardware `AcousticEchoCanceler` (with WebRTC APM software AEC3 fallback), and Silero VAD barge-in gating.

## Rejected Alternatives
- **Always-on Android foreground service**: Drains battery and triggers OS ANR kills when idle.
- **Unconditionally relying on `dataSync` FGS**: Hits Android 15+'s hard 6h/24h timeout on multi-hour agent runs.
- **Legacy `startBluetoothSco()`**: Fails on Android 13–17 BLE Audio headsets.

## Consequences & Verification
- Protects mobile battery life, guarantees zero FGS timeout ANRs on Android 15/16/17, and enables durable Android agent runs with optional Termux shell execution.
- Verified in Android manifest hygiene checks (`compileSdk/targetSdk = 36`, `minSdk = 29`), `BistreAgentService.kt` / `AgentRecoveryWorker.kt` / `TermuxBridge.kt`, and `just guard`.
