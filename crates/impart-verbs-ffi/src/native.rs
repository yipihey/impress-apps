//! Async callback boundary into the running impart app.

use std::sync::Arc;

use impart_service::{
    AppStatus, ConversationRecord, ImpartBackend, ImpartService, LogEntry, MessageRecord,
};
use impress_service_core::pipeline::context::report_refusal;
use impress_service_core::refusal::codes;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};

#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct NativeCallResult {
    pub status: u16,
    pub body_json: String,
}

#[cfg_attr(feature = "native", uniffi::export(callback_interface))]
#[async_trait::async_trait]
pub trait ImpartNativeCallbacks: Send + Sync {
    async fn invoke(&self, method: String, args_json: String) -> NativeCallResult;
}

struct NativeBackend {
    callback: Arc<dyn ImpartNativeCallbacks>,
}

impl ImpartBackend for NativeBackend {
    fn service(&self) -> Arc<dyn ImpartService> {
        Arc::new(NativeImpartService {
            callback: Arc::clone(&self.callback),
        })
    }
}

pub(crate) struct NativeImpartService {
    callback: Arc<dyn ImpartNativeCallbacks>,
}

impl NativeImpartService {
    async fn invoke<T: DeserializeOwned>(&self, method: &str, args: Value) -> Result<T, ()> {
        let args_json = args.to_string();
        let result = self.callback.invoke(method.into(), args_json).await;
        if !(200..300).contains(&result.status) {
            let body: Value = serde_json::from_str(&result.body_json).unwrap_or(Value::Null);
            let code = body
                .get("code")
                .and_then(Value::as_str)
                .unwrap_or(codes::VERB_FAILED);
            let message = body
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("impart native operation failed");
            report_refusal(code, message);
            return Err(());
        }
        serde_json::from_str(&result.body_json).map_err(|error| {
            report_refusal(
                codes::INTERNAL,
                format!("impart {method} returned an invalid result: {error}"),
            );
        })
    }
}

#[async_trait::async_trait]
impl ImpartService for NativeImpartService {
    async fn status(&self) -> AppStatus {
        self.invoke("status", json!({})).await.unwrap_or(AppStatus {
            running: false,
            detail: String::new(),
        })
    }

    async fn get_logs(&self, limit: u32, level: Option<String>) -> Vec<LogEntry> {
        self.invoke("get_logs", json!({ "limit": limit, "level": level }))
            .await
            .unwrap_or_default()
    }

    async fn list_conversations(
        &self,
        limit: u32,
        include_archived: bool,
    ) -> Vec<ConversationRecord> {
        self.invoke(
            "list_conversations",
            json!({ "limit": limit, "include_archived": include_archived }),
        )
        .await
        .unwrap_or_default()
    }

    async fn get_conversation(&self, conversation_id: String) -> Option<ConversationRecord> {
        self.invoke(
            "get_conversation",
            json!({ "conversation_id": conversation_id }),
        )
        .await
        .unwrap_or(None)
    }

    async fn create_conversation(
        &self,
        title: String,
        summary: Option<String>,
    ) -> Option<ConversationRecord> {
        self.invoke(
            "create_conversation",
            json!({ "title": title, "summary": summary }),
        )
        .await
        .unwrap_or(None)
    }

    async fn update_conversation(
        &self,
        conversation_id: String,
        title: Option<String>,
        summary: Option<String>,
    ) -> bool {
        self.invoke(
            "update_conversation",
            json!({ "conversation_id": conversation_id, "title": title, "summary": summary }),
        )
        .await
        .unwrap_or(false)
    }

    async fn add_message(
        &self,
        conversation_id: String,
        content: String,
        role: Option<String>,
    ) -> Option<MessageRecord> {
        self.invoke(
            "add_message",
            json!({ "conversation_id": conversation_id, "content": content, "role": role }),
        )
        .await
        .unwrap_or(None)
    }

    async fn record_decision(
        &self,
        conversation_id: String,
        decision: String,
        rationale: Option<String>,
    ) -> bool {
        self.invoke(
            "record_decision",
            json!({ "conversation_id": conversation_id, "decision": decision, "rationale": rationale }),
        )
        .await
        .unwrap_or(false)
    }

    async fn record_artifact(
        &self,
        conversation_id: String,
        title: String,
        kind: Option<String>,
        reference: Option<String>,
    ) -> bool {
        self.invoke(
            "record_artifact",
            json!({ "conversation_id": conversation_id, "title": title, "kind": kind, "reference": reference }),
        )
        .await
        .unwrap_or(false)
    }

    async fn branch_conversation(
        &self,
        conversation_id: String,
        title: String,
    ) -> Option<ConversationRecord> {
        self.invoke(
            "branch_conversation",
            json!({ "conversation_id": conversation_id, "title": title }),
        )
        .await
        .unwrap_or(None)
    }
}

/// Install the app-owned callback before accepting any verb dispatch.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn register_native_backend(callback: Box<dyn ImpartNativeCallbacks>) {
    impart_service::register_backend(Box::new(NativeBackend {
        callback: Arc::from(callback),
    }));
}
