//! DTO mapping and 16 ms delta-coalescing helpers for the FFI layer (not scanned by FRB).

use bistre_protocol::{
    AgentRunRecord, AppHealthSnapshot, AppSettings, AssistantRecord, DraftRecord, EngineEvent,
    MoneyMicros, NodeRecord, PowerGuardStatus, ProviderProfile, SearchHit, SteeringMessage,
    StorageStats, StreamChunk, ThreadSummary, UpdateCheckResult,
};

use crate::api::{
    FfiAgentRunRecord, FfiAppSettings, FfiAssistantRecord, FfiDraftRecord, FfiEngineEvent,
    FfiHealthSnapshot, FfiNodeRecord, FfiPowerGuardStatus, FfiProviderProfile, FfiSearchHit,
    FfiSteeringMessage, FfiStorageStats, FfiThreadSummary, FfiUpdateCheckResult,
};
use crate::frb_generated::StreamSink;

pub(crate) fn flush_pending_delta(
    pending: &mut Option<(String, String, String)>,
    sink: &StreamSink<FfiEngineEvent>,
) -> bool {
    if let Some((thread_id, node_id, text_delta)) = pending.take() {
        return sink
            .add(FfiEngineEvent::delta(thread_id, node_id, text_delta))
            .is_ok();
    }
    true
}

pub(crate) fn buffer_delta_chunks(
    pending: &mut Option<(String, String, String)>,
    thread_id: &str,
    chunks: Vec<StreamChunk>,
    sink: &StreamSink<FfiEngineEvent>,
) -> bool {
    for StreamChunk {
        node_id,
        text_delta,
    } in chunks
    {
        match pending {
            Some((t, n, buf)) if t == thread_id && *n == node_id => buf.push_str(&text_delta),
            Some(_) => {
                if let Some((t, n, buf)) =
                    pending.replace((thread_id.to_owned(), node_id, text_delta))
                {
                    if sink.add(FfiEngineEvent::delta(t, n, buf)).is_err() {
                        return false;
                    }
                }
            }
            None => *pending = Some((thread_id.to_owned(), node_id, text_delta)),
        }
    }
    true
}

pub(crate) fn map_health(h: AppHealthSnapshot) -> FfiHealthSnapshot {
    FfiHealthSnapshot {
        core_version: h.core_version,
        schema_version: h.schema_version,
        wal_mode_active: h.wal_mode_active,
        thread_count: h.thread_count,
        node_count: h.node_count,
        active_runs: h.active_runs,
        status_key: h.status_key.as_key().to_owned(),
    }
}

pub(crate) fn map_assistant(a: AssistantRecord) -> FfiAssistantRecord {
    FfiAssistantRecord {
        id: a.id,
        name: a.name,
        role_subtitle: a.role_subtitle,
        system_prompt: a.system_prompt,
        default_mode: a.default_mode.as_str().to_owned(),
        badge_code: a.badge_code,
        icon_slug: a.icon_slug,
        default_provider_id: a.default_provider_id,
        default_model_id: a.default_model_id,
        temperature_milli: a.temperature_milli,
        max_output_tokens: a.max_output_tokens,
        top_p_milli: a.top_p_milli,
        is_builtin: a.is_builtin,
        created_at_ms: a.created_at_ms,
    }
}

pub(crate) fn map_provider(p: ProviderProfile) -> FfiProviderProfile {
    let is_local = bistre_core::net::is_loopback_url(&p.base_url);
    FfiProviderProfile {
        id: p.id,
        name: p.name,
        dialect: p.dialect.as_str().to_owned(),
        base_url: p.base_url,
        default_model: p.default_model,
        key_hint: p.key_hint,
        has_api_key: p.has_api_key,
        is_enabled: p.is_enabled,
        is_builtin: p.is_builtin,
        use_server_state_cache: p.use_server_state_cache,
        icon_slug: p.icon_slug,
        custom_icon_path: p.custom_icon_path,
        created_at_ms: p.created_at_ms,
        updated_at_ms: p.updated_at_ms,
        is_local,
    }
}

pub(crate) fn map_settings(s: AppSettings) -> FfiAppSettings {
    FfiAppSettings {
        theme: s.theme,
        layout_mode: s.layout_mode,
        locale: s.locale,
        trust_preset: s.trust_preset.as_str().to_owned(),
        wallet_daily_ceiling_micros: s.wallet_daily_ceiling_micros.map(MoneyMicros::as_micros),
        wallet_local_first: s.wallet_local_first,
        provider_stateless_default: s.provider_stateless_default,
        font_scale_bps: s.font_scale_bps,
        font_size_px: s.font_size_px,
        line_height_bps: s.line_height_bps,
        reading_width_px: s.reading_width_px,
        prose_font_family: s.prose_font_family,
        prose_font_path: s.prose_font_path,
        mono_font_family: s.mono_font_family,
        mono_font_path: s.mono_font_path,
        accent_preset: s.accent_preset,
        custom_accent_hex: s.custom_accent_hex,
        sidebar_open: s.sidebar_open,
        send_on_enter: s.send_on_enter,
        reduce_motion_override: s.reduce_motion_override,
        show_token_metrics: s.show_token_metrics,
        active_provider_id: s.active_provider_id,
        active_model_id: s.active_model_id,
        ota_feed_url: s.ota_feed_url,
        ota_channel: s.ota_channel,
        ota_auto_check: s.ota_auto_check,
        window_bounds_json: s.window_bounds_json,
        custom_shortcuts_json: s.custom_shortcuts_json,
        keep_awake_while_running: s.keep_awake_while_running,
        windows_keep_awake_on_battery: s.windows_keep_awake_on_battery,
        daemon_keep_alive_when_active: s.daemon_keep_alive_when_active,
        unattended_policy: s.unattended_policy.as_str().to_owned(),
        retry_watchdog_max_wait_secs: s.retry_watchdog_max_wait_secs,
        reasoning_effort: s.reasoning_effort,
        termux_bridge_enabled: s.termux_bridge_enabled,
        code_wrap_mode: s.code_wrap_mode,
        pricing_auto_refresh: s.pricing_auto_refresh,
        user_display_name: s.user_display_name,
    }
}

pub(crate) fn map_agent_run(r: AgentRunRecord) -> FfiAgentRunRecord {
    FfiAgentRunRecord {
        id: r.id,
        thread_id: r.thread_id,
        parent_run_id: r.parent_run_id,
        root_node_id: r.root_node_id,
        mode: r.mode.as_str().to_owned(),
        status: r.status.as_str().to_owned(),
        step_index: r.step_index,
        max_steps: r.max_steps,
        unattended_policy: r.unattended_policy.as_str().to_owned(),
        worktree_path: r.worktree_path,
        retry_after_ms: r.retry_after_ms,
        last_heartbeat_ms: r.last_heartbeat_ms,
        cost_micros: r.cost_micros.as_micros(),
        error_key: r.error_key,
        created_at_ms: r.created_at_ms,
        updated_at_ms: r.updated_at_ms,
    }
}

pub(crate) fn map_steering(m: SteeringMessage) -> FfiSteeringMessage {
    FfiSteeringMessage {
        id: m.id,
        thread_id: m.thread_id,
        run_id: m.run_id,
        content: m.content,
        status: m.status,
        created_at_ms: m.created_at_ms,
    }
}

pub(crate) fn map_power_status(p: PowerGuardStatus) -> FfiPowerGuardStatus {
    FfiPowerGuardStatus {
        platform: p.platform,
        keep_awake_active: p.keep_awake_active,
        battery_override_active: p.battery_override_active,
        daemon_connected: p.daemon_connected,
        on_ac_power: p.on_ac_power,
        sleep_prevented_reason: p.sleep_prevented_reason,
        android_fgs_active: p.android_fgs_active,
        android_battery_unrestricted: p.android_battery_unrestricted,
        active_run_count: p.active_run_count,
    }
}

pub(crate) fn map_thread(t: ThreadSummary) -> FfiThreadSummary {
    FfiThreadSummary {
        id: t.id,
        workspace_id: t.workspace_id,
        title: t.title,
        mode: t.mode.as_str().to_owned(),
        topic: t.topic,
        assistant_id: t.assistant_id,
        is_pinned: t.is_pinned,
        active_head_node_id: t.active_head_node_id,
        provider_id_override: t.provider_id_override,
        model_id_override: t.model_id_override,
        system_prompt_override: t.system_prompt_override,
        temperature_milli: t.temperature_milli,
        max_output_tokens: t.max_output_tokens,
        top_p_milli: t.top_p_milli,
        created_at_ms: t.created_at_ms,
        updated_at_ms: t.updated_at_ms,
    }
}

pub(crate) fn map_node(n: NodeRecord) -> FfiNodeRecord {
    FfiNodeRecord {
        id: n.id,
        thread_id: n.thread_id,
        parent_id: n.parent_id,
        role: n.role.as_str().to_owned(),
        content: n.content,
        provider_meta_json: n.provider_meta_json,
        created_at_ms: n.created_at_ms,
    }
}

pub(crate) fn map_storage_stats(s: StorageStats) -> FfiStorageStats {
    FfiStorageStats {
        data_dir: s.data_dir,
        db_size_bytes: s.db_size_bytes,
        core_version: s.core_version,
        schema_version: s.schema_version,
        wal_mode_active: s.wal_mode_active,
        thread_count: s.thread_count,
        node_count: s.node_count,
        active_runs: s.active_runs,
    }
}

pub(crate) fn map_update_check(u: UpdateCheckResult) -> FfiUpdateCheckResult {
    FfiUpdateCheckResult {
        current_version: u.current_version,
        latest_version: u.latest_version,
        update_available: u.update_available,
        track: u.track,
        ownership_mode: u.ownership_mode,
        signature_verified: u.signature_verified,
        active_runs_blocking: u.active_runs_blocking,
        release_notes: u.release_notes,
        download_url: u.download_url,
        sha256_hex: u.sha256_hex,
        download_size_bytes: u.download_size_bytes,
        checked_at_ms: u.checked_at_ms,
    }
}

pub(crate) fn map_draft(d: DraftRecord) -> FfiDraftRecord {
    FfiDraftRecord {
        thread_id: d.thread_id,
        text: d.text,
        updated_at_ms: d.updated_at_ms,
    }
}

pub(crate) fn map_hit(h: SearchHit) -> FfiSearchHit {
    FfiSearchHit {
        node_id: h.node_id,
        thread_id: h.thread_id,
        role: h.role.as_str().to_owned(),
        snippet: h.snippet,
        created_at_ms: h.created_at_ms,
    }
}

pub(crate) fn map_event(e: EngineEvent) -> FfiEngineEvent {
    match e {
        EngineEvent::RunStarted { thread_id, node_id } => {
            let mut evt = FfiEngineEvent::blank("run_started");
            evt.thread_id = Some(thread_id);
            evt.node_id = Some(node_id);
            evt
        }
        EngineEvent::DeltaBatch { thread_id, chunks } => {
            let first = chunks.into_iter().next();
            let (node_id, text_delta) = match first {
                Some(c) => (c.node_id, c.text_delta),
                None => (String::new(), String::new()),
            };
            FfiEngineEvent::delta(thread_id, node_id, text_delta)
        }
        EngineEvent::ThinkingDelta {
            thread_id,
            node_id,
            delta,
        } => {
            let mut evt = FfiEngineEvent::blank("thinking_delta");
            evt.thread_id = Some(thread_id);
            evt.node_id = Some(node_id);
            evt.text_delta = Some(delta);
            evt
        }
        EngineEvent::RunFinished {
            thread_id,
            node_id,
            cancelled,
        } => {
            let mut evt = FfiEngineEvent::blank("run_finished");
            evt.thread_id = Some(thread_id);
            evt.node_id = Some(node_id);
            evt.cancelled = Some(cancelled);
            evt
        }
        EngineEvent::RunStateChanged { run } => {
            let mut evt = FfiEngineEvent::blank("run_state_changed");
            evt.thread_id = Some(run.thread_id.clone());
            evt.payload_json = serde_json::to_string(&run).ok();
            evt
        }
        EngineEvent::RunStepUpdated { step } => {
            let mut evt = FfiEngineEvent::blank("run_step_updated");
            evt.payload_json = serde_json::to_string(&step).ok();
            evt
        }
        EngineEvent::SteeringQueueChanged {
            thread_id,
            pending_count,
        } => {
            let mut evt = FfiEngineEvent::blank("steering_queue_changed");
            evt.thread_id = Some(thread_id);
            evt.payload_json = Some(format!("{{\"pending_count\":{pending_count}}}"));
            evt
        }
        EngineEvent::PowerStatusChanged { status } => {
            let mut evt = FfiEngineEvent::blank("power_status_changed");
            evt.payload_json = serde_json::to_string(&status).ok();
            evt
        }
        EngineEvent::NodeCommitted { node } => {
            let mut evt = FfiEngineEvent::blank("node_committed");
            evt.thread_id = Some(node.thread_id.clone());
            evt.node_id = Some(node.id.clone());
            evt.node = Some(map_node(node));
            evt
        }
        EngineEvent::DraftSaved {
            thread_id,
            updated_at_ms,
        } => {
            let mut evt = FfiEngineEvent::blank("draft_saved");
            evt.thread_id = Some(thread_id);
            evt.updated_at_ms = Some(updated_at_ms);
            evt
        }
        EngineEvent::DiagnosticRaised { key, detail_code } => {
            FfiEngineEvent::diagnostic(key.as_key().to_owned(), detail_code)
        }
        EngineEvent::LocalePackVerified { pack_id, semver } => {
            let mut evt = FfiEngineEvent::blank("locale_pack_verified");
            evt.pack_id = Some(pack_id);
            evt.semver = Some(semver);
            evt
        }
    }
}

/// Maps a core error to the FFI error string: `diag.<key>` or `diag.<key>:<detail_code>`.
/// The Dart side reads the leading key; the detail stays available for logs and support.
pub(crate) fn ffi_err(err: bistre_protocol::BistreError) -> String {
    match err.detail_code {
        Some(detail) => format!("{}:{detail}", err.key.as_key()),
        None => err.key.as_key().to_owned(),
    }
}
