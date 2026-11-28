//! What each paid request was for, so background use can be shown apart from chat.

use serde::{Deserialize, Serialize};

use crate::MoneyMicros;

/// The reason a request was paid for; stored on every `wallet_ledger` row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SpendPurpose {
    /// A chat run's own requests.
    Chat,
    /// Read-only helpers a run started (`agent_delegate`).
    Helper,
    /// Naming a chat after its first reply.
    Title,
    /// Shortening a long chat.
    Summary,
    /// Translating a message.
    Translation,
    /// Read aloud and live voice.
    Voice,
}

impl SpendPurpose {
    /// Every purpose, chat first.
    pub const ALL: [Self; 6] = [
        Self::Chat,
        Self::Helper,
        Self::Title,
        Self::Summary,
        Self::Translation,
        Self::Voice,
    ];

    /// The stored column value.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Chat => "chat",
            Self::Helper => "helper",
            Self::Title => "title",
            Self::Summary => "summary",
            Self::Translation => "translation",
            Self::Voice => "voice",
        }
    }

    /// Parses a stored column value; `None` for anything else.
    #[must_use]
    pub fn parse(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|p| p.as_str() == raw)
    }
}

/// Settled spend for one purpose over a time window.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PurposeUsage {
    pub purpose: SpendPurpose,
    pub requests: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cost: MoneyMicros,
}

#[cfg(test)]
mod tests {
    use super::SpendPurpose;

    #[test]
    fn every_purpose_round_trips_its_stored_name() {
        for purpose in SpendPurpose::ALL {
            assert_eq!(SpendPurpose::parse(purpose.as_str()), Some(purpose));
        }
        assert_eq!(SpendPurpose::parse("other"), None);
    }
}
