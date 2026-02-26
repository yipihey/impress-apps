//! Citation metrics endpoint.

use crate::client::AdsClient;
use crate::error::{AdsError, Result};
use crate::types::Metrics;

impl AdsClient {
    /// Get citation metrics for a set of papers.
    ///
    /// Returns h-index, g-index, citation counts, and other bibliometric indicators.
    pub async fn metrics(&self, bibcodes: &[&str]) -> Result<Metrics> {
        let body = serde_json::json!({
            "bibcodes": bibcodes,
            "types": ["basic", "citations", "indicators"],
        });

        let response_body = self.post_json("/metrics", &body).await?;
        serde_json::from_str(&response_body)
            .map_err(|e| AdsError::Parse(format!("Invalid metrics response: {}", e)))
    }
}
