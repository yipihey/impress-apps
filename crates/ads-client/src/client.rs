//! The ADS API client.

use crate::error::{AdsError, Result};
use crate::rate_limit::RateLimiter;
use reqwest::Client;
use std::time::Duration;

/// Async client for the NASA ADS / SciX API.
///
/// # Example
///
/// ```no_run
/// # async fn example() -> ads_client::error::Result<()> {
/// let client = ads_client::AdsClient::from_env()?;
/// let results = client.search("author:\"Einstein\" year:1905", 10).await?;
/// for paper in &results.papers {
///     println!("{} ({})", paper.title, paper.bibcode);
/// }
/// # Ok(())
/// # }
/// ```
#[derive(Clone)]
pub struct AdsClient {
    pub(crate) http: Client,
    pub(crate) api_token: String,
    pub(crate) base_url: String,
    pub(crate) rate_limiter: RateLimiter,
}

impl AdsClient {
    /// Create a new client with the given API token.
    pub fn new(api_token: impl Into<String>) -> Self {
        let http = Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("Failed to create HTTP client");

        Self {
            http,
            api_token: api_token.into(),
            base_url: "https://api.adsabs.harvard.edu/v1".to_string(),
            rate_limiter: RateLimiter::new(5.0),
        }
    }

    /// Create a client from the `ADS_API_TOKEN` environment variable.
    pub fn from_env() -> Result<Self> {
        let token = std::env::var("ADS_API_TOKEN").map_err(|_| AdsError::AuthRequired)?;
        if token.is_empty() {
            return Err(AdsError::AuthRequired);
        }
        Ok(Self::new(token))
    }

    /// Override the base URL (useful for testing or SciX).
    pub fn with_base_url(mut self, url: impl Into<String>) -> Self {
        self.base_url = url.into();
        self
    }

    /// Override the rate limit (requests per second).
    pub fn with_rate_limit(mut self, per_second: f64) -> Self {
        self.rate_limiter = RateLimiter::new(per_second);
        self
    }

    /// Make an authenticated GET request to the ADS API.
    pub(crate) async fn get(&self, path: &str, params: &[(&str, &str)]) -> Result<String> {
        self.rate_limiter.acquire().await;

        let url = format!("{}{}", self.base_url, path);
        let response = self
            .http
            .get(&url)
            .header("Authorization", format!("Bearer {}", self.api_token))
            .header("User-Agent", "ads-client/0.1.0")
            .query(params)
            .send()
            .await?;

        self.rate_limiter.update_from_headers(response.headers()).await;
        handle_response(response).await
    }

    /// Make an authenticated POST request with a JSON body.
    pub(crate) async fn post_json(
        &self,
        path: &str,
        body: &serde_json::Value,
    ) -> Result<String> {
        self.rate_limiter.acquire().await;

        let url = format!("{}{}", self.base_url, path);
        let response = self
            .http
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.api_token))
            .header("User-Agent", "ads-client/0.1.0")
            .json(body)
            .send()
            .await?;

        self.rate_limiter.update_from_headers(response.headers()).await;
        handle_response(response).await
    }

    /// Make an authenticated POST request with a text body.
    pub(crate) async fn post_text(
        &self,
        path: &str,
        content_type: &str,
        body: &str,
    ) -> Result<String> {
        self.rate_limiter.acquire().await;

        let url = format!("{}{}", self.base_url, path);
        let response = self
            .http
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.api_token))
            .header("User-Agent", "ads-client/0.1.0")
            .header("Content-Type", content_type)
            .body(body.to_string())
            .send()
            .await?;

        self.rate_limiter.update_from_headers(response.headers()).await;
        handle_response(response).await
    }

    /// Make an authenticated PUT request with a JSON body.
    pub(crate) async fn put_json(
        &self,
        path: &str,
        body: &serde_json::Value,
    ) -> Result<String> {
        self.rate_limiter.acquire().await;

        let url = format!("{}{}", self.base_url, path);
        let response = self
            .http
            .put(&url)
            .header("Authorization", format!("Bearer {}", self.api_token))
            .header("User-Agent", "ads-client/0.1.0")
            .json(body)
            .send()
            .await?;

        self.rate_limiter.update_from_headers(response.headers()).await;
        handle_response(response).await
    }

    /// Make an authenticated DELETE request.
    pub(crate) async fn delete(&self, path: &str) -> Result<String> {
        self.rate_limiter.acquire().await;

        let url = format!("{}{}", self.base_url, path);
        let response = self
            .http
            .delete(&url)
            .header("Authorization", format!("Bearer {}", self.api_token))
            .header("User-Agent", "ads-client/0.1.0")
            .send()
            .await?;

        self.rate_limiter.update_from_headers(response.headers()).await;
        handle_response(response).await
    }
}

/// Handle the HTTP response, mapping status codes to errors.
async fn handle_response(response: reqwest::Response) -> Result<String> {
    let status = response.status().as_u16();

    match status {
        200..=299 => Ok(response.text().await?),
        401 => Err(AdsError::AuthRequired),
        404 => Err(AdsError::NotFound("Resource not found".to_string())),
        429 => {
            let retry_after = response
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.parse::<u64>().ok())
                .map(Duration::from_secs);
            Err(AdsError::RateLimited { retry_after })
        }
        _ => {
            let body = response.text().await.unwrap_or_default();
            Err(AdsError::Api {
                status,
                message: body,
            })
        }
    }
}
