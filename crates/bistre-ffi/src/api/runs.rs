//! Agent run FFI entrypoints: durable runs, steering, power state, and the context breakdown.

use super::{
    current_engine, frb, map_agent_run, map_power_status, map_steering, DiagnosticKey,
    FfiAgentRunRecord, FfiPowerGuardStatus, FfiSteeringMessage, SystemPowerEvent,
};

/// Lists durable long-horizon agent runs stored in SQLite WAL.
#[frb]
pub async fn list_agent_runs(
    thread_id: Option<String>,
    only_active: bool,
    limit: u32,
) -> Result<Vec<FfiAgentRunRecord>, String> {
    let engine = current_engine()?;
    let runs = engine
        .list_agent_runs(thread_id, only_active, limit)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(runs.into_iter().map(map_agent_run).collect())
}

/// Queues a mid-stream user steering message for injection at the next step boundary without cancelling.
#[frb]
pub async fn enqueue_steering(
    thread_id: String,
    content: String,
) -> Result<FfiSteeringMessage, String> {
    let engine = current_engine()?;
    let msg = engine
        .enqueue_steering(thread_id, content)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_steering(msg))
}

/// Lists pending steering messages queued for `thread_id`.
#[frb]
pub async fn list_pending_steering(thread_id: String) -> Result<Vec<FfiSteeringMessage>, String> {
    let engine = current_engine()?;
    let items = engine
        .list_pending_steering(thread_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(items.into_iter().map(map_steering).collect())
}

/// Removes a queued steering message before injection.
#[frb]
pub async fn delete_steering(steering_id: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .delete_steering(steering_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Returns live OS sleep-guard, daemon connection, and Android FGS status.
#[frb]
pub async fn power_guard_status() -> Result<FfiPowerGuardStatus, String> {
    let engine = current_engine()?;
    let status = engine
        .power_guard_status()
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_power_status(status))
}

/// Delivers an OS suspend, resume, network, or timeout lifecycle event to the durable run reconciler.
#[frb]
pub async fn notify_power_event(event_kind: String, on_ac: Option<bool>) -> Result<u32, String> {
    let engine = current_engine()?;
    let parsed = match event_kind.as_str() {
        "will_suspend" => SystemPowerEvent::WillSuspend,
        "did_resume" => SystemPowerEvent::DidResume,
        "app_resumed" => SystemPowerEvent::AppResumed,
        "network_lost" => SystemPowerEvent::NetworkLost,
        "network_restored" => SystemPowerEvent::NetworkRestored,
        "os_timeout_imminent" => SystemPowerEvent::OsTimeoutImminent,
        "power_source_changed" => SystemPowerEvent::PowerSourceChanged {
            on_ac: on_ac.unwrap_or(true),
        },
        _ => return Err(DiagnosticKey::InvalidInput.as_key().to_owned()),
    };
    engine
        .notify_power_event(parsed)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Updates Android run-scoped `specialUse` FGS & battery exemption telemetry from Kotlin platform channel.
#[frb]
pub async fn set_android_power_state(
    fgs_active: bool,
    battery_unrestricted: bool,
) -> Result<FfiPowerGuardStatus, String> {
    let engine = current_engine()?;
    let status = engine
        .set_android_power_state(fgs_active, battery_unrestricted)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_power_status(status))
}

/// Reconciles an `indeterminate_halt` Tier-2 run after explicit user choice (`confirm_completed` or retry).
#[frb]
pub async fn resolve_indeterminate_run(
    run_id: String,
    confirm_completed: bool,
) -> Result<FfiAgentRunRecord, String> {
    let engine = current_engine()?;
    let run = engine
        .resolve_indeterminate_run(run_id, confirm_completed)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_agent_run(run))
}

/// The model's conversation limit in tokens as `provider_id` serves it (`None` when no
/// override or public list reports it).
#[frb]
pub async fn model_context_tokens(
    provider_id: String,
    model: String,
) -> Result<Option<u32>, String> {
    current_engine()?
        .model_context_tokens(provider_id, model)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// One row of the context breakdown; `kind` is a fixed id the app maps to its words.
#[derive(Debug, Clone)]
pub struct FfiContextCategory {
    pub kind: String,
    pub tokens: u64,
    pub count: Option<u32>,
    pub sent: bool,
}

/// One MCP tool's schema in the breakdown.
#[derive(Debug, Clone)]
pub struct FfiMcpToolUsage {
    pub name: String,
    pub tokens: u64,
    pub deferred: bool,
}

/// One MCP server and its tools in the breakdown.
#[derive(Debug, Clone)]
pub struct FfiMcpServerUsage {
    pub server_id: String,
    pub label: String,
    pub tools: Vec<FfiMcpToolUsage>,
}

/// What fills the next request, by category, with the window and the kept-free reserve.
#[derive(Debug, Clone)]
pub struct FfiContextBreakdown {
    pub categories: Vec<FfiContextCategory>,
    pub total_sent: u64,
    pub limit_tokens: Option<u64>,
    pub reserve_tokens: u64,
    pub mcp: Vec<FfiMcpServerUsage>,
    pub mcp_truncated: bool,
}

/// The breakdown for the branch ending at `leaf_node_id`, with `draft` as the message about to
/// be sent.
#[frb]
pub async fn context_breakdown(
    thread_id: String,
    leaf_node_id: String,
    draft: String,
) -> Result<FfiContextBreakdown, String> {
    let b = current_engine()?
        .context_breakdown(thread_id, leaf_node_id, draft)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(FfiContextBreakdown {
        total_sent: b.total_sent(),
        categories: b
            .categories
            .iter()
            .map(|c| FfiContextCategory {
                kind: c.kind.as_str().to_owned(),
                tokens: c.tokens,
                count: c.count,
                sent: c.sent,
            })
            .collect(),
        limit_tokens: b.limit_tokens,
        reserve_tokens: b.reserve_tokens,
        mcp: b
            .mcp
            .into_iter()
            .map(|srv| FfiMcpServerUsage {
                server_id: srv.server_id,
                label: srv.label,
                tools: srv
                    .tools
                    .into_iter()
                    .map(|t| FfiMcpToolUsage {
                        name: t.name,
                        tokens: t.tokens,
                        deferred: t.deferred,
                    })
                    .collect(),
            })
            .collect(),
        mcp_truncated: b.mcp_truncated,
    })
}
