//! Default models slots, local-first background work, the request inspector, and which agent tools a chat gets (split out of `egress_tests.rs`).

use crate::egress_tests::*;
use crate::test_support::MockServer;
use bistre_protocol::{DiagnosticKey, ProviderDialect, ThreadMode};

/// Compacting a chat without a manual summary uses the Default models Summary slot when
/// configured, instead of only producing the local extractive stub.
#[tokio::test]
pub(crate) async fn default_models_summary_slot_writes_compaction_summary() -> TestResult {
    let summary_srv =
        MockServer::start(vec![chat_reply("Model-written recap of earlier turns.")]).await?;
    let chat_srv = MockServer::start(Vec::new()).await?;
    let chat = local_chat(&chat_srv).await?;
    let summary_provider = chat
        .engine
        .create_provider(
            "Summarizer".to_owned(),
            ProviderDialect::CustomOpenAi,
            format!("{}/v1", summary_srv.base()),
            "sum-m".to_owned(),
            "openai".to_owned(),
            String::new(),
            Some("k".to_owned()),
        )
        .await?;
    chat.engine
        .set_kv_meta(
            "settings.default_models".to_owned(),
            serde_json::json!({
                "summaryFollowGlobal": false,
                "summaryProviderId": summary_provider.id,
                "summaryModelId": "sum-m"
            })
            .to_string(),
        )
        .await?;
    let mut parent = None;
    for i in 0..4 {
        let u = chat
            .engine
            .append_node(
                chat.thread_id.clone(),
                parent,
                bistre_protocol::NodeRole::User,
                format!("question {i}"),
                None,
            )
            .await?;
        let a = chat
            .engine
            .append_node(
                chat.thread_id.clone(),
                Some(u.id),
                bistre_protocol::NodeRole::Assistant,
                format!("answer {i}"),
                None,
            )
            .await?;
        parent = Some(a.id);
    }
    let summary_node = chat
        .engine
        .compact_thread(chat.thread_id.clone(), 2, None, None)
        .await?;
    assert_eq!(
        summary_node.content,
        "Model-written recap of earlier turns."
    );
    let seen = summary_srv.finish().await;
    assert_eq!(seen.len(), 1);
    assert!(chat_srv.finish().await.is_empty());
    Ok(())
}

/// The user's words on what to keep reach the summary request; a rewritten summary is what
/// the next request sends, and that request offers the model the tools to search and open
/// the condensed messages.
#[tokio::test]
pub(crate) async fn compaction_follows_the_users_words_and_the_edited_summary_is_sent() -> TestResult
{
    let summary_srv = MockServer::start(vec![chat_reply("Recap.")]).await?;
    let chat_srv = MockServer::start(Vec::new()).await?;
    let chat = local_chat(&chat_srv).await?;
    let summary_provider = chat
        .engine
        .create_provider(
            "Summarizer".to_owned(),
            ProviderDialect::CustomOpenAi,
            format!("{}/v1", summary_srv.base()),
            "sum-m".to_owned(),
            "openai".to_owned(),
            String::new(),
            Some("k".to_owned()),
        )
        .await?;
    chat.engine
        .set_kv_meta(
            "settings.default_models".to_owned(),
            serde_json::json!({
                "summaryFollowGlobal": false,
                "summaryProviderId": summary_provider.id,
                "summaryModelId": "sum-m"
            })
            .to_string(),
        )
        .await?;
    let mut parent = None;
    for i in 0..4 {
        let role = if i % 2 == 0 {
            bistre_protocol::NodeRole::User
        } else {
            bistre_protocol::NodeRole::Assistant
        };
        let node = chat
            .engine
            .append_node(
                chat.thread_id.clone(),
                parent,
                role,
                format!("turn {i}"),
                None,
            )
            .await?;
        parent = Some(node.id);
    }
    let summary = chat
        .engine
        .compact_thread(
            chat.thread_id.clone(),
            2,
            None,
            Some("Keep the parser decisions".to_owned()),
        )
        .await?;
    let seen = summary_srv.finish().await;
    assert_eq!(seen.len(), 1);
    assert!(
        seen[0]
            .body_json()?
            .to_string()
            .contains("Keep the parser decisions"),
        "the user's words reach the summary request"
    );

    let edited = chat
        .engine
        .rewrite_compaction_summary(
            chat.thread_id.clone(),
            summary.id.clone(),
            "Edited recap: the parser stays strict.".to_owned(),
        )
        .await?;
    assert_eq!(edited.id, summary.id);
    let inspected = chat
        .engine
        .inspect_next_request(chat.thread_id.clone(), String::new())
        .await?;
    let body = inspected.body_json;
    assert!(
        body.contains("Edited recap: the parser stays strict."),
        "{body}"
    );
    assert!(!body.contains("Recap."), "the old summary is gone: {body}");
    assert!(
        body.contains("history_search") && body.contains("history_open"),
        "{body}"
    );
    Ok(())
}

/// Generating a chat title routes to the Title slot with its prompt template, strips
/// surrounding quotes and trailing punctuation, and updates the stored thread title.
#[tokio::test]
pub(crate) async fn default_models_title_slot_generates_and_sanitizes_thread_title() -> TestResult {
    let title_srv = MockServer::start(vec![chat_reply("\"Rust Wallet Shield Design.\"")]).await?;
    let chat_srv = MockServer::start(Vec::new()).await?;
    let chat = local_chat(&chat_srv).await?;
    let title_provider = chat
        .engine
        .create_provider(
            "Titler".to_owned(),
            ProviderDialect::CustomOpenAi,
            format!("{}/v1", title_srv.base()),
            "title-m".to_owned(),
            "openai".to_owned(),
            String::new(),
            Some("k".to_owned()),
        )
        .await?;
    chat.engine
        .set_kv_meta(
            "settings.default_models".to_owned(),
            serde_json::json!({
                "titleFollowGlobal": false,
                "titleProviderId": title_provider.id,
                "titleModelId": "title-m",
                "titlePromptTemplate": "Return a three word title."
            })
            .to_string(),
        )
        .await?;
    let u = chat
        .engine
        .append_node(
            chat.thread_id.clone(),
            None,
            bistre_protocol::NodeRole::User,
            "How does Wallet Shield reserve spend?".to_owned(),
            None,
        )
        .await?;
    chat.engine
        .append_node(
            chat.thread_id.clone(),
            Some(u.id),
            bistre_protocol::NodeRole::Assistant,
            "It reserves spend in SQLite before each paid POST.".to_owned(),
            None,
        )
        .await?;
    let updated = chat.engine.generate_thread_title(chat.thread_id).await?;
    assert_eq!(updated.title, "Rust Wallet Shield Design");
    let seen = title_srv.finish().await;
    assert_eq!(seen.len(), 1);
    let body = String::from_utf8_lossy(&seen[0].body);
    assert!(body.contains("Return a three word title."), "{body}");
    assert!(body.contains("\"model\":\"title-m\""), "{body}");
    assert!(chat_srv.finish().await.is_empty());
    Ok(())
}

/// Translating a message routes to the Translation slot with the configured target language
/// and commits the translation as a new sibling version on the same parent.
#[tokio::test]
pub(crate) async fn default_models_translate_adds_sibling_version_in_target_language() -> TestResult
{
    let trans_srv = MockServer::start(vec![chat_reply("Xin chao the gioi")]).await?;
    let chat_srv = MockServer::start(Vec::new()).await?;
    let chat = local_chat(&chat_srv).await?;
    let trans_provider = chat
        .engine
        .create_provider(
            "Translator".to_owned(),
            ProviderDialect::CustomOpenAi,
            format!("{}/v1", trans_srv.base()),
            "trans-m".to_owned(),
            "openai".to_owned(),
            String::new(),
            Some("k".to_owned()),
        )
        .await?;
    chat.engine
        .set_kv_meta(
            "settings.default_models".to_owned(),
            serde_json::json!({
                "translationFollowGlobal": false,
                "translationProviderId": trans_provider.id,
                "translationModelId": "trans-m",
                "translationTargetLanguage": "Vietnamese"
            })
            .to_string(),
        )
        .await?;
    let u = chat
        .engine
        .append_node(
            chat.thread_id.clone(),
            None,
            bistre_protocol::NodeRole::User,
            "Say hi".to_owned(),
            None,
        )
        .await?;
    let a = chat
        .engine
        .append_node(
            chat.thread_id.clone(),
            Some(u.id.clone()),
            bistre_protocol::NodeRole::Assistant,
            "Hello world".to_owned(),
            None,
        )
        .await?;
    let translated = chat
        .engine
        .translate_node(chat.thread_id.clone(), a.id.clone(), None)
        .await?;
    assert_eq!(translated.parent_id.as_deref(), Some(u.id.as_str()));
    assert_eq!(translated.role, bistre_protocol::NodeRole::Assistant);
    assert_eq!(translated.content, "Xin chao the gioi");
    assert!(
        translated
            .provider_meta_json
            .as_deref()
            .unwrap_or("")
            .contains(&a.id)
    );
    let seen = trans_srv.finish().await;
    assert_eq!(seen.len(), 1);
    let body = String::from_utf8_lossy(&seen[0].body);
    assert!(body.contains("Vietnamese"), "{body}");
    assert!(chat_srv.finish().await.is_empty());
    Ok(())
}

/// With "Prefer free local models" on, background utility tasks that follow the global
/// default pick an enabled loopback local provider instead of a paid cloud provider.
#[tokio::test]
pub(crate) async fn wallet_local_first_routes_background_tasks_to_local_provider() -> TestResult {
    let local_srv = MockServer::start(vec![chat_reply("Local Generated Title")]).await?;
    let dir = tempfile::tempdir()?;
    let engine =
        crate::InProcessEngine::open_for_test(dir.path(), crate::http_clients::provider_client()?)?;
    // Configure a cloud global provider (would fail if contacted) plus an enabled local provider.
    let cloud = engine
        .create_provider(
            "Cloud".to_owned(),
            ProviderDialect::OpenAi,
            "https://cloud.invalid/v1".to_owned(),
            "cloud-m".to_owned(),
            "openai".to_owned(),
            String::new(),
            Some("k".to_owned()),
        )
        .await?;
    let _local = engine
        .create_provider(
            "Local".to_owned(),
            ProviderDialect::CustomOpenAi,
            format!("{}/v1", local_srv.base()),
            "local-m".to_owned(),
            "ollama".to_owned(),
            String::new(),
            None,
        )
        .await?;
    let mut settings = engine.load_settings().await?;
    settings.wallet_local_first = true;
    settings.active_provider_id = cloud.id;
    settings.active_model_id = "cloud-m".to_owned();
    engine.save_settings(settings).await?;
    let thread = engine
        .create_thread(None, "New chat".to_owned(), ThreadMode::Chat, None, None)
        .await?;
    engine
        .append_node(
            thread.id.clone(),
            None,
            bistre_protocol::NodeRole::User,
            "Explain local inference".to_owned(),
            None,
        )
        .await?;
    let updated = engine.generate_thread_title(thread.id).await?;
    assert_eq!(updated.title, "Local Generated Title");
    assert_eq!(local_srv.finish().await.len(), 1);
    Ok(())
}

/// The request inspector returns core's real serialized wire request without credentials
/// (even under query auth) and fails closed on invalid custom headers.
#[tokio::test]
pub(crate) async fn inspect_next_request_returns_real_wire_body_without_keys_and_blocks_invalid_headers()
-> TestResult {
    let server = MockServer::start(Vec::new()).await?;
    let chat = local_chat(&server).await?;
    chat.engine
        .set_kv_meta(
            format!("provider.adv:{}", chat.provider_id),
            serde_json::json!({
                "endpointPathOverride": "/custom/chat",
                "authHeaderMode": "query_param"
            })
            .to_string(),
        )
        .await?;
    chat.engine
        .save_provider_overrides(
            chat.provider_id.clone(),
            r#"{"X-Trace":"inspect-me"}"#.to_owned(),
            r#"{"seed":7}"#.to_owned(),
        )
        .await?;
    let inspected = chat
        .engine
        .inspect_next_request(chat.thread_id.clone(), "preview draft".to_owned())
        .await?;
    assert_eq!(inspected.method, "POST");
    assert!(
        inspected.url.ends_with("/v1/custom/chat"),
        "{}",
        inspected.url
    );
    assert!(!inspected.url.contains("key="), "no key in inspected URL");
    assert!(
        inspected
            .headers
            .iter()
            .all(|(k, _)| !matches!(k.as_str(), "authorization" | "x-api-key" | "x-goog-api-key"))
    );
    assert!(
        inspected
            .headers
            .iter()
            .any(|(k, v)| k == "x-trace" && v == "inspect-me")
    );
    let body: serde_json::Value = serde_json::from_str(&inspected.body_json)?;
    assert_eq!(body["seed"], 7);
    assert_eq!(body["messages"][0]["content"], "preview draft");

    // Invalid stored header blocks inspection just like it blocks sending.
    chat.engine
        .set_kv_meta(
            format!("provider.overrides:{}", chat.provider_id),
            serde_json::json!({ "headers_json": "{\"X-Bad\":\"a\\nb\"}", "body_json": "" })
                .to_string(),
        )
        .await?;
    let err = chat
        .engine
        .inspect_next_request(chat.thread_id, String::new())
        .await
        .err()
        .ok_or("invalid headers must block inspection")?;
    assert_eq!(err.key, DiagnosticKey::ProviderHeadersInvalid);
    Ok(())
}

/// `agent.web_search` controls whether `web_search` is exposed (empty = Off even with a
/// workspace; `"duckduckgo"` or a custom URL = On even without a workspace).
#[tokio::test]
pub(crate) async fn agent_web_search_setting_controls_tool_exposure() -> TestResult {
    let dir = tempfile::tempdir()?;
    let storage = bistre_storage::StorageHandle::open(dir.path().join("ws.sqlite"))?;
    let has_search =
        |s: &bistre_storage::StorageHandle| -> Result<bool, Box<dyn std::error::Error>> {
            let cat = crate::agent_tools::resolve_active_tool_catalog(s, None, ThreadMode::Chat)?;
            Ok(cat
                .canonical_schemas
                .iter()
                .any(|v| v.get("name").and_then(serde_json::Value::as_str) == Some("web_search")))
        };

    // With no workspace and `agent.web_search = "duckduckgo"`, web_search must be exposed.
    storage.set_kv_meta("agent.web_search".to_owned(), "duckduckgo".to_owned())?;
    assert!(has_search(&storage)?, "duckduckgo enables web_search");

    // With a workspace and `agent.web_search = ""`, web_search must be hidden even if allowed.
    storage.set_kv_meta(
        "agent.workspace_root".to_owned(),
        dir.path().to_string_lossy().into_owned(),
    )?;
    storage.set_kv_meta(
        "agent.tool_permissions".to_owned(),
        r#"{"web_search":"allow"}"#.to_owned(),
    )?;
    storage.set_kv_meta("agent.web_search".to_owned(), String::new())?;
    assert!(
        !has_search(&storage)?,
        "empty agent.web_search disables web_search"
    );
    Ok(())
}

/// Whenever tools are on (outside Write mode), CLAUDE.md/AGENTS.md, the workspace skills
/// index, and saved memory entries are injected into the turn context.
#[tokio::test]
pub(crate) async fn agent_prompt_injects_claude_md_skills_and_memory_in_chat_mode() -> TestResult {
    let dir = tempfile::tempdir()?;
    std::fs::write(dir.path().join("CLAUDE.md"), "Always run cargo clippy.")?;
    let skill_dir = dir.path().join(".agents").join("skills").join("review");
    std::fs::create_dir_all(&skill_dir)?;
    std::fs::write(
        skill_dir.join("SKILL.md"),
        "---\nname: review\ndescription: Audit pull requests carefully.\n---\nFull body here.",
    )?;
    let storage = bistre_storage::StorageHandle::open(dir.path().join("ctx.sqlite"))?;
    storage.set_kv_meta(
        "agent.workspace_root".to_owned(),
        dir.path().to_string_lossy().into_owned(),
    )?;
    storage.upsert_memory_entry(
        None,
        "global".to_owned(),
        "default".to_owned(),
        "preferred_style".to_owned(),
        "Prefer concise Rust functions.".to_owned(),
        None,
        true,
    )?;
    let thread = storage.create_thread(None, "chat", ThreadMode::Chat, None, None)?;
    let u = storage.append_node(
        thread.id.clone(),
        None,
        bistre_protocol::NodeRole::User,
        "hi".to_owned(),
        None,
    )?;
    let (_, _, prompt) =
        crate::engine_runs::load_turn_context(&storage, &thread.id, &u.id, "Base", None)?;
    assert!(prompt.contains("Always run cargo clippy."), "{prompt}");
    assert!(prompt.contains("review"), "{prompt}");
    assert!(
        prompt.contains("Audit pull requests carefully."),
        "{prompt}"
    );
    assert!(
        prompt.contains("Prefer concise Rust functions."),
        "{prompt}"
    );
    Ok(())
}

/// Active tool catalog exposes `agent_memory` and `skill_load` when applicable.
#[tokio::test]
pub(crate) async fn agent_catalog_exposes_skill_load_and_agent_memory_tools() -> TestResult {
    let dir = tempfile::tempdir()?;
    let storage = bistre_storage::StorageHandle::open(dir.path().join("tools.sqlite"))?;
    storage.set_kv_meta(
        "agent.workspace_root".to_owned(),
        dir.path().to_string_lossy().into_owned(),
    )?;
    let cat = crate::agent_tools::resolve_active_tool_catalog(&storage, None, ThreadMode::Chat)?;
    let names: Vec<&str> = cat
        .canonical_schemas
        .iter()
        .filter_map(|v| v.get("name").and_then(serde_json::Value::as_str))
        .collect();
    assert!(names.contains(&"agent_memory"), "{names:?}");
    assert!(names.contains(&"skill_load"), "{names:?}");
    Ok(())
}

/// `computer_use` is hidden by default, never exposed in Plan or Write mode, and only appears when
/// explicitly enabled in `settings.ui_prefs`.
#[tokio::test]
pub(crate) async fn computer_use_is_off_by_default_and_never_exposed_in_plan_or_write_mode()
-> TestResult {
    let dir = tempfile::tempdir()?;
    let storage = bistre_storage::StorageHandle::open(dir.path().join("cu_cat.sqlite"))?;
    let has_cu = |mode: ThreadMode| -> Result<bool, Box<dyn std::error::Error>> {
        let cat = crate::agent_tools::resolve_active_tool_catalog(&storage, None, mode)?;
        Ok(cat
            .canonical_schemas
            .iter()
            .any(|v| v.get("name").and_then(serde_json::Value::as_str) == Some("computer_use")))
    };
    assert!(!has_cu(ThreadMode::Chat)?, "must be off by default");

    storage.set_kv_meta(
        "settings.ui_prefs".to_owned(),
        r#"{"computerUseEnabled":true}"#.to_owned(),
    )?;
    assert!(has_cu(ThreadMode::Chat)?, "enabled in Chat mode");
    assert!(has_cu(ThreadMode::Code)?, "enabled in Code mode");
    assert!(
        !has_cu(ThreadMode::Plan)?,
        "never exposed in read-only Plan mode"
    );
    assert!(!has_cu(ThreadMode::Write)?, "never exposed in Write mode");
    Ok(())
}

/// A provider share code brings the Custom provider's API format and sign-in mode to a fresh
/// provider; the key comes along only when the user asks for it.
#[tokio::test]
pub(crate) async fn a_provider_share_code_keeps_the_api_format_and_leaves_the_key_out() -> TestResult
{
    let server = MockServer::start(Vec::new()).await?;
    let chat = local_chat(&server).await?;
    chat.engine
        .set_kv_meta(
            format!("provider.adv:{}", chat.provider_id),
            serde_json::json!({
                "customDialect": "anthropic_messages",
                "authHeaderMode": "query_param"
            })
            .to_string(),
        )
        .await?;
    let code = chat
        .engine
        .export_provider_share_code(chat.provider_id.clone(), false)
        .await?;
    let copy = chat.engine.import_provider_share_code(code).await?;
    assert_ne!(copy.id, chat.provider_id);
    assert!(!copy.has_api_key);
    let adv: serde_json::Value = serde_json::from_str(
        &chat
            .engine
            .get_kv_meta(format!("provider.adv:{}", copy.id))
            .await?
            .ok_or("no advanced settings")?,
    )?;
    assert_eq!(adv["customDialect"], "anthropic_messages", "{adv}");
    assert_eq!(adv["authHeaderMode"], "query_param", "{adv}");

    let with_key = chat
        .engine
        .export_provider_share_code(chat.provider_id.clone(), true)
        .await?;
    let keyed = chat.engine.import_provider_share_code(with_key).await?;
    assert!(keyed.has_api_key);
    Ok(())
}
