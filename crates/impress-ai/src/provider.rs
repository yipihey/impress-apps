use async_trait::async_trait;

use crate::types::{ChatRequest, ModelSummary};
use crate::{EventStream, Result};

/// Transport-neutral inference boundary used by the durable task executor.
///
/// oMLX is the first implementation, but the conversation graph, provenance,
/// tool loop, and scheduler do not depend on its concrete HTTP client. A host
/// can therefore install another local or remote provider without creating a
/// second execution path or weakening the recorded run identity.
#[async_trait]
pub trait InferenceProvider: Send + Sync {
    /// Stable provider family recorded on every agent run (for example
    /// `omlx`).
    fn provider_id(&self) -> &str;

    /// Stable endpoint identity within that family (for example
    /// `local-omlx` or `lab-server`).
    fn endpoint_id(&self) -> &str;

    async fn models(&self) -> Result<Vec<ModelSummary>>;

    async fn stream(&self, request: ChatRequest) -> Result<EventStream>;
}
