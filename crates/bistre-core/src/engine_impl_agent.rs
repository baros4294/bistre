//! The engine calls for agent runs, tools, MCP, memory, skills, schedules, and Story
//! Studio (split out of `engine_impl.rs`; `EngineClient` delegates to them).

use super::{
    AgentRunRecord, BistreError, BistreResult, BoxFuture, CharacterCardRecord, CronJobRecord,
    CursorEventRecord, DiagnosticKey, EngineEvent, InProcessEngine, MemoryEntryRecord, NodeRecord,
    Path, PowerGuardStatus, ProviderProfile, RegexRuleRecord, RunStepRecord, SteeringMessage,
    StoryChapterRecord, StoryEntryRecord, StoryProgressionRecord, StorySceneRecord,
    StorySnapshotRecord, StoryThreadStateRecord, SystemPowerEvent, ThreadSummary, ToolRiskTier,
    UserPersonaRecord, WorkspaceCheckpointRecord, agent, broadcast, compaction, cron, hooks, mcp,
    skills, story, tools,
};
use crate::engine_runs::{utc_day_start_unix_ms, utc_now_unix_ms};
use crate::events::{emit, emit_logged};
use crate::off_worker::{in_place, off_worker};
use bistre_protocol::lock_or_recover;

use crate::engine_impl::parse_tool_args;

impl InProcessEngine {
    pub fn list_agent_runs(
        &self,
        thread_id: Option<String>,
        only_active: bool,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<AgentRunRecord>>> {
        Box::pin(async move {
            self.storage
                .list_agent_runs(thread_id.as_deref(), only_active, limit)
        })
    }

    pub fn list_run_steps(
        &self,
        run_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<RunStepRecord>>> {
        Box::pin(async move { self.storage.list_run_steps(&run_id) })
    }

    pub fn enqueue_steering(
        &self,
        thread_id: String,
        content: String,
    ) -> BoxFuture<'_, BistreResult<SteeringMessage>> {
        Box::pin(async move {
            let active_run_id = self
                .storage
                .list_agent_runs(Some(&thread_id), true, 1)?
                .into_iter()
                .next()
                .map(|r| r.id);
            let msg = self.storage.enqueue_steering_message(
                thread_id.clone(),
                active_run_id,
                &content,
                "[]".to_owned(),
            )?;
            let pending_count =
                u32::try_from(self.storage.list_pending_steering(&thread_id)?.len())
                    .unwrap_or(u32::MAX);
            let ev = EngineEvent::SteeringQueueChanged {
                thread_id: thread_id.clone(),
                pending_count,
            };
            emit_logged(&self.storage, &self.events_tx, Some(thread_id), ev);
            Ok(msg)
        })
    }

    pub fn list_pending_steering(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<SteeringMessage>>> {
        Box::pin(async move { self.storage.list_pending_steering(&thread_id) })
    }

    pub fn delete_steering(&self, steering_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.delete_steering_message(steering_id) })
    }

    pub fn power_guard_status(&self) -> BoxFuture<'_, BistreResult<PowerGuardStatus>> {
        Box::pin(async move { Ok(self.power.status()) })
    }

    pub fn notify_power_event(&self, event: SystemPowerEvent) -> BoxFuture<'_, BistreResult<u32>> {
        Box::pin(async move {
            self.power.notify_system_event(event);
            let settings = self.storage.load_settings()?;
            let spent = self
                .storage
                .sum_wallet_spend_since_micros(utc_day_start_unix_ms())?;
            let actions =
                agent::handle_power_event(&self.storage, &settings, &self.events_tx, event, spent)?;
            emit(
                &self.events_tx,
                EngineEvent::PowerStatusChanged {
                    status: self.power.status(),
                },
            );
            Ok(u32::try_from(actions.len()).unwrap_or(u32::MAX))
        })
    }

    pub fn set_android_power_state(
        &self,
        fgs_active: bool,
        battery_unrestricted: bool,
    ) -> BoxFuture<'_, BistreResult<PowerGuardStatus>> {
        Box::pin(async move {
            self.power
                .set_android_power_state(fgs_active, battery_unrestricted);
            let status = self.power.status();
            emit(
                &self.events_tx,
                EngineEvent::PowerStatusChanged {
                    status: status.clone(),
                },
            );
            Ok(status)
        })
    }

    pub fn resolve_indeterminate_run(
        &self,
        run_id: String,
        confirm_completed: bool,
    ) -> BoxFuture<'_, BistreResult<AgentRunRecord>> {
        Box::pin(async move {
            agent::resolve_indeterminate_run(
                &self.storage,
                &self.events_tx,
                run_id,
                confirm_completed,
            )
        })
    }

    pub fn replay_events_after(
        &self,
        after_cursor: u64,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<CursorEventRecord>>> {
        Box::pin(async move { self.storage.read_engine_events_after(after_cursor, limit) })
    }

    pub fn latest_event_cursor(&self) -> BoxFuture<'_, BistreResult<u64>> {
        Box::pin(async move { self.storage.latest_event_cursor() })
    }

    pub fn context_breakdown(
        &self,
        thread_id: String,
        leaf_node_id: String,
        draft: String,
    ) -> BoxFuture<'_, BistreResult<crate::ContextBreakdown>> {
        let dir = self.data_dir.clone();
        let prices = self.pricing.snapshot();
        Box::pin(off_worker(&self.storage, move |s| {
            let limit_for = |model: &str| {
                prices
                    .lookup(&crate::registry::CatalogScope::ANY, model)
                    .and_then(|r| r.context_tokens)
                    .map(u64::from)
            };
            crate::context_breakdown::branch_context_breakdown(
                s,
                Some(&dir),
                &thread_id,
                &leaf_node_id,
                &draft,
                &limit_for,
            )
        }))
    }

    /// The conversation limit of `model` as `provider_id` serves it.
    pub fn model_context_tokens(
        &self,
        provider_id: String,
        model: String,
    ) -> BoxFuture<'_, BistreResult<Option<u32>>> {
        Box::pin(async move {
            let scope = self.catalog_scope(&provider_id)?;
            let base = self.pricing.snapshot().lookup(&scope, &model);
            Ok(
                crate::provider_prefs::load_provider_advanced(&self.storage, &provider_id)
                    .context_tokens(&model, base),
            )
        })
    }

    pub fn refresh_prices(&self) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            self.pricing.force_refresh(&self.web);
            Ok(())
        })
    }

    pub fn approve_tool_call(
        &self,
        thread_id: String,
        tool_name: String,
        arguments_json: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            let settings = self.storage.load_settings()?;
            if settings.trust_preset == bistre_protocol::TrustPreset::Off {
                return Err(BistreError::with_detail(
                    DiagnosticKey::ToolTierBlocked,
                    "tools_disabled",
                ));
            }
            let args = parse_tool_args(&arguments_json)?;
            if tools::classify_tool_risk(&tool_name, &args) == ToolRiskTier::Tier3Blocked {
                return Err(BistreError::with_detail(
                    DiagnosticKey::ToolTierBlocked,
                    "tier3_blocked",
                ));
            }
            self.broker.approve(&thread_id, &tool_name, &args)
        })
    }

    pub fn allow_unpriced_once(&self, thread_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            lock_or_recover(&self.unpriced_allowed, "unpriced_allowed").insert(thread_id);
            Ok(())
        })
    }

    pub fn save_provider_overrides(
        &self,
        provider_id: String,
        headers_json: String,
        body_json: String,
    ) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            self.save_provider_overrides_inner(&provider_id, &headers_json, &body_json)
        })
    }
    pub fn allow_unpriced_media_once(&self) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            lock_or_recover(&self.unpriced_allowed, "unpriced_allowed")
                .insert(crate::engine_extras::MEDIA_ALLOWANCE.to_owned());
            Ok(())
        })
    }

    pub fn pending_tool_approvals(&self) -> BoxFuture<'_, BistreResult<Vec<EngineEvent>>> {
        Box::pin(async move {
            Ok(crate::agent_approvals::pending_approval_requests(
                &self.pending_approvals,
            ))
        })
    }

    pub fn respond_tool_approval(
        &self,
        thread_id: String,
        run_id: String,
        call_id: String,
        decision: bistre_protocol::ToolApprovalDecision,
    ) -> BoxFuture<'_, BistreResult<bool>> {
        Box::pin(async move {
            Ok(crate::agent_tools::deliver_tool_approval(
                &self.pending_approvals,
                &crate::agent_tools::ApprovalKey {
                    thread_id,
                    run_id,
                    call_id,
                },
                decision,
            ))
        })
    }

    pub fn respond_host_action(
        &self,
        request_id: String,
        ok: bool,
        output_text: String,
        image_base64: Option<String>,
    ) -> BoxFuture<'_, BistreResult<bool>> {
        Box::pin(async move {
            Ok(self.host_actions.deliver(
                &request_id,
                crate::computer_use::HostActionResponse {
                    ok,
                    output_text,
                    image_base64,
                },
            ))
        })
    }

    pub fn execute_workspace_tool(
        &self,
        workspace_root: String,
        thread_id: String,
        tool_name: String,
        arguments_json: String,
        permit_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<tools::ToolExecutionOutput>> {
        Box::pin(async move {
            let args = parse_tool_args(&arguments_json)?;
            crate::agent_tools::execute_workspace_tool_direct(
                &self.storage,
                &self.web,
                &self.read_ledger,
                &self.broker,
                &workspace_root,
                &thread_id,
                &tool_name,
                &args,
                permit_id,
            )
            .await
        })
    }

    pub fn rewind_checkpoint(
        &self,
        workspace_root: String,
        checkpoint_id: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            let rel_path = tools::tool_rewind_checkpoint(
                &self.storage,
                Path::new(&workspace_root),
                &checkpoint_id,
            )?;
            self.read_ledger.invalidate_path(&rel_path);
            Ok(rel_path)
        })
    }

    pub fn list_checkpoints(
        &self,
        thread_id: String,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<WorkspaceCheckpointRecord>>> {
        Box::pin(async move {
            let mut cps = self.storage.list_workspace_checkpoints(&thread_id)?;
            let max = usize::try_from(limit).unwrap_or(50);
            if cps.len() > max {
                cps.truncate(max);
            }
            Ok(cps)
        })
    }

    pub fn compact_thread(
        &self,
        thread_id: String,
        keep_recent_turns: u32,
        custom_summary: Option<String>,
        instructions: Option<String>,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>> {
        Box::pin(async move {
            self.compact_thread_inner(&thread_id, keep_recent_turns, custom_summary, instructions)
                .await
        })
    }

    pub fn rewrite_compaction_summary(
        &self,
        thread_id: String,
        node_id: String,
        content: String,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>> {
        Box::pin(
            async move { self.rewrite_compaction_summary_inner(&thread_id, &node_id, &content) },
        )
    }

    pub fn undo_compaction(
        &self,
        thread_id: String,
        compaction_node_id: String,
    ) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            compaction::undo_compaction(&self.storage, &thread_id, &compaction_node_id)
        })
    }

    pub fn set_context_start_pin(
        &self,
        thread_id: String,
        node_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Option<String>>> {
        Box::pin(async move {
            let key = format!("thread_context_start:{thread_id}");
            if let Some(id) = node_id
                .map(|s| s.trim().to_owned())
                .filter(|s| !s.is_empty())
            {
                self.storage.set_kv_meta(key, id.clone())?;
                Ok(Some(id))
            } else {
                self.storage.delete_kv_meta(key)?;
                Ok(None)
            }
        })
    }

    pub fn get_context_start_pin(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Option<String>>> {
        Box::pin(async move {
            let key = format!("thread_context_start:{thread_id}");
            self.storage.get_kv_meta(&key)
        })
    }

    pub fn discover_mcp_server(
        &self,
        server: mcp::McpServerConfig,
    ) -> BoxFuture<'_, BistreResult<mcp::McpDiscoveryReport>> {
        Box::pin(async move {
            let bearer = self.load_mcp_bearer(&server.id);
            let report =
                mcp::discover_mcp_server(&self.mcp_http, &server, bearer.as_deref()).await?;
            crate::mcp_refresh::store_tools(
                &self.storage,
                &server.id,
                &report.tools,
                utc_now_unix_ms(),
                &crate::mcp_refresh::auth_context(bearer.as_deref()),
            );
            Ok(report)
        })
    }

    /// Saves `token` as the server's Bearer token in the vault; a blank token removes it. It is
    /// sent only over HTTPS or to a loopback host (`mcp::mcp_headers`).
    pub fn set_mcp_token(
        &self,
        server_id: String,
        token: String,
    ) -> BoxFuture<'_, BistreResult<()>> {
        let vault = std::sync::Arc::clone(&self.vault);
        Box::pin(crate::off_worker::blocking(move || {
            let key = mcp::bearer_vault_key(&server_id);
            let clean = crate::credentials::sanitize_secret(&token);
            if clean.is_empty() {
                return vault.delete(&key);
            }
            if clean.len() > mcp::MAX_MCP_TOKEN_BYTES {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "mcp_token_too_long",
                ));
            }
            vault.put(&key, clean.as_bytes())
        }))
    }

    /// Whether the server has a token saved.
    pub fn has_mcp_token(&self, server_id: String) -> BoxFuture<'_, BistreResult<bool>> {
        let vault = std::sync::Arc::clone(&self.vault);
        Box::pin(crate::off_worker::blocking(move || {
            vault.contains(&mcp::bearer_vault_key(&server_id))
        }))
    }

    pub fn call_mcp_tool(
        &self,
        server: mcp::McpServerConfig,
        tool_name: String,
        arguments_json: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            let args: serde_json::Value = serde_json::from_str(&arguments_json)
                .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "mcp_args"))?;
            let bearer = self.load_mcp_bearer(&server.id);
            let out = mcp::call_mcp_tool_rich(
                &self.mcp_http,
                &server,
                bearer.as_deref(),
                &tool_name,
                &args,
                Some(&self.data_dir),
            )
            .await?;
            Ok(out.text)
        })
    }

    pub fn get_kv_meta(&self, key: String) -> BoxFuture<'_, BistreResult<Option<String>>> {
        Box::pin(async move { self.storage.get_kv_meta(&key) })
    }

    pub fn set_kv_meta(&self, key: String, value: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            crate::agent_tools::invalidate_broker_on_policy_change(&self.broker, &key);
            if key == "agent.mcp_servers" {
                crate::mcp_stdio::close_all_stdio_sessions();
                crate::mcp_listen::stop_all();
                self.close_dropped_http_sessions(&value);
                self.forget_dropped_tokens(&value);
            }
            self.storage.set_kv_meta(key, value)
        })
    }

    /// Before the MCP server list becomes `next`: removes the tokens of servers it no longer
    /// has. A list that does not parse removes none (its servers may still be there).
    fn forget_dropped_tokens(&self, next: &str) {
        let parse = |raw: &str| serde_json::from_str::<Vec<mcp::McpServerConfig>>(raw);
        let kept: std::collections::HashSet<String> = match parse(next) {
            Ok(servers) => servers.into_iter().map(|s| s.id).collect(),
            Err(err) => {
                tracing::warn!(%err, "new mcp server list unreadable; tokens kept");
                return;
            }
        };
        let previous = match self.storage.get_kv_meta("agent.mcp_servers") {
            Ok(Some(raw)) => match parse(&raw) {
                Ok(servers) => servers,
                Err(err) => {
                    tracing::warn!(%err, "old mcp server list unreadable; tokens kept");
                    return;
                }
            },
            Ok(None) => return,
            Err(err) => {
                tracing::warn!(key = err.key.as_key(), "old mcp server list unreadable");
                return;
            }
        };
        for server in previous.iter().filter(|s| !kept.contains(&s.id)) {
            if let Err(err) = self.vault.delete(&mcp::bearer_vault_key(&server.id)) {
                tracing::warn!(key = err.key.as_key(), server = %server.id, "mcp token not removed");
            }
        }
    }

    /// Before the MCP server list becomes `next`: forgets the HTTP eras of servers it no longer
    /// has (or whose URL changed) and closes their legacy sessions in the background. A list
    /// that does not parse forgets and closes every one.
    fn close_dropped_http_sessions(&self, next: &str) {
        let parse = |raw: &str| serde_json::from_str::<Vec<mcp::McpServerConfig>>(raw);
        let kept: Option<std::collections::HashSet<String>> = match parse(next) {
            Ok(servers) => Some(servers.iter().map(crate::mcp_era::http_era_key).collect()),
            Err(err) => {
                tracing::warn!(%err, "new mcp server list unreadable; every session closes");
                None
            }
        };
        let previous = match self.storage.get_kv_meta("agent.mcp_servers") {
            Ok(Some(raw)) => parse(&raw).unwrap_or_else(|err| {
                tracing::warn!(%err, "old mcp server list unreadable; its sessions expire");
                Vec::new()
            }),
            Ok(None) => Vec::new(),
            Err(err) => {
                tracing::warn!(key = err.key.as_key(), "old mcp server list unreadable");
                Vec::new()
            }
        };
        for (era_key, era) in crate::mcp_era::forget_http_eras_except(kept.as_ref()) {
            let Some(server) = previous
                .iter()
                .find(|s| crate::mcp_era::http_era_key(s) == era_key)
                .cloned()
            else {
                continue;
            };
            let bearer = self.load_mcp_bearer(&server.id);
            let transport = self.mcp_http.clone();
            tokio::spawn(async move {
                mcp::close_http_session(&transport, &server, bearer.as_deref(), era).await;
            });
        }
    }

    pub fn list_memory_entries(
        &self,
        scope: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<MemoryEntryRecord>>> {
        Box::pin(async move { self.storage.list_memory_entries(scope.as_deref()) })
    }

    pub fn upsert_memory_entry(
        &self,
        id: Option<String>,
        scope: String,
        scope_id: String,
        key: String,
        content: String,
        pinned: bool,
    ) -> BoxFuture<'_, BistreResult<MemoryEntryRecord>> {
        Box::pin(async move {
            self.storage
                .upsert_memory_entry(id, scope, scope_id, key, content, None, pinned)
        })
    }

    pub fn delete_memory_entry(&self, entry_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.delete_memory_entry(entry_id) })
    }

    pub fn discover_workspace_skills(
        &self,
        workspace_root: String,
    ) -> BoxFuture<'_, BistreResult<Vec<skills::SkillIndexEntry>>> {
        Box::pin(async move {
            Ok(in_place(|| {
                skills::discover_workspace_skills(Path::new(&workspace_root))
            }))
        })
    }

    pub fn load_skill_body(
        &self,
        workspace_root: String,
        skill_path: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            in_place(|| skills::load_skill_body(Path::new(&workspace_root), Path::new(&skill_path)))
        })
    }

    pub fn list_thread_grounding(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<crate::engine_grounding::NodeGrounding>>> {
        Box::pin(self.list_thread_grounding_inner(thread_id))
    }

    pub fn workspace_hooks_status(
        &self,
        workspace_root: String,
    ) -> BoxFuture<'_, BistreResult<Option<hooks::WorkspaceHooksStatus>>> {
        Box::pin(async move {
            in_place(|| self.workspace_hooks_status_inner(Path::new(&workspace_root)))
        })
    }

    pub fn approve_workspace_hooks(
        &self,
        workspace_root: String,
        digest: String,
    ) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            in_place(|| self.approve_workspace_hooks_inner(Path::new(&workspace_root), &digest))
        })
    }
    pub fn list_cron_jobs(&self) -> BoxFuture<'_, BistreResult<Vec<CronJobRecord>>> {
        Box::pin(async move { self.storage.list_cron_jobs() })
    }

    pub fn upsert_cron_job(
        &self,
        mut job: CronJobRecord,
    ) -> BoxFuture<'_, BistreResult<CronJobRecord>> {
        Box::pin(async move {
            if job.next_run_ms <= 0 {
                job.next_run_ms =
                    cron::compute_next_run_unix_ms(&job.schedule_expr, utc_now_unix_ms())?;
            }
            self.storage.upsert_cron_job(job)
        })
    }

    pub fn delete_cron_job(&self, job_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.delete_cron_job(job_id) })
    }

    pub fn list_character_cards(&self) -> BoxFuture<'_, BistreResult<Vec<CharacterCardRecord>>> {
        Box::pin(async move { self.storage.list_character_cards() })
    }

    pub fn upsert_character_card(
        &self,
        card: CharacterCardRecord,
    ) -> BoxFuture<'_, BistreResult<CharacterCardRecord>> {
        Box::pin(async move { self.storage.upsert_character_card(card) })
    }

    pub fn delete_character_card(&self, card_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.delete_character_card(card_id) })
    }

    pub fn import_character_card_file(
        &self,
        file_path: String,
    ) -> BoxFuture<'_, BistreResult<CharacterCardRecord>> {
        Box::pin(async move {
            in_place(|| self.import_character_card_file_inner(Path::new(&file_path)))
        })
    }

    pub fn export_character_card_ccv3(
        &self,
        card_id: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            let cards = self.storage.list_character_cards()?;
            let card = cards
                .into_iter()
                .find(|c| c.id == card_id)
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
            let entries = self.storage.list_story_entries(None)?;
            Ok(story::card_io::export_card_ccv3_json(&card, &entries))
        })
    }

    pub fn list_user_personas(&self) -> BoxFuture<'_, BistreResult<Vec<UserPersonaRecord>>> {
        Box::pin(async move { self.storage.list_user_personas() })
    }

    pub fn upsert_user_persona(
        &self,
        persona: UserPersonaRecord,
    ) -> BoxFuture<'_, BistreResult<UserPersonaRecord>> {
        Box::pin(async move { self.storage.upsert_user_persona(persona) })
    }

    pub fn list_story_entries(
        &self,
        book_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<StoryEntryRecord>>> {
        Box::pin(async move { self.storage.list_story_entries(book_id.as_deref()) })
    }

    pub fn upsert_story_entry(
        &self,
        entry: StoryEntryRecord,
    ) -> BoxFuture<'_, BistreResult<StoryEntryRecord>> {
        Box::pin(async move { self.storage.upsert_story_entry(entry) })
    }

    pub fn delete_story_entry(&self, entry_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.delete_story_entry(entry_id) })
    }

    pub fn list_story_progressions(
        &self,
        entry_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<StoryProgressionRecord>>> {
        Box::pin(async move { self.storage.list_story_progressions(entry_id.as_deref()) })
    }

    pub fn add_story_progression(
        &self,
        prog: StoryProgressionRecord,
    ) -> BoxFuture<'_, BistreResult<StoryProgressionRecord>> {
        Box::pin(async move { self.storage.add_story_progression(prog) })
    }

    pub fn list_story_chapters(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<StoryChapterRecord>>> {
        Box::pin(async move { self.storage.list_story_chapters(&thread_id) })
    }

    pub fn upsert_story_chapter(
        &self,
        chapter: StoryChapterRecord,
    ) -> BoxFuture<'_, BistreResult<StoryChapterRecord>> {
        Box::pin(async move { self.storage.upsert_story_chapter(chapter) })
    }

    pub fn list_story_scenes(
        &self,
        chapter_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<StorySceneRecord>>> {
        Box::pin(async move { self.storage.list_story_scenes(&chapter_id) })
    }

    pub fn upsert_story_scene(
        &self,
        scene: StorySceneRecord,
    ) -> BoxFuture<'_, BistreResult<StorySceneRecord>> {
        Box::pin(async move { self.storage.upsert_story_scene(scene) })
    }

    pub fn load_story_thread_state(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<StoryThreadStateRecord>> {
        Box::pin(async move { self.storage.load_story_thread_state(&thread_id) })
    }

    pub fn save_story_thread_state(
        &self,
        state: StoryThreadStateRecord,
    ) -> BoxFuture<'_, BistreResult<StoryThreadStateRecord>> {
        Box::pin(async move { self.storage.save_story_thread_state(state) })
    }

    pub fn list_regex_rules(&self) -> BoxFuture<'_, BistreResult<Vec<RegexRuleRecord>>> {
        Box::pin(async move { self.storage.list_regex_rules() })
    }

    pub fn upsert_regex_rule(
        &self,
        rule: RegexRuleRecord,
    ) -> BoxFuture<'_, BistreResult<RegexRuleRecord>> {
        Box::pin(async move { self.storage.upsert_regex_rule(rule) })
    }

    pub fn list_story_snapshots(
        &self,
        entity_type: String,
        entity_id: String,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<StorySnapshotRecord>>> {
        Box::pin(async move {
            self.storage
                .list_story_snapshots(&entity_type, &entity_id, limit)
        })
    }

    pub fn inspect_story_prompt(
        &self,
        thread_id: String,
        active_scene_beats: Option<String>,
    ) -> BoxFuture<'_, BistreResult<story::prompt_assembler::CompiledPromptReport>> {
        Box::pin(async move {
            self.inspect_story_prompt_inner(&thread_id, active_scene_beats.as_deref())
        })
    }

    pub fn inspect_next_request(
        &self,
        thread_id: String,
        draft: String,
    ) -> BoxFuture<'_, BistreResult<crate::engine_story::InspectedRequest>> {
        Box::pin(async move { self.inspect_next_request_inner(&thread_id, &draft) })
    }

    pub fn generate_thread_title(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<ThreadSummary>> {
        Box::pin(async move { self.generate_thread_title_inner(&thread_id).await })
    }

    pub fn translate_node(
        &self,
        thread_id: String,
        node_id: String,
        target_language: Option<String>,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>> {
        Box::pin(async move {
            self.translate_node_inner(&thread_id, &node_id, target_language.as_deref())
                .await
        })
    }

    pub fn export_provider_share_code(
        &self,
        provider_id: String,
        include_api_key: bool,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(
            async move { self.export_provider_share_code_inner(&provider_id, include_api_key) },
        )
    }

    pub fn import_provider_share_code(
        &self,
        code: String,
    ) -> BoxFuture<'_, BistreResult<ProviderProfile>> {
        Box::pin(async move { self.import_provider_share_code_inner(&code) })
    }

    pub fn list_nodes_window(
        &self,
        thread_id: String,
        before_node_id: Option<String>,
        limit: usize,
    ) -> BoxFuture<'_, BistreResult<Vec<NodeRecord>>> {
        Box::pin(async move {
            self.list_nodes_window_inner(&thread_id, before_node_id.as_deref(), limit)
        })
    }

    pub fn thread_history_rev(&self, thread_id: String) -> BoxFuture<'_, BistreResult<i64>> {
        Box::pin(async move { self.thread_history_rev_inner(&thread_id) })
    }

    pub fn subscribe_events(&self) -> broadcast::Receiver<EngineEvent> {
        self.events_tx.subscribe()
    }

    pub fn shutdown(&self) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.shutdown_inner().await })
    }
}
