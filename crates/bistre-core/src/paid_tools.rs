//! The provider's tools billed per call (Anthropic and `OpenAI` web search, `OpenAI` code
//! interpreter): sent only when the user turns them on for the provider and the catalog prices
//! each call, and counted after the reply from the provider's usage report
//! (`UsageMetrics::{web_searches, code_sessions}`), so a reply can pass a spending limit
//! (Spec 06).

use bistre_protocol::ProviderDialect;
use serde_json::{Value, json};

/// The provider's tools billed per call that a request sends.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PaidTools {
    /// Anthropic `web_search` or `OpenAI` Responses `web_search`.
    pub search: bool,
    /// `OpenAI` Responses `code_interpreter`.
    pub code: bool,
}

/// The paid tools a request sends: turned on, beside Bistre's tools, and only where the
/// catalog prices each call, so its fee can be counted after the reply (an unpriced tool is
/// never sent). A spending limit does not hold them back: the user turned them on knowing a
/// reply can pass it (Spec 06).
pub(crate) fn paid_tools(
    prov_adv: &crate::provider_prefs::ProviderAdvancedPrefs,
    dialect: ProviderDialect,
    rates: Option<&crate::registry::ModelRates>,
    bistre_tools_sent: bool,
) -> PaidTools {
    let on = prov_adv.paid_provider_tools
        && bistre_tools_sent
        && matches!(
            dialect,
            ProviderDialect::OpenAi | ProviderDialect::Anthropic
        );
    let priced = |r: fn(&crate::registry::ModelRates) -> Option<i64>| rates.and_then(r).is_some();
    PaidTools {
        search: on && priced(|r| r.per_search_micros),
        code: on && dialect == ProviderDialect::OpenAi && priced(|r| r.per_code_session_micros),
    }
}

/// Anthropic's basic web search (every model, no code execution needed) and the most
/// searches one request runs.
const ANTHROPIC_WEB_SEARCH: &str = "web_search_20250305";
const MAX_PROVIDER_SEARCHES: u32 = 5;

/// `tools` with the paid tools `paid` names: each takes the place of Bistre's tool of the
/// same job (a request holds a tool name once, and one search tool keeps the model's choice
/// plain), first so a cache mark stays on the last of Bistre's.
pub(crate) fn with_paid_tools(
    dialect: ProviderDialect,
    paid: PaidTools,
    tools: Vec<Value>,
) -> Vec<Value> {
    let mut out = Vec::new();
    if paid.search {
        out.push(match dialect {
            ProviderDialect::Anthropic => json!({
                "type": ANTHROPIC_WEB_SEARCH,
                "name": "web_search",
                "max_uses": MAX_PROVIDER_SEARCHES,
            }),
            _ => json!({ "type": "web_search" }),
        });
    }
    if paid.code {
        out.push(json!({ "type": "code_interpreter", "container": { "type": "auto" } }));
    }
    let replaced =
        |t: &Value| paid.search && t.get("name").and_then(Value::as_str) == Some("web_search");
    out.extend(tools.into_iter().filter(|t| !replaced(t)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider_prefs::ProviderAdvancedPrefs;
    use crate::providers::StreamRequestOptions;
    use crate::registry::ModelRates;
    use bistre_protocol::{GenerationParams, MoneyMicros, UsageMetrics};
    use std::collections::HashMap;

    fn priced() -> ModelRates {
        ModelRates {
            per_search_micros: Some(10_000),
            per_code_session_micros: Some(30_000),
            ..ModelRates::default()
        }
    }

    /// Off by default; on, only for Anthropic and `OpenAI`, only beside Bistre's tools, and
    /// only for a call the catalog prices.
    #[test]
    fn paid_tools_go_only_when_turned_on_and_priced() {
        let mut adv = ProviderAdvancedPrefs::default();
        let rates = priced();
        assert_eq!(
            paid_tools(&adv, ProviderDialect::OpenAi, Some(&rates), true),
            PaidTools::default()
        );
        adv.paid_provider_tools = true;
        assert_eq!(
            paid_tools(&adv, ProviderDialect::OpenAi, Some(&rates), true),
            PaidTools {
                search: true,
                code: true
            }
        );
        assert_eq!(
            paid_tools(&adv, ProviderDialect::Anthropic, Some(&rates), true),
            PaidTools {
                search: true,
                code: false
            }
        );
        assert_eq!(
            paid_tools(&adv, ProviderDialect::GoogleGemini, Some(&rates), true),
            PaidTools::default()
        );
        assert_eq!(
            paid_tools(&adv, ProviderDialect::OpenAi, Some(&rates), false),
            PaidTools::default()
        );
        assert_eq!(
            paid_tools(&adv, ProviderDialect::OpenAi, None, true),
            PaidTools::default(),
            "an unpriced call is never sent"
        );
    }

    fn tools_of(dialect: ProviderDialect, paid: PaidTools) -> Vec<String> {
        let local = vec![
            json!({"name": "web_search", "description": "d", "input_schema": {"type": "object"}}),
            json!({"name": "read", "description": "d", "input_schema": {"type": "object"}}),
        ];
        let options = StreamRequestOptions {
            tools_wire: Some(&local),
            paid_tools: paid,
            ..StreamRequestOptions::default()
        };
        let base = match dialect {
            ProviderDialect::Anthropic => "https://api.anthropic.com",
            _ => "https://api.openai.com/v1",
        };
        let body = crate::request_body::build_stream_request_full(
            dialect,
            base,
            "m",
            "",
            &crate::test_support::user_turn("news?"),
            GenerationParams::default(),
            false,
            None,
            &HashMap::<String, String>::new(),
            &options,
        )
        .body
        .unwrap_or(Value::Null);
        body["tools"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|t| {
                format!(
                    "{}:{}",
                    t["type"].as_str().unwrap_or("-"),
                    t["name"].as_str().unwrap_or("-")
                )
            })
            .collect()
    }

    /// The provider's search takes the place of Bistre's `web_search`; `OpenAI` also gets its
    /// code interpreter; nothing changes while they are off.
    #[test]
    fn paid_tools_replace_bistres_search_in_the_request() {
        let both = PaidTools {
            search: true,
            code: true,
        };
        let anthropic = tools_of(
            ProviderDialect::Anthropic,
            PaidTools {
                search: true,
                code: false,
            },
        );
        assert_eq!(anthropic, ["web_search_20250305:web_search", "-:read"]);
        let openai = tools_of(ProviderDialect::OpenAi, both);
        assert_eq!(
            openai[..2],
            ["web_search:-".to_owned(), "code_interpreter:-".to_owned()]
        );
        assert_eq!(openai.len(), 3, "{openai:?}");
        assert!(
            !openai.iter().any(|t| t.ends_with(":web_search")),
            "{openai:?}"
        );
        let off = tools_of(ProviderDialect::OpenAi, PaidTools::default());
        assert!(off.iter().any(|t| t.ends_with(":web_search")), "{off:?}");
    }

    /// Searches and code sessions are counted from the finished reply and billed at the
    /// catalog's fee, on top of tokens.
    #[test]
    fn searches_and_code_sessions_are_counted_after_the_reply() {
        let mut claude = UsageMetrics::default();
        crate::wire_parse::merge_sse_usage(
            ProviderDialect::Anthropic,
            r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":10,"server_tool_use":{"web_search_requests":3}}}"#,
            &mut claude,
        );
        assert_eq!(claude.web_searches, 3);
        let mut gpt = UsageMetrics::default();
        crate::wire_parse::merge_sse_usage(
            ProviderDialect::OpenAi,
            r#"{"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1},"output":[{"type":"web_search_call","action":{"type":"search"}},{"type":"web_search_call","action":{"type":"open_page"}},{"type":"code_interpreter_call","container_id":"c1"},{"type":"code_interpreter_call","container_id":"c1"},{"type":"message"}]}}"#,
            &mut gpt,
        );
        assert_eq!((gpt.web_searches, gpt.code_sessions), (2, 1));
        let doc = json!({"m": {"input_cost_per_token": 0, "output_cost_per_token": 0,
            "search_context_cost_per_query": {"search_context_size_low": 0.025, "search_context_size_high": 0.05},
            "code_interpreter_cost_per_session": 0.03}});
        let entries = crate::registry::parse_source("litellm", doc.to_string().as_bytes());
        let rates = entries.first().map_or_default(|e| e.rates);
        assert_eq!(
            rates.per_search_micros,
            Some(50_000),
            "the dearest search size"
        );
        assert_eq!(
            rates
                .cost_for_dialect(ProviderDialect::OpenAi, &gpt)
                .map(MoneyMicros::as_micros),
            Some(130_000)
        );
        let unpriced = ModelRates {
            per_search_micros: None,
            ..rates
        };
        assert_eq!(
            unpriced.cost_for_dialect(ProviderDialect::OpenAi, &gpt),
            None
        );
    }
}
