//! `agent_delegate`: up to [`MAX_HELPERS`] read-only helper agents that look into the workspace
//! in parallel and report back a capped summary (Spec 04).
//!
//! A helper is a short in-memory conversation on the run's own provider and model. It sees only
//! the read tools the run itself may use (`read`, `grep`, `glob`, `fs_list`), never writes,
//! never asks for approval, and never starts another helper. Every request is reserved in the
//! Wallet Shield like the run's own, and the run's Stop ends every helper.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, GenerationParams, MoneyMicros, NodeRecord, NodeRole,
    ProviderProfile, ToolRiskTier,
};
use bistre_storage::StorageHandle;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::agent_tools::ActiveToolCatalog;
use crate::engine_runs::StreamServices;
use crate::replay_policy::StoredToolResult;
use crate::subagents::cap_subagent_summary;
use crate::tools::ToolExecutionOutput;

/// Most helpers one call starts.
pub const MAX_HELPERS: usize = 3;
/// Most model requests one helper sends.
const MAX_HELPER_STEPS: u32 = 8;
/// The only tools a helper may call.
const HELPER_TOOLS: [&str; 4] = ["fs_list", "glob", "grep", "read"];
const MAX_TASK_CHARS: usize = 4_000;

const HELPER_PROMPT: &str = "You are a read-only helper working for another agent. Investigate \
the task below in the workspace using only the tools you have. You cannot change files. When \
you are done, reply with a short, factual summary of what you found, naming the files and \
lines that matter. Do not ask questions; nobody will answer them.";

/// What a helper borrows from the run that started it.
pub(crate) struct HelperContext<'a> {
    pub(crate) provider: &'a ProviderProfile,
    pub(crate) keys: &'a crate::credentials::KeyRing,
    pub(crate) model: &'a str,
    pub(crate) cancel_flag: &'a Arc<AtomicBool>,
}

/// The `agent_delegate` schema, offered only when the user turned the tool on.
pub fn schema() -> Value {
    json!({
        "name": "agent_delegate",
        "description": format!(
            "Start up to {MAX_HELPERS} read-only helper agents in parallel. Each looks into the workspace for one task and returns a short summary. Use it to research several places at once."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "tasks": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "One self-contained instruction per helper."
                }
            },
            "required": ["tasks"]
        }
    })
}

/// Parses `tasks`: one to [`MAX_HELPERS`] non-empty strings.
pub(crate) fn parse_tasks(args: &Value) -> BistreResult<Vec<String>> {
    let tasks: Vec<String> = args
        .get("tasks")
        .and_then(Value::as_array)
        .ok_or_else(|| BistreError::with_detail(DiagnosticKey::InvalidInput, "tasks_missing"))?
        .iter()
        .filter_map(Value::as_str)
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .map(|t| t.chars().take(MAX_TASK_CHARS).collect())
        .collect();
    if tasks.is_empty() || tasks.len() > MAX_HELPERS {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "tasks_count",
        ));
    }
    Ok(tasks)
}

/// Runs every helper at once and joins their summaries in task order.
pub(crate) async fn run_helpers(
    storage: &Arc<StorageHandle>,
    services: &StreamServices,
    catalog: &ActiveToolCatalog,
    ctx: &HelperContext<'_>,
    thread_id: &str,
    run_id: &str,
    args: &Value,
) -> BistreResult<ToolExecutionOutput> {
    let started = Instant::now();
    let tasks = parse_tasks(args)?;
    let tools = ActiveToolCatalog {
        canonical_schemas: catalog
            .canonical_schemas
            .iter()
            .filter(|s| {
                s.get("name")
                    .and_then(Value::as_str)
                    .is_some_and(|n| HELPER_TOOLS.contains(&n))
            })
            .cloned()
            .collect(),
        workspace_roots: catalog.workspace_roots.clone(),
        workspace_root: catalog.workspace_root.clone(),
        ..ActiveToolCatalog::default()
    };
    let runs = tasks.iter().enumerate().map(|(index, task)| {
        let tools = &tools;
        async move {
            let helper = Helper {
                storage,
                services,
                ctx,
                tools,
                thread_id,
                run_id,
                index: index + 1,
            };
            helper.run(task).await
        }
    });
    let results = join_in_order(runs).await;
    let mut text = String::new();
    let mut any_ok = false;
    for (index, (task, result)) in tasks.iter().zip(results).enumerate() {
        let title: String = task.chars().take(80).collect();
        let body = match result {
            Ok(summary) => {
                any_ok = true;
                cap_subagent_summary(&summary)
            }
            Err(err) => format!("Helper failed: {err}"),
        };
        let number = (index + 1).to_string();
        text.extend(["## Helper ", &number, ": ", &title, "\n", &body, "\n\n"]);
    }
    if ctx.cancel_flag.load(Ordering::SeqCst) {
        text.push_str("Stopped before every helper finished.\n");
    }
    Ok(ToolExecutionOutput {
        tool_name: "agent_delegate".to_owned(),
        risk_tier: ToolRiskTier::Tier0ReadOnly,
        ok: any_ok,
        summary: format!("{} helpers reported", tasks.len()),
        output_text: text.trim_end().to_owned(),
        diff_text: None,
        checkpoint_id: None,
        duration_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(i64::MAX),
        media_attachments: Vec::new(),
    })
}

/// Runs every future concurrently and returns their outputs in input order.
async fn join_in_order<F: Future>(futures: impl Iterator<Item = F>) -> Vec<F::Output> {
    let mut set: Vec<std::pin::Pin<Box<F>>> = futures.map(Box::pin).collect();
    let mut done: Vec<Option<F::Output>> = (0..set.len()).map(|_| None).collect();
    std::future::poll_fn(|cx| {
        let mut pending = false;
        for (slot, fut) in done.iter_mut().zip(set.iter_mut()) {
            if slot.is_none() {
                match fut.as_mut().poll(cx) {
                    std::task::Poll::Ready(out) => *slot = Some(out),
                    std::task::Poll::Pending => pending = true,
                }
            }
        }
        if pending {
            std::task::Poll::Pending
        } else {
            std::task::Poll::Ready(())
        }
    })
    .await;
    done.into_iter().flatten().collect()
}

fn cancelled() -> BistreError {
    BistreError::with_detail(DiagnosticKey::ProviderStreamInterrupted, "cancelled")
}

struct Helper<'a> {
    storage: &'a Arc<StorageHandle>,
    services: &'a StreamServices,
    ctx: &'a HelperContext<'a>,
    tools: &'a ActiveToolCatalog,
    thread_id: &'a str,
    run_id: &'a str,
    index: usize,
}

impl Helper<'_> {
    fn node(&self, role: NodeRole, content: String, meta: Option<Value>) -> NodeRecord {
        NodeRecord {
            id: Uuid::now_v7().to_string(),
            thread_id: self.thread_id.to_owned(),
            parent_id: None,
            role,
            content,
            provider_meta_json: meta.map(|m| m.to_string()),
            created_at_ms: crate::engine_runs::utc_now_unix_ms(),
        }
    }

    /// Books one helper request's real cost in place of its reservation.
    fn settle(
        &self,
        reservation: crate::wallet::SpendReservation,
        adv: &crate::provider_prefs::ProviderAdvancedPrefs,
        res: &crate::wire_stream::StreamOutcome,
        estimated_input: u64,
        step: u32,
    ) -> BistreResult<()> {
        let (provider, model) = (self.ctx.provider, self.ctx.model);
        let counted = std::iter::once(res.full_text.as_str())
            .chain(res.tool_calls.iter().map(|c| c.arguments_json.as_str()))
            .map(|t| crate::compaction::estimate_tokens_for_model(t, Some(model)))
            .fold(0_u64, u64::saturating_add);
        let (usage, _) = crate::wallet::billable_usage(&res.usage, estimated_input, counted);
        let rates = adv.resolve_rates(
            model,
            self.services
                .pricing
                .snapshot()
                .lookup(&crate::registry::CatalogScope::of(provider), model),
        );
        // An unpriced model books as zero; reservation already blocked it while a cap is set.
        let cost = crate::providers::estimate_cost_micros(provider, rates, &usage)
            .unwrap_or(MoneyMicros::ZERO);
        let status = if res.cancelled {
            "cancelled"
        } else {
            "settled"
        };
        reservation.settle_for_request(
            Some(format!("{}:helper{}:{step}", self.run_id, self.index)),
            cost,
            usage.input_tokens,
            usage.output_tokens,
            status.to_owned(),
        )
    }

    async fn run(&self, task: &str) -> BistreResult<String> {
        let (provider, model) = (self.ctx.provider, self.ctx.model);
        let adv = crate::provider_prefs::load_provider_advanced(self.storage, &provider.id);
        let is_local = crate::net::is_loopback_url(&provider.base_url);
        let tools_wire = self.tools.wire_tools_for_dialect(provider.dialect);
        let tools_canonical = self.tools.canonical_json();
        let mut history = vec![self.node(NodeRole::User, task.to_owned(), None)];
        for step in 0..MAX_HELPER_STEPS {
            if self.ctx.cancel_flag.load(Ordering::SeqCst) {
                return Err(cancelled());
            }
            let last = step + 1 == MAX_HELPER_STEPS;
            let (reservation, estimated_input) = if is_local {
                (None, 0)
            } else {
                let (r, est) = crate::engine_runs::reserve_paid_request(
                    self.storage,
                    self.services,
                    self.thread_id,
                    provider,
                    &adv,
                    model,
                    HELPER_PROMPT,
                    &history,
                    bistre_protocol::SpendPurpose::Helper,
                )
                .await?;
                (Some(r), est)
            };
            let replay_ctx = crate::replay_policy::ReplayContext::new(
                provider.dialect,
                &provider.id,
                model,
                HELPER_PROMPT,
                &tools_canonical,
                Some(self.thread_id),
            );
            let options = crate::providers::StreamRequestOptions {
                replay_ctx: Some(&replay_ctx),
                // The last step has no tools, so the helper has to answer in words.
                tools_wire: (!last && !tools_wire.is_empty()).then_some(tools_wire.as_slice()),
                previous_server_id: None,
                chain_first_new_index: 0,
                store: false,
                anthropic_cache_1h: false,
                anthropic_server_compaction: false,
                endpoint_path: adv.endpoint_path.as_deref(),
                auth_mode: adv.auth_mode,
                disable_legacy_fallback: !adv.use_legacy_fallback,
                reply_prefill: None,
                anthropic_beta_headers: Vec::new(),
                extra_headers: Vec::new(),
                extra_body_fields: None,
                media_out: crate::registry::ModalitySet::default(),
                reads: None,
                voice: None,
                media_pick: crate::media_wire::MediaPick::default(),
                provider_tools: false,
                paid_tools: crate::paid_tools::PaidTools::default(),
                raw_request_id: None,
            };
            let res = crate::providers::stream_completion_with_options(
                &self.services.http,
                provider,
                self.ctx.keys,
                model,
                HELPER_PROMPT,
                &history,
                GenerationParams::default(),
                Some(&self.services.data_dir),
                &options,
                self.ctx.cancel_flag,
                |_| {},
                |_| {},
            )
            .await?;
            if let Some(r) = reservation {
                self.settle(r, &adv, &res, estimated_input, step)?;
            }
            if res.cancelled {
                return Err(cancelled());
            }
            if res.tool_calls.is_empty() {
                return Ok(res.full_text);
            }
            let calls = res.tool_calls.clone();
            history.push(self.node(
                NodeRole::Assistant,
                res.full_text,
                Some(json!({ "tool_calls": calls })),
            ));
            for call in calls {
                let output = self.call_tool(&call.name, &call.arguments_json).await;
                let (text, is_error) = match output {
                    Ok(out) => (out.output_text, !out.ok),
                    Err(err) => (format!("Error: {}", err.key.as_key()), true),
                };
                let result = StoredToolResult {
                    call_id: call.call_id.clone(),
                    name: call.name.clone(),
                    is_error,
                    media_attachments: Vec::new(),
                };
                history.push(self.node(
                    NodeRole::Tool,
                    text,
                    Some(json!({ "tool_result": result })),
                ));
            }
        }
        Err(BistreError::with_detail(
            DiagnosticKey::RunStepLimitReached,
            "helper",
        ))
    }

    async fn call_tool(&self, name: &str, raw_args: &str) -> BistreResult<ToolExecutionOutput> {
        if !self
            .tools
            .canonical_schemas
            .iter()
            .any(|s| s.get("name").and_then(Value::as_str) == Some(name))
        {
            return Err(BistreError::with_detail(
                DiagnosticKey::ToolTierBlocked,
                "helper_tool_not_allowed",
            ));
        }
        let args: Value = if raw_args.trim().is_empty() {
            json!({})
        } else {
            serde_json::from_str(raw_args)
                .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "args_json"))?
        };
        if crate::tools::classify_tool_risk(name, &args) != ToolRiskTier::Tier0ReadOnly {
            return Err(BistreError::with_detail(
                DiagnosticKey::ToolTierBlocked,
                "helper_tool_not_allowed",
            ));
        }
        let storage = Arc::clone(self.storage);
        let ledger = Arc::clone(&self.services.read_ledger);
        let roots = self.tools.workspace_roots.clone();
        // Helpers keep their own read record, so they never vouch for the run's writes.
        let scope = format!("{}:helper{}", self.thread_id, self.index);
        let name = name.to_owned();
        crate::off_worker::blocking(move || {
            crate::agent_context::run_workspace_file_tool(
                &storage, &ledger, &roots, &scope, None, &name, &args,
            )
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tasks_are_bounded() {
        assert!(parse_tasks(&json!({ "tasks": [] })).is_err());
        assert!(parse_tasks(&json!({ "tasks": ["a", "b", "c", "d"] })).is_err());
        assert!(parse_tasks(&json!({ "tasks": ["  "] })).is_err());
        assert_eq!(
            parse_tasks(&json!({ "tasks": [" find the parser ", "list docs"] })).ok(),
            Some(vec!["find the parser".to_owned(), "list docs".to_owned()])
        );
    }
}
