//! Native HTTP client using reqwest

use super::{HttpError, HttpResponse};
use reqwest::Client;
use std::time::Duration;

pub struct HttpClient {
    client: Client,
    user_agent: String,
}

impl HttpClient {
    pub fn new(user_agent: &str) -> Self {
        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("Failed to create HTTP client");

        Self {
            client,
            user_agent: user_agent.to_string(),
        }
    }

    pub async fn get(&self, url: &str) -> Result<HttpResponse, HttpError> {
        let response = self
            .client
            .get(url)
            .header("User-Agent", &self.user_agent)
            .send()
            .await
            .map_err(|e| HttpError::RequestFailed {
                message: e.to_string(),
            })?;

        let status = response.status().as_u16();

        if status == 429 {
            return Err(HttpError::RateLimited);
        }

        let headers = response
            .headers()
            .iter()
            .filter_map(|(k, v)| v.to_str().ok().map(|v| (k.to_string(), v.to_string())))
            .collect();

        let body = response.text().await.map_err(|e| HttpError::ParseError {
            message: e.to_string(),
        })?;

        Ok(HttpResponse {
            status,
            body,
            headers,
        })
    }

    pub async fn get_with_params(
        &self,
        url: &str,
        params: &[(&str, &str)],
    ) -> Result<HttpResponse, HttpError> {
        let url =
            reqwest::Url::parse_with_params(url, params).map_err(|_| HttpError::InvalidUrl {
                url: url.to_string(),
            })?;

        self.get(url.as_str()).await
    }
}

impl Default for HttpClient {
    fn default() -> Self {
        Self::new("imbib/1.0")
    }
}
