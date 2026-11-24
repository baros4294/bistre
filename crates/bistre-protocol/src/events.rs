//! Streamed engine events, daemon RPC envelopes, and live tool-approval decisions.

use serde::{Deserialize, Serialize};

use crate::{
    AgentRunRecord, BistreError, DiagnosticKey, NodeRecord, PowerGuardStatus, RunStepRecord,
    StreamChunk, ToolRiskTier,
};

/// User's response to a live tool-approval request paused inside an agent run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolApprovalDecision {
    ApproveOnce,
    ApproveForThread,
    Deny,
}

impl ToolApprovalDecision {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ApproveOnce => "approve_once",
            Self::ApproveForThread => "approve_for_thread",
            Self::Deny => "deny",
        }
    }

    pub fn parse(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "approve_once" | "once" | "allow" => Self::ApproveOnce,
            "approve_for_thread" | "thread" | "chat" | "allow_chat" => Self::ApproveForThread,
            _ => Self::Deny,
        }
    }
}

/// Monotonically ordered persisted event envelope enabling lossless IPC / FGS resume (`resume_after_cursor`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CursorEventRecord {
    pub cursor: u64,
    pub thread_id: Option<String>,
    pub event: EngineEvent,
    pub created_at_ms: i64,
}

/// Length-prefixed JSON RPC request frame sent from `LocalIpcEngine` to `bistre-daemon`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DaemonRpcRequest {
    pub request_id: u64,
    pub method: String,
    pub params_json: String,
}

/// Length-prefixed JSON RPC response frame returned by `bistre-daemon`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DaemonRpcResponse {
    pub request_id: u64,
    pub ok: bool,
    pub payload_json: String,
    pub error: Option<BistreError>,
}

/// Batched event union streamed from Rust core to UI / IPC subscribers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum EngineEvent {
    RunStarted {
        thread_id: String,
        node_id: String,
    },
    DeltaBatch {
        thread_id: String,
        chunks: Vec<StreamChunk>,
    },
    ThinkingDelta {
        thread_id: String,
        node_id: String,
        delta: String,
    },
    RunFinished {
        thread_id: String,
        node_id: String,
        cancelled: bool,
    },
    RunStateChanged {
        run: AgentRunRecord,
    },
    RunStepUpdated {
        step: RunStepRecord,
    },
    ToolApprovalRequested {
        thread_id: String,
        run_id: String,
        call_id: String,
        tool_name: String,
        arguments_json: String,
        risk_tier: ToolRiskTier,
    },
    ToolExecutionUpdated {
        thread_id: String,
        run_id: String,
        call_id: String,
        tool_name: String,
        risk_tier: ToolRiskTier,
        status: String,
        summary: String,
        output_text: String,
        diff_text: Option<String>,
        checkpoint_id: Option<String>,
        duration_ms: i64,
    },
    SteeringQueueChanged {
        thread_id: String,
        pending_count: u32,
    },
    PowerStatusChanged {
        status: PowerGuardStatus,
    },
    NodeCommitted {
        node: NodeRecord,
    },
    DraftSaved {
        thread_id: String,
        updated_at_ms: i64,
    },
    DiagnosticRaised {
        key: DiagnosticKey,
        detail_code: Option<String>,
    },
    LocalePackVerified {
        pack_id: String,
        semver: String,
    },
    LiveVoiceState {
        session_id: String,
        state: String,
        detail: Option<String>,
    },
    LiveVoiceTranscript {
        session_id: String,
        role: String,
        text: String,
        is_final: bool,
    },
    LiveVoiceAudio {
        session_id: String,
        wav_base64: String,
    },
}
