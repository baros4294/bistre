//! Web sources of a chat's replies (B2), read back from the stored node metadata.

use bistre_protocol::{BistreResult, NodeRole};

use crate::InProcessEngine;
use crate::grounding::{GroundingSource, parse_grounding_meta};

/// The sources one reply used.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NodeGrounding {
    pub node_id: String,
    pub sources: Vec<GroundingSource>,
}

impl InProcessEngine {
    /// Every reply in `thread_id` that used web sources, oldest first.
    pub(crate) async fn list_thread_grounding_inner(
        &self,
        thread_id: String,
    ) -> BistreResult<Vec<NodeGrounding>> {
        crate::off_worker::off_worker(&self.storage, move |s| {
            Ok(s.list_nodes(&thread_id)?
                .into_iter()
                .filter(|n| n.role == NodeRole::Assistant)
                .filter_map(|n| {
                    let sources = parse_grounding_meta(n.provider_meta_json.as_deref());
                    (!sources.is_empty()).then_some(NodeGrounding {
                        node_id: n.id,
                        sources,
                    })
                })
                .collect())
        })
        .await
    }
}
