//! Fail-closed Computer use (desktop) and Phone use (Android) tool contract and host-action
//! broker (Spec 04 & Spec 06).
//!
//! Safety invariants:
//! - Off by default (`settings.ui_prefs.computerUseEnabled == true` required to expose the tool).
//! - Never exposed to sub-agents, read-only Plan mode, or Write mode.
//! - Every single call requires explicit user approval (never auto-approved by preset, tool-allow
//!   policy, or `ApproveForThread`).
//! - All inputs are parsed and bounded at the boundary (`text <= 4,000` chars, `key <= 64` chars,
//!   coordinates `0..=16_384`, scroll delta `-10_000..=10_000`).
//! - Screenshots returned by the host stay strictly in memory for the immediate next model step
//!   and are never persisted to SQLite or disk.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, EngineEvent, ToolRiskTier, lock_or_recover,
};
use bistre_storage::StorageHandle;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::{broadcast, oneshot};
use uuid::Uuid;

use crate::events::emit;
use crate::tools::ToolExecutionOutput;

/// Maximum characters accepted by the `type` action.
pub const MAX_TYPE_CHARS: usize = 4_000;
/// Maximum byte length accepted by the `key` chord action.
pub const MAX_KEY_LEN: usize = 64;
/// Maximum coordinate value accepted on either axis.
pub const MAX_COORD: i64 = 16_384;
/// Maximum absolute scroll delta accepted on either axis.
pub const MAX_SCROLL_DELTA: i64 = 10_000;
/// Maximum concurrent in-flight host-action requests.
const MAX_PENDING_HOST_ACTIONS: usize = 16;
/// Maximum time to wait for the native host bridge to finish one action.
const HOST_ACTION_TIMEOUT: Duration = Duration::from_secs(60);
/// Maximum base64 screenshot bytes kept transiently for the next turn (`2 MiB`).
pub const MAX_TRANSIENT_SCREENSHOT_B64_BYTES: usize = 2 * 1024 * 1024;

/// Strictly validated `computer_use` action parsed from tool arguments.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum ComputerUseAction {
    Screenshot,
    Click {
        x: i64,
        y: i64,
    },
    DoubleClick {
        x: i64,
        y: i64,
    },
    RightClick {
        x: i64,
        y: i64,
    },
    Move {
        x: i64,
        y: i64,
    },
    Type {
        text: String,
    },
    Key {
        key: String,
    },
    Scroll {
        x: i64,
        y: i64,
        delta_x: i64,
        delta_y: i64,
    },
}

fn bounded_coord(args: &Value, field: &str) -> BistreResult<i64> {
    let v = args
        .get(field)
        .and_then(Value::as_i64)
        .ok_or_else(|| BistreError::with_detail(DiagnosticKey::InvalidInput, "invalid_coord"))?;
    if !(0..=MAX_COORD).contains(&v) {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "coord_out_of_bounds",
        ));
    }
    Ok(v)
}

fn bounded_scroll(args: &Value, field: &str) -> BistreResult<i64> {
    let v = args.get(field).and_then(Value::as_i64).unwrap_or(0);
    if !(-MAX_SCROLL_DELTA..=MAX_SCROLL_DELTA).contains(&v) {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "scroll_out_of_bounds",
        ));
    }
    Ok(v)
}

/// Parses and validates untrusted JSON tool arguments into a [`ComputerUseAction`].
pub fn parse_action(args: &Value) -> BistreResult<ComputerUseAction> {
    let action = args
        .get("action")
        .and_then(Value::as_str)
        .map(str::trim)
        .ok_or_else(|| BistreError::with_detail(DiagnosticKey::InvalidInput, "missing_action"))?;
    match action {
        "screenshot" => Ok(ComputerUseAction::Screenshot),
        "click" => Ok(ComputerUseAction::Click {
            x: bounded_coord(args, "x")?,
            y: bounded_coord(args, "y")?,
        }),
        "double_click" => Ok(ComputerUseAction::DoubleClick {
            x: bounded_coord(args, "x")?,
            y: bounded_coord(args, "y")?,
        }),
        "right_click" => Ok(ComputerUseAction::RightClick {
            x: bounded_coord(args, "x")?,
            y: bounded_coord(args, "y")?,
        }),
        "move" => Ok(ComputerUseAction::Move {
            x: bounded_coord(args, "x")?,
            y: bounded_coord(args, "y")?,
        }),
        "type" => {
            let text = args.get("text").and_then(Value::as_str).ok_or_else(|| {
                BistreError::with_detail(DiagnosticKey::InvalidInput, "missing_text")
            })?;
            if text.is_empty() || text.chars().count() > MAX_TYPE_CHARS {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "text_out_of_bounds",
                ));
            }
            if text
                .chars()
                .any(|c| c.is_control() && !matches!(c, '\n' | '\t'))
            {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "control_chars_forbidden",
                ));
            }
            Ok(ComputerUseAction::Type {
                text: text.to_owned(),
            })
        }
        "key" => {
            let key = args
                .get("key")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| {
                    BistreError::with_detail(DiagnosticKey::InvalidInput, "missing_key")
                })?;
            if key.len() > MAX_KEY_LEN || !key.bytes().all(|b| b.is_ascii_graphic()) {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "key_out_of_bounds",
                ));
            }
            Ok(ComputerUseAction::Key {
                key: key.to_owned(),
            })
        }
        "scroll" => Ok(ComputerUseAction::Scroll {
            x: bounded_coord(args, "x")?,
            y: bounded_coord(args, "y")?,
            delta_x: bounded_scroll(args, "delta_x")?,
            delta_y: bounded_scroll(args, "delta_y")?,
        }),
        _ => Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "unknown_computer_action",
        )),
    }
}

/// Returns `true` only when `kv_meta["settings.ui_prefs"]` explicitly enables `computerUseEnabled`.
/// Fails closed (`false`) on missing or unreadable preferences.
pub fn is_computer_use_enabled(storage: &StorageHandle) -> bool {
    match storage.get_kv_meta("settings.ui_prefs") {
        Ok(Some(raw)) if !raw.trim().is_empty() => match serde_json::from_str::<Value>(&raw) {
            Ok(v) => v
                .get("computerUseEnabled")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            Err(err) => {
                tracing::warn!(%err, "ui_prefs json unreadable; computer_use stays disabled");
                false
            }
        },
        Ok(_) => false,
        Err(err) => {
            tracing::warn!(
                key = err.key.as_key(),
                "ui_prefs unreadable; computer_use stays disabled"
            );
            false
        }
    }
}

/// Canonical JSON schema for `computer_use` (adapts wording for Android Phone use).
pub fn computer_use_schema(is_android: bool) -> Value {
    let description = if is_android {
        "Phone use: inspect or interact with the Android screen via Accessibility (screenshot, click, double_click, right_click, move, type, key including back/home/recents/notifications, scroll). Every call requires explicit user approval."
    } else {
        "Computer use: inspect or interact with the desktop screen (screenshot, click, double_click, right_click, move, type, key chords, scroll). Every call requires explicit user approval."
    };
    json!({
        "name": "computer_use",
        "description": description,
        "parameters": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["screenshot", "click", "double_click", "right_click", "move", "type", "key", "scroll"]
                },
                "x": { "type": "integer", "minimum": 0, "maximum": MAX_COORD },
                "y": { "type": "integer", "minimum": 0, "maximum": MAX_COORD },
                "text": { "type": "string", "maxLength": MAX_TYPE_CHARS },
                "key": { "type": "string", "maxLength": MAX_KEY_LEN },
                "delta_x": { "type": "integer", "minimum": -MAX_SCROLL_DELTA, "maximum": MAX_SCROLL_DELTA },
                "delta_y": { "type": "integer", "minimum": -MAX_SCROLL_DELTA, "maximum": MAX_SCROLL_DELTA }
            },
            "required": ["action"]
        }
    })
}

/// Result returned by the native platform host bridge over FFI (`respond_host_action`).
#[derive(Debug, Clone)]
pub struct HostActionResponse {
    pub ok: bool,
    pub output_text: String,
    /// Optional transient PNG screenshot (base64, never stored to SQLite or disk).
    pub image_base64: Option<String>,
}

/// Coordinates pending host-bridge requests and ephemeral per-run screenshots.
#[derive(Debug, Default)]
pub struct HostActionBroker {
    pending: Mutex<HashMap<String, oneshot::Sender<HostActionResponse>>>,
    transient_screenshots: Mutex<HashMap<String, Vec<String>>>,
}

impl HostActionBroker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Delivers the native host response for `request_id`. Returns `false` if no waiter exists.
    pub fn deliver(&self, request_id: &str, response: HostActionResponse) -> bool {
        let tx = lock_or_recover(&self.pending, "host_actions").remove(request_id);
        tx.is_some_and(|sender| sender.send(response).is_ok())
    }

    /// Consumes any transient screenshots queued for `run_id` so they appear only on the next turn.
    pub fn take_transient_screenshots(&self, run_id: &str) -> Vec<String> {
        lock_or_recover(&self.transient_screenshots, "transient_screenshots")
            .remove(run_id)
            .unwrap_or_default()
    }

    /// Drops any transient screenshots left behind when `run_id` finishes or cancels.
    pub fn clear_run(&self, run_id: &str) {
        lock_or_recover(&self.transient_screenshots, "transient_screenshots").remove(run_id);
    }

    /// Emits `EngineEvent::HostActionRequested` and waits for the native host result, racing
    /// run cancellation and `HOST_ACTION_TIMEOUT`.
    pub async fn execute(
        &self,
        events_tx: &broadcast::Sender<EngineEvent>,
        cancel_flag: &Arc<AtomicBool>,
        thread_id: &str,
        run_id: &str,
        args: &Value,
    ) -> BistreResult<ToolExecutionOutput> {
        let action = parse_action(args)?;
        let action_json = serde_json::to_string(&action)
            .map_err(|_| BistreError::new(DiagnosticKey::InvalidInput))?;
        let request_id = format!("host_{}", Uuid::now_v7());
        let (tx, rx) = oneshot::channel();
        {
            let mut map = lock_or_recover(&self.pending, "host_actions");
            if map.len() >= MAX_PENDING_HOST_ACTIONS {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InternalError,
                    "too_many_host_actions",
                ));
            }
            map.insert(request_id.clone(), tx);
        }

        emit(
            events_tx,
            EngineEvent::HostActionRequested {
                request_id: request_id.clone(),
                thread_id: thread_id.to_owned(),
                run_id: run_id.to_owned(),
                action_json,
            },
        );

        let waited = tokio::select! {
            biased;
            () = crate::providers::until_cancelled(cancel_flag) => {
                lock_or_recover(&self.pending, "host_actions").remove(&request_id);
                return Err(BistreError::with_detail(
                    DiagnosticKey::ProviderStreamInterrupted,
                    "cancelled",
                ));
            }
            res = tokio::time::timeout(HOST_ACTION_TIMEOUT, rx) => res,
        };
        lock_or_recover(&self.pending, "host_actions").remove(&request_id);

        let response = match waited {
            Ok(Ok(r)) => r,
            Ok(Err(_)) => {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InternalError,
                    "host_bridge_disconnected",
                ));
            }
            Err(_) => {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InternalError,
                    "host_action_timeout",
                ));
            }
        };

        if cancel_flag.load(Ordering::SeqCst) {
            return Err(BistreError::with_detail(
                DiagnosticKey::ProviderStreamInterrupted,
                "cancelled",
            ));
        }

        let mut note = response.output_text;
        if let Some(b64) = response.image_base64
            && !b64.is_empty()
            && b64.len() <= MAX_TRANSIENT_SCREENSHOT_B64_BYTES
        {
            let mut shots = lock_or_recover(&self.transient_screenshots, "transient_screenshots");
            shots.entry(run_id.to_owned()).or_default().push(b64);
            if note.trim().is_empty() {
                "Captured transient screenshot (attached to next turn only; never stored)."
                    .clone_into(&mut note);
            }
        }

        Ok(ToolExecutionOutput {
            tool_name: "computer_use".to_owned(),
            risk_tier: ToolRiskTier::Tier2ExternalSideEffect,
            ok: response.ok,
            summary: format!(
                "computer_use {:?}",
                args.get("action")
                    .and_then(Value::as_str)
                    .unwrap_or("action")
            ),
            output_text: note,
            diff_text: None,
            checkpoint_id: None,
            duration_ms: 0,
            media_attachments: Vec::new(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[test]
    fn parse_action_enforces_strict_bounds() -> TestResult {
        assert_eq!(
            parse_action(&json!({"action": "screenshot"}))?,
            ComputerUseAction::Screenshot
        );
        assert_eq!(
            parse_action(&json!({"action": "click", "x": 120, "y": 340}))?,
            ComputerUseAction::Click { x: 120, y: 340 }
        );
        assert!(parse_action(&json!({"action": "click", "x": -1, "y": 10})).is_err());
        assert!(parse_action(&json!({"action": "click", "x": 20_000, "y": 10})).is_err());
        assert!(
            parse_action(&json!({"action": "type", "text": "a".repeat(MAX_TYPE_CHARS + 1)}))
                .is_err()
        );
        assert!(parse_action(&json!({"action": "type", "text": "hi\x07"})).is_err());
        assert!(parse_action(&json!({"action": "key", "key": "Ctrl+C"})).is_ok());
        assert!(
            parse_action(&json!({"action": "key", "key": "a".repeat(MAX_KEY_LEN + 1)})).is_err()
        );
        assert!(parse_action(&json!({"action": "key", "key": "Ctrl C"})).is_err());
        assert!(
            parse_action(&json!({"action": "scroll", "x": 10, "y": 10, "delta_y": 99_999}))
                .is_err()
        );
        assert!(parse_action(&json!({"action": "drop_db"})).is_err());
        Ok(())
    }

    #[test]
    fn computer_use_is_off_by_default_and_fails_closed() -> TestResult {
        let dir = tempdir()?;
        let storage = StorageHandle::open(dir.path().join("cu.sqlite"))?;
        assert!(!is_computer_use_enabled(&storage));

        storage.set_kv_meta("settings.ui_prefs".to_owned(), "not-json".to_owned())?;
        assert!(!is_computer_use_enabled(&storage));

        storage.set_kv_meta(
            "settings.ui_prefs".to_owned(),
            r#"{"computerUseEnabled":false}"#.to_owned(),
        )?;
        assert!(!is_computer_use_enabled(&storage));

        storage.set_kv_meta(
            "settings.ui_prefs".to_owned(),
            r#"{"computerUseEnabled":true}"#.to_owned(),
        )?;
        assert!(is_computer_use_enabled(&storage));
        Ok(())
    }

    #[tokio::test]
    async fn host_action_broker_delivers_response_and_keeps_screenshots_transient() -> TestResult {
        let broker = Arc::new(HostActionBroker::new());
        let (tx, mut rx) = broadcast::channel(16);
        let cancel = Arc::new(AtomicBool::new(false));

        let b2 = Arc::clone(&broker);
        let responder = tokio::spawn(async move {
            if let Ok(EngineEvent::HostActionRequested { request_id, .. }) = rx.recv().await {
                let delivered = b2.deliver(
                    &request_id,
                    HostActionResponse {
                        ok: true,
                        output_text: String::new(),
                        image_base64: Some("iVBORw0KGgo=".to_owned()),
                    },
                );
                assert!(delivered);
            }
        });

        let out = broker
            .execute(&tx, &cancel, "t1", "run1", &json!({"action": "screenshot"}))
            .await?;
        responder.await?;
        assert!(out.ok);
        assert!(
            out.media_attachments.is_empty(),
            "screenshots must never persist as attachments"
        );

        let shots = broker.take_transient_screenshots("run1");
        assert_eq!(shots, vec!["iVBORw0KGgo=".to_owned()]);
        assert!(
            broker.take_transient_screenshots("run1").is_empty(),
            "transient screenshot must be cleared after single consumption"
        );
        Ok(())
    }
}
