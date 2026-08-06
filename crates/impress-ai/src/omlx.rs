use std::time::Duration;

use futures_util::StreamExt;
use reqwest::header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE};
use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;

use crate::types::{
    ChatRequest, ModelContentPart, ModelMessage, ModelSummary, StreamEvent, ToolDefinition,
};
use crate::InferenceProvider;
use crate::{Error, Result};

pub const DEFAULT_URL: &str = "http://127.0.0.1:8000";
pub type EventStream = ReceiverStream<Result<StreamEvent>>;

/// OpenAI-compatible client tuned for oMLX's discovery and streaming surface.
#[derive(Clone)]
pub struct OmlxClient {
    client: reqwest::Client,
    base_url: String,
    api_key: Option<String>,
    endpoint_id: String,
}

impl OmlxClient {
    pub fn new(base_url: impl Into<String>, api_key: Option<String>) -> Result<Self> {
        Self::with_endpoint_id(base_url, api_key, "omlx")
    }

    pub fn with_endpoint_id(
        base_url: impl Into<String>,
        api_key: Option<String>,
        endpoint_id: impl Into<String>,
    ) -> Result<Self> {
        let base_url = normalized_base_url(base_url.into());
        if base_url.is_empty() {
            return Err(Error::Invalid("oMLX URL cannot be empty".into()));
        }
        let client = reqwest::Client::builder()
            .no_proxy()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(15 * 60))
            .build()?;
        Ok(Self {
            client,
            base_url,
            api_key,
            endpoint_id: endpoint_id.into(),
        })
    }

    pub fn endpoint_id(&self) -> &str {
        &self.endpoint_id
    }

    /// Canonical endpoint root used for requests and provenance. Accepting a
    /// configured OpenAI-compatible `/v1` URL here avoids the easy-to-miss
    /// `/v1/v1/models` failure when device settings are shared with clients
    /// that expect the versioned base URL.
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    fn request(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        let request = self
            .client
            .request(method, format!("{}{path}", self.base_url));
        match &self.api_key {
            Some(key) => request.header(AUTHORIZATION, format!("Bearer {key}")),
            None => request,
        }
    }

    pub async fn models(&self) -> Result<Vec<ModelSummary>> {
        let listed = self
            .request(reqwest::Method::GET, "/v1/models")
            .header(ACCEPT, "application/json")
            .send()
            .await
            .map_err(|error| Error::Omlx(error.to_string()))?
            .error_for_status()
            .map_err(|error| Error::Omlx(error.to_string()))?
            .json::<Value>()
            .await
            .map_err(|error| Error::Omlx(error.to_string()))?;

        let status = match self
            .request(reqwest::Method::GET, "/v1/models/status")
            .send()
            .await
        {
            Ok(response) if response.status().is_success() => response.json::<Value>().await.ok(),
            _ => None,
        };

        let mut models = listed
            .get("data")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|item| {
                let id = item.get("id")?.as_str()?.to_string();
                if id == "MarkItDown" {
                    return None;
                }
                let matching_status = status
                    .as_ref()
                    .and_then(|value| value.get("models"))
                    .and_then(Value::as_array)
                    .and_then(|items| {
                        items.iter().find(|candidate| {
                            candidate.get("id").and_then(Value::as_str) == Some(&id)
                        })
                    });
                let loaded = matching_status
                    .and_then(|value| value.get("loaded"))
                    .and_then(Value::as_bool)
                    .or_else(|| item.get("loaded").and_then(Value::as_bool))
                    .unwrap_or(false);
                let max_context_window = matching_status
                    .and_then(|value| value.get("max_context_window"))
                    .and_then(Value::as_u64)
                    .or_else(|| item.get("max_context_window").and_then(Value::as_u64));
                let modalities = item
                    .get("modalities")
                    .and_then(Value::as_array)
                    .map(|values| {
                        values
                            .iter()
                            .filter_map(Value::as_str)
                            .map(str::to_string)
                            .collect()
                    })
                    .unwrap_or_else(|| vec!["text".into()]);
                Some(ModelSummary {
                    id,
                    loaded,
                    max_context_window,
                    modalities,
                })
            })
            .collect::<Vec<_>>();
        models.sort_by(|left, right| {
            (!left.loaded)
                .cmp(&(!right.loaded))
                .then_with(|| left.id.to_lowercase().cmp(&right.id.to_lowercase()))
        });
        Ok(models)
    }

    pub async fn stream(&self, request: ChatRequest) -> Result<EventStream> {
        request.validate()?;
        let mut payload = json!({
            "model": request.model,
            "messages": request.messages.iter().map(message_json).collect::<Vec<_>>(),
            "temperature": request.temperature,
            "max_tokens": request.max_tokens,
            "stream": true,
            "stream_options": { "include_usage": true },
            "chat_template_kwargs": { "enable_thinking": request.thinking },
        });
        if !request.tools.is_empty() {
            payload["tools"] = Value::Array(request.tools.iter().map(tool_json).collect());
            payload["tool_choice"] = Value::String("auto".into());
        }

        let response = self
            .request(reqwest::Method::POST, "/v1/chat/completions")
            .header(ACCEPT, "text/event-stream")
            .header(CONTENT_TYPE, "application/json")
            .json(&payload)
            .send()
            .await
            .map_err(|error| Error::Omlx(error.to_string()))?;
        if !response.status().is_success() {
            let status = response.status();
            let detail = response.text().await.unwrap_or_default();
            return Err(Error::Omlx(format!("HTTP {status}: {detail}")));
        }

        let (sender, receiver) = mpsc::channel(64);
        tokio::spawn(async move {
            let mut upstream = response.bytes_stream();
            let mut pending = String::new();
            let mut terminal_sent = false;
            while let Some(chunk) = upstream.next().await {
                let chunk = match chunk {
                    Ok(chunk) => chunk,
                    Err(error) => {
                        let _ = sender.send(Err(Error::Omlx(error.to_string()))).await;
                        return;
                    }
                };
                pending.push_str(&String::from_utf8_lossy(&chunk));
                while let Some(newline) = pending.find('\n') {
                    let line = pending[..newline].trim().trim_end_matches('\r').to_string();
                    pending.drain(..=newline);
                    if line.is_empty() || line.starts_with(':') {
                        continue;
                    }
                    let data = line.strip_prefix("data:").map(str::trim).unwrap_or(&line);
                    if data == "[DONE]" {
                        let _ = sender
                            .send(Ok(StreamEvent::Done {
                                finish_reason: None,
                            }))
                            .await;
                        terminal_sent = true;
                        break;
                    }
                    match parse_chunk(data) {
                        Ok(events) => {
                            for event in events {
                                if sender.send(Ok(event)).await.is_err() {
                                    return;
                                }
                            }
                        }
                        Err(error) => {
                            let _ = sender.send(Err(error)).await;
                            return;
                        }
                    }
                }
                if terminal_sent {
                    return;
                }
            }
            if !terminal_sent {
                let _ = sender
                    .send(Ok(StreamEvent::Done {
                        finish_reason: None,
                    }))
                    .await;
            }
        });
        Ok(ReceiverStream::new(receiver))
    }
}

fn normalized_base_url(value: String) -> String {
    let trimmed = value.trim().trim_end_matches('/');
    trimmed.strip_suffix("/v1").unwrap_or(trimmed).to_string()
}

#[async_trait::async_trait]
impl InferenceProvider for OmlxClient {
    fn provider_id(&self) -> &str {
        "omlx"
    }

    fn endpoint_id(&self) -> &str {
        self.endpoint_id()
    }

    async fn models(&self) -> Result<Vec<ModelSummary>> {
        self.models().await
    }

    async fn stream(&self, request: ChatRequest) -> Result<EventStream> {
        self.stream(request).await
    }
}

fn message_json(message: &ModelMessage) -> Value {
    let content = match message.content.as_slice() {
        [ModelContentPart::Text { text }] => Value::String(text.clone()),
        _ => serde_json::to_value(&message.content).unwrap_or(Value::Array(vec![])),
    };
    let mut value = json!({ "role": message.role, "content": content });
    if let Some(name) = &message.name {
        value["name"] = Value::String(name.clone());
    }
    if let Some(tool_call_id) = &message.tool_call_id {
        value["tool_call_id"] = Value::String(tool_call_id.clone());
    }
    if !message.tool_calls.is_empty() {
        value["tool_calls"] = Value::Array(
            message
                .tool_calls
                .iter()
                .map(|call| {
                    json!({
                        "id": call.id,
                        "type": "function",
                        "function": {
                            "name": call.name,
                            "arguments": call.arguments,
                        },
                    })
                })
                .collect(),
        );
    }
    value
}

fn tool_json(tool: &ToolDefinition) -> Value {
    json!({
        "type": "function",
        "function": {
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.input_schema,
        }
    })
}

fn content_text(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(|part| match part {
                Value::String(text) => Some(text.as_str()),
                Value::Object(object) => object.get("text").and_then(Value::as_str),
                _ => None,
            })
            .collect(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

fn parse_chunk(data: &str) -> Result<Vec<StreamEvent>> {
    let value: Value = serde_json::from_str(data)
        .map_err(|error| Error::Omlx(format!("invalid stream event: {error}")))?;
    let mut events = Vec::new();
    if let Some(choice) = value
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first())
    {
        let delta = choice.get("delta").unwrap_or(choice);
        let reasoning = ["reasoning_content", "reasoning", "thinking"]
            .into_iter()
            .map(|key| content_text(delta.get(key)))
            .find(|text| !text.is_empty())
            .unwrap_or_default();
        if !reasoning.is_empty() {
            events.push(StreamEvent::Reasoning { text: reasoning });
        }
        let text = content_text(delta.get("content"));
        if !text.is_empty() {
            events.push(StreamEvent::Token { text });
        }
        if let Some(calls) = delta.get("tool_calls").and_then(Value::as_array) {
            for call in calls {
                let function = call.get("function").unwrap_or(&Value::Null);
                events.push(StreamEvent::ToolCallDelta {
                    index: call.get("index").and_then(Value::as_u64).unwrap_or(0) as u32,
                    id: call.get("id").and_then(Value::as_str).map(str::to_string),
                    name: function
                        .get("name")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    arguments: function
                        .get("arguments")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                });
            }
        }
        if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
            events.push(StreamEvent::Done {
                finish_reason: Some(reason.into()),
            });
        }
    }
    if let Some(usage) = value.get("usage").filter(|usage| usage.is_object()) {
        events.push(StreamEvent::Usage {
            usage: usage.clone(),
        });
    }
    Ok(events)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ImageUrl, Role};

    #[test]
    fn keeps_text_only_messages_backward_compatible() {
        let value = message_json(&ModelMessage::text(Role::User, "hello"));
        assert_eq!(value["content"], "hello");
    }

    #[test]
    fn accepts_endpoint_roots_and_openai_versioned_urls() {
        let root = OmlxClient::new("http://127.0.0.1:8000/", None).unwrap();
        assert_eq!(root.base_url(), "http://127.0.0.1:8000");

        let versioned = OmlxClient::new(" http://laptop.tailnet.ts.net:8000/v1/ ", None).unwrap();
        assert_eq!(versioned.base_url(), "http://laptop.tailnet.ts.net:8000");
    }

    #[tokio::test]
    async fn discovers_loaded_models_from_a_versioned_configured_endpoint() {
        let mut server = mockito::Server::new_async().await;
        let listed = server
            .mock("GET", "/v1/models")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{"data":[{"id":"text-model","modalities":["text"]},{"id":"vision-model","modalities":["text","image"]}]}"#,
            )
            .create_async()
            .await;
        let status = server
            .mock("GET", "/v1/models/status")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(
                r#"{"models":[{"id":"vision-model","loaded":true,"max_context_window":32768}]}"#,
            )
            .create_async()
            .await;

        let client = OmlxClient::new(format!("{}/v1", server.url()), None).unwrap();
        let models = client.models().await.unwrap();

        listed.assert_async().await;
        status.assert_async().await;
        assert_eq!(models[0].id, "vision-model");
        assert!(models[0].loaded);
        assert_eq!(models[0].max_context_window, Some(32_768));
        assert_eq!(models[0].modalities, ["text", "image"]);
        assert_eq!(models[1].id, "text-model");
    }

    #[test]
    fn emits_openai_multimodal_content_arrays() {
        let value = message_json(&ModelMessage {
            role: Role::User,
            content: vec![
                ModelContentPart::Text {
                    text: "look".into(),
                },
                ModelContentPart::ImageUrl {
                    image_url: ImageUrl {
                        url: "data:image/png;base64,AA==".into(),
                        detail: None,
                    },
                },
            ],
            name: None,
            tool_call_id: None,
            tool_calls: vec![],
        });
        assert!(value["content"].is_array());
        assert_eq!(value["content"][1]["type"], "image_url");
    }

    #[test]
    fn parses_reasoning_tools_usage_and_finish_reason() {
        let events = parse_chunk(
            r#"{"choices":[{"delta":{"reasoning_content":"why","content":"answer","tool_calls":[{"index":0,"id":"call_1","function":{"name":"scix_search","arguments":"{\"q\":\"stars\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":4}}"#,
        )
        .unwrap();
        assert!(matches!(&events[0], StreamEvent::Reasoning { text } if text == "why"));
        assert!(events.iter().any(|event| matches!(event, StreamEvent::ToolCallDelta { name: Some(name), .. } if name == "scix_search")));
        assert!(events
            .iter()
            .any(|event| matches!(event, StreamEvent::Usage { .. })));
        assert!(events.iter().any(|event| matches!(event, StreamEvent::Done { finish_reason: Some(reason) } if reason == "tool_calls")));
    }

    #[test]
    fn accepts_common_thinking_delta_spellings() {
        for key in ["reasoning_content", "reasoning", "thinking"] {
            let chunk = format!(r#"{{"choices":[{{"delta":{{"{key}":"working"}}}}]}}"#);
            let events = parse_chunk(&chunk).unwrap();
            assert!(matches!(&events[0], StreamEvent::Reasoning { text } if text == "working"));
        }
    }
}
