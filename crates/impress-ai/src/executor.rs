use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use futures_util::StreamExt;
use impel_core::{ExecutionOutcome, TaskError, TaskExecutor, TaskStoreApi};
use impress_core::item::{Item, Value as CoreValue};
use serde_json::{json, Value};

use crate::blob::BlobStore;
use crate::research::ResearchContextProvider;
use crate::store::{AiStore, INFERENCE_TASK_KIND, TITLE_SUGGESTION_TASK_KIND};
use crate::tools::{ToolAdapter, ToolCallAccumulator};
use crate::types::{
    CompletionRecord, ModelContentPart, ModelMessage, ModelToolCall, Role, StreamEvent,
    ToolDefinition, ToolInvocationRecord,
};
use crate::{Error, InferenceProvider, OmlxClient};

const DEFAULT_MAX_TOOL_ROUNDS: u32 = 6;

/// Scheduler adapter that turns durable `impress.ai.respond` tasks into oMLX
/// runs and appends the attributed assistant message back to the shared graph.
///
/// Tool schemas come from an installed [`ToolAdapter`]. Each model call is
/// executed, recorded, appended to the endpoint transcript, and followed by a
/// new oMLX round. Only the final answer becomes a durable chat message.
pub struct AiTaskExecutor {
    ai: Arc<AiStore>,
    provider: Arc<dyn InferenceProvider>,
    blobs: Arc<dyn BlobStore>,
    tool_catalog: BTreeMap<String, Vec<ToolDefinition>>,
    tool_adapter: Option<Arc<dyn ToolAdapter>>,
    research: Option<Arc<dyn ResearchContextProvider>>,
    max_tool_rounds: u32,
}

impl AiTaskExecutor {
    pub fn new(ai: Arc<AiStore>, omlx: OmlxClient, blobs: Arc<dyn BlobStore>) -> Self {
        Self::with_provider(ai, Arc::new(omlx), blobs)
    }

    pub fn with_provider(
        ai: Arc<AiStore>,
        provider: Arc<dyn InferenceProvider>,
        blobs: Arc<dyn BlobStore>,
    ) -> Self {
        Self {
            ai,
            provider,
            blobs,
            tool_catalog: BTreeMap::new(),
            tool_adapter: None,
            research: None,
            max_tool_rounds: DEFAULT_MAX_TOOL_ROUNDS,
        }
    }

    /// Attach definitions without execution support. Kept for transport tests;
    /// production callers should install [`Self::with_tool_adapter`].
    pub fn with_tool_catalog(
        mut self,
        tool_catalog: BTreeMap<String, Vec<ToolDefinition>>,
    ) -> Self {
        self.tool_catalog = tool_catalog;
        self
    }

    pub fn with_tool_adapter(mut self, adapter: Arc<dyn ToolAdapter>) -> Self {
        self.tool_catalog = adapter.catalog();
        self.tool_adapter = Some(adapter);
        self
    }

    pub fn with_research_provider(mut self, provider: Arc<dyn ResearchContextProvider>) -> Self {
        self.research = Some(provider);
        self
    }

    pub fn with_max_tool_rounds(mut self, max_tool_rounds: u32) -> Self {
        self.max_tool_rounds = max_tool_rounds.clamp(1, 32);
        self
    }
}

/// Compatibility name for existing oMLX-only hosts. New hosts should prefer
/// [`AiTaskExecutor`] and [`AiTaskExecutor::with_provider`].
pub type OmlxTaskExecutor = AiTaskExecutor;

/// Dedicated provenance-bearing executor for conversation naming. Keeping
/// this as a separate durable task prevents title generation from delaying or
/// masquerading as an assistant response.
pub struct AiTitleTaskExecutor {
    ai: Arc<AiStore>,
    provider: Arc<dyn InferenceProvider>,
}

impl AiTitleTaskExecutor {
    pub fn new(ai: Arc<AiStore>, omlx: OmlxClient) -> Self {
        Self::with_provider(ai, Arc::new(omlx))
    }

    pub fn with_provider(ai: Arc<AiStore>, provider: Arc<dyn InferenceProvider>) -> Self {
        Self { ai, provider }
    }
}

#[async_trait]
impl TaskExecutor for AiTaskExecutor {
    fn task_kind(&self) -> &str {
        INFERENCE_TASK_KIND
    }

    async fn execute(
        &self,
        task: &Item,
        _store: &dyn TaskStoreApi,
    ) -> Result<ExecutionOutcome, TaskError> {
        if self.ai.has_completed_run(task.id).map_err(permanent)? {
            return Ok(ExecutionOutcome::Complete);
        }
        let mut prepared = self
            .ai
            .prepare_request(task.id, self.blobs.as_ref(), &self.tool_catalog)
            .map_err(permanent)?;

        let research_context = if prepared.request.tool_policy.allows("web") {
            if let Some(provider) = &self.research {
                let query = latest_user_text(&prepared.request.messages);
                let context = provider.gather(&query).await.map_err(classify_transport)?;
                if research_context_was_used(&context) {
                    self.ai
                        .attach_research_context(&mut prepared, self.blobs.as_ref(), &context)
                        .map_err(permanent)?;
                    Some((query, context))
                } else {
                    None
                }
            } else {
                None
            }
        } else {
            None
        };

        let run_id = self
            .ai
            .record_run_start(
                task.id,
                &prepared,
                self.provider.provider_id(),
                self.provider.endpoint_id(),
            )
            .map_err(permanent)?;
        if let Some((query, context)) = research_context {
            let mut result = BTreeMap::new();
            result.insert(
                "sources".into(),
                CoreValue::Array(
                    context
                        .sources
                        .iter()
                        .map(|source| CoreValue::String(source.url.clone()))
                        .collect(),
                ),
            );
            let error = if context.sources.is_empty() && !context.errors.is_empty() {
                Some(context.errors.join("; "))
            } else {
                None
            };
            self.ai
                .record_tool_invocation(
                    run_id,
                    task.id,
                    ToolInvocationRecord {
                        tool: "web.research-context".into(),
                        provider: "bounded-web".into(),
                        arguments: BTreeMap::from([("query".into(), CoreValue::String(query))]),
                        result: Some(result),
                        result_summary: Some(format!(
                            "{} source(s), {} retrieval warning(s)",
                            context.sources.len(),
                            context.errors.len()
                        )),
                        error,
                        duration_ms: None,
                    },
                )
                .map_err(permanent)?;
        }

        let started = Instant::now();
        let mut request = prepared.request.clone();
        let mut completion = CompletionRecord::default();
        let mut completed = false;
        let previews_allowed = request.tools.is_empty();
        let mut preview_published = false;

        // Allow the configured number of tool-using turns, then make one
        // tools-disabled request so the model must synthesize a user-facing
        // answer from the evidence it has already collected.
        for round in 0..=self.max_tool_rounds {
            let mut stream = match self.provider.stream(request.clone()).await {
                Ok(stream) => stream,
                Err(error) => {
                    let _ = self.ai.record_run_failure(run_id, &error.to_string());
                    return Err(classify_transport(error));
                }
            };
            let mut round_content = String::new();
            let mut round_reasoning = String::new();
            let mut calls = ToolCallAccumulator::default();
            while let Some(event) = stream.next().await {
                let event = match event {
                    Ok(event) => event,
                    Err(error) => {
                        let _ = self.ai.record_run_failure(run_id, &error.to_string());
                        return Err(classify_transport(error));
                    }
                };
                match event {
                    StreamEvent::Token { text } => {
                        round_content.push_str(&text);
                        if previews_allowed && !preview_published {
                            if let Some(preview) = response_preview(&round_content) {
                                self.ai
                                    .record_run_preview(
                                        run_id,
                                        preview.text,
                                        preview.paragraph_complete,
                                    )
                                    .map_err(permanent)?;
                                preview_published = true;
                            }
                        }
                    }
                    StreamEvent::Reasoning { text } => round_reasoning.push_str(&text),
                    StreamEvent::Usage { usage } => completion.usage = Some(usage),
                    StreamEvent::Done { finish_reason } => {
                        if finish_reason.is_some() {
                            completion.finish_reason = finish_reason;
                        }
                    }
                    StreamEvent::ToolCallDelta {
                        index,
                        id,
                        name,
                        arguments,
                    } => calls.push(index, id, name, arguments),
                    StreamEvent::Error { error } => {
                        let _ = self.ai.record_run_failure(run_id, &error);
                        return Err(TaskError::Retryable(error));
                    }
                }
            }
            if !round_reasoning.is_empty() {
                if !completion.reasoning.is_empty() {
                    completion.reasoning.push_str("\n\n");
                }
                completion.reasoning.push_str(&round_reasoning);
            }
            let pending = calls.finish().map_err(permanent)?;
            if pending.is_empty() {
                completion.content = round_content;
                completed = true;
                break;
            }
            if round == self.max_tool_rounds {
                let error = format!(
                    "model requested a tool after the {}-round tool limit",
                    self.max_tool_rounds
                );
                let _ = self.ai.record_run_failure(run_id, &error);
                return Err(TaskError::Permanent(error));
            }
            let Some(adapter) = &self.tool_adapter else {
                let error = "model requested a tool, but no tool execution adapter is installed";
                let _ = self.ai.record_run_failure(run_id, error);
                return Err(TaskError::Permanent(error.into()));
            };

            request.messages.push(ModelMessage {
                role: Role::Assistant,
                content: if round_content.is_empty() {
                    vec![]
                } else {
                    vec![ModelContentPart::Text {
                        text: round_content,
                    }]
                },
                name: None,
                tool_call_id: None,
                tool_calls: pending
                    .iter()
                    .map(|call| ModelToolCall {
                        id: call.id.clone(),
                        name: call.name.clone(),
                        arguments: call.arguments.clone(),
                    })
                    .collect(),
            });

            for call in pending {
                let arguments: Value = serde_json::from_str(&call.arguments).map_err(|error| {
                    permanent(Error::Invalid(format!(
                        "{} returned invalid tool arguments: {error}",
                        call.name
                    )))
                })?;
                let call_started = Instant::now();
                let outcome = adapter.call(&call.name, arguments.clone()).await;
                let duration_ms = Some(
                    call_started
                        .elapsed()
                        .as_millis()
                        .try_into()
                        .unwrap_or(u64::MAX),
                );
                let (tool_content, result, error) = match outcome {
                    Ok(value) => {
                        let content = value.to_string();
                        (content, Some(json_object_to_core(value)), None)
                    }
                    Err(error) => {
                        let message = error.to_string();
                        (json!({ "error": message }).to_string(), None, Some(message))
                    }
                };
                self.ai
                    .record_tool_invocation(
                        run_id,
                        task.id,
                        ToolInvocationRecord {
                            tool: call.name.clone(),
                            provider: adapter.provider_id(&call.name),
                            arguments: json_object_to_core(arguments),
                            result,
                            result_summary: Some(tool_content.chars().take(500).collect()),
                            error,
                            duration_ms,
                        },
                    )
                    .map_err(permanent)?;
                request.messages.push(ModelMessage {
                    role: Role::Tool,
                    content: vec![ModelContentPart::Text { text: tool_content }],
                    name: Some(call.name),
                    tool_call_id: Some(call.id),
                    tool_calls: vec![],
                });
            }

            if round + 1 == self.max_tool_rounds {
                request.tools.clear();
                request.messages.push(ModelMessage::text(
                    Role::System,
                    "The tool-use limit has been reached. Answer the user now using the evidence \
                     already collected. Do not request more tools. Clearly state any remaining \
                     uncertainty.",
                ));
            }
        }

        if !completed {
            let error = "model did not produce a terminal response";
            let _ = self.ai.record_run_failure(run_id, error);
            return Err(TaskError::Permanent(error.into()));
        }
        completion.duration_ms = Some(started.elapsed().as_millis().try_into().unwrap_or(u64::MAX));
        self.ai
            .record_completion(&prepared, run_id, completion)
            .map_err(permanent)?;
        // The response is already durable and visible. Naming is a distinct
        // task so it can run next without holding up this result.
        let _ = self
            .ai
            .queue_title_suggestion_if_placeholder(prepared.conversation_id);
        Ok(ExecutionOutcome::Complete)
    }

    fn max_retries(&self) -> u32 {
        2
    }
}

#[async_trait]
impl TaskExecutor for AiTitleTaskExecutor {
    fn task_kind(&self) -> &str {
        TITLE_SUGGESTION_TASK_KIND
    }

    async fn execute(
        &self,
        task: &Item,
        _store: &dyn TaskStoreApi,
    ) -> Result<ExecutionOutcome, TaskError> {
        if self.ai.has_completed_run(task.id).map_err(permanent)? {
            return Ok(ExecutionOutcome::Complete);
        }
        let prepared = self.ai.prepare_title_request(task.id).map_err(permanent)?;
        let run_id = self
            .ai
            .record_run_start(
                task.id,
                &prepared,
                self.provider.provider_id(),
                self.provider.endpoint_id(),
            )
            .map_err(permanent)?;
        let started = Instant::now();
        let mut stream = match self.provider.stream(prepared.request.clone()).await {
            Ok(stream) => stream,
            Err(error) => {
                let _ = self.ai.record_run_failure(run_id, &error.to_string());
                return Err(classify_transport(error));
            }
        };
        let mut completion = CompletionRecord::default();
        while let Some(event) = stream.next().await {
            let event = match event {
                Ok(event) => event,
                Err(error) => {
                    let _ = self.ai.record_run_failure(run_id, &error.to_string());
                    return Err(classify_transport(error));
                }
            };
            match event {
                StreamEvent::Token { text } => completion.content.push_str(&text),
                StreamEvent::Reasoning { text } => completion.reasoning.push_str(&text),
                StreamEvent::Usage { usage } => completion.usage = Some(usage),
                StreamEvent::Done { finish_reason } => completion.finish_reason = finish_reason,
                StreamEvent::Error { error } => {
                    let _ = self.ai.record_run_failure(run_id, &error);
                    return Err(TaskError::Retryable(error));
                }
                StreamEvent::ToolCallDelta { .. } => {
                    let error = "title model unexpectedly requested a tool";
                    let _ = self.ai.record_run_failure(run_id, error);
                    return Err(TaskError::Permanent(error.into()));
                }
            }
        }
        let title = suggested_title(&completion.content).map_err(|error| {
            let _ = self.ai.record_run_failure(run_id, &error.to_string());
            permanent(error)
        })?;
        completion.duration_ms = Some(started.elapsed().as_millis().try_into().unwrap_or(u64::MAX));
        self.ai
            .record_title_completion(task.id, &prepared, run_id, title, completion)
            .map_err(permanent)?;
        Ok(ExecutionOutcome::Complete)
    }

    fn max_retries(&self) -> u32 {
        2
    }
}

fn latest_user_text(messages: &[ModelMessage]) -> String {
    messages
        .iter()
        .rfind(|message| message.role == Role::User)
        .map(|message| {
            message
                .content
                .iter()
                .filter_map(|part| match part {
                    ModelContentPart::Text { text } => Some(text.as_str()),
                    _ => None,
                })
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

fn research_context_was_used(context: &crate::ResearchContext) -> bool {
    !context.sources.is_empty() || !context.errors.is_empty()
}

fn suggested_title(content: &str) -> crate::Result<String> {
    let first_line = content
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default();
    let without_label = first_line
        .strip_prefix("Title:")
        .or_else(|| first_line.strip_prefix("title:"))
        .unwrap_or(first_line);
    let title = without_label
        .trim()
        .trim_matches(|character| matches!(character, '"' | '\'' | '`' | '*' | '#' | ' '))
        .trim_end_matches(['.', '!', '?', ':', ';'])
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if title.is_empty() {
        return Err(Error::Invalid(
            "the model returned an empty conversation title".into(),
        ));
    }
    Ok(title.chars().take(120).collect())
}

fn json_object_to_core(value: Value) -> BTreeMap<String, CoreValue> {
    match value {
        Value::Object(values) => values
            .into_iter()
            .map(|(key, value)| (key, json_to_core(value)))
            .collect(),
        other => BTreeMap::from([("value".into(), json_to_core(other))]),
    }
}

fn json_to_core(value: Value) -> CoreValue {
    match value {
        Value::Null => CoreValue::Null,
        Value::Bool(value) => CoreValue::Bool(value),
        Value::Number(value) => value
            .as_i64()
            .map(CoreValue::Int)
            .or_else(|| value.as_f64().map(CoreValue::Float))
            .unwrap_or(CoreValue::Null),
        Value::String(value) => CoreValue::String(value),
        Value::Array(values) => CoreValue::Array(values.into_iter().map(json_to_core).collect()),
        Value::Object(values) => CoreValue::Object(
            values
                .into_iter()
                .map(|(key, value)| (key, json_to_core(value)))
                .collect(),
        ),
    }
}

#[derive(Debug, PartialEq, Eq)]
struct ResponsePreview<'a> {
    text: &'a str,
    paragraph_complete: bool,
}

/// Select the earliest coherent block worth publishing. Paragraph boundaries
/// win; a complete sentence provides a bounded fallback for models that emit
/// one very long paragraph. Incomplete TeX and code fences are never exposed.
fn response_preview(content: &str) -> Option<ResponsePreview<'_>> {
    for (boundary, _) in content.match_indices("\n\n") {
        let candidate = content[..boundary].trim_end();
        if has_substantive_final_block(candidate) && preview_is_balanced(candidate) {
            return Some(ResponsePreview {
                text: candidate,
                paragraph_complete: true,
            });
        }
    }

    if content.chars().count() < 240 {
        return None;
    }
    for (index, character) in content.char_indices() {
        if index < 120 || !matches!(character, '.' | '!' | '?') {
            continue;
        }
        let end = index + character.len_utf8();
        if content[end..]
            .chars()
            .next()
            .is_some_and(char::is_whitespace)
        {
            let candidate = content[..end].trim_end();
            if has_substantive_final_block(candidate) && preview_is_balanced(candidate) {
                return Some(ResponsePreview {
                    text: candidate,
                    paragraph_complete: false,
                });
            }
        }
    }

    if content.chars().count() < 480 {
        return None;
    }
    let end = content
        .char_indices()
        .take_while(|(index, _)| *index <= 480)
        .filter_map(|(index, character)| character.is_whitespace().then_some(index))
        .last()?;
    let candidate = content[..end].trim_end();
    (has_substantive_final_block(candidate) && preview_is_balanced(candidate)).then_some(
        ResponsePreview {
            text: candidate,
            paragraph_complete: false,
        },
    )
}

fn has_substantive_final_block(candidate: &str) -> bool {
    let block = candidate.rsplit("\n\n").next().unwrap_or(candidate).trim();
    !block.is_empty()
        && !block
            .lines()
            .filter(|line| !line.trim().is_empty())
            .all(|line| line.trim_start().starts_with('#'))
}

fn preview_is_balanced(candidate: &str) -> bool {
    if !candidate.match_indices("```").count().is_multiple_of(2) {
        return false;
    }
    let mut dollars = 0_u32;
    let mut escaped = false;
    for character in candidate.chars() {
        if character == '$' && !escaped {
            dollars += 1;
        }
        escaped = character == '\\' && !escaped;
        if character != '\\' {
            escaped = false;
        }
    }
    dollars.is_multiple_of(2)
        && candidate.matches("\\(").count() == candidate.matches("\\)").count()
        && candidate.matches("\\[").count() == candidate.matches("\\]").count()
}

fn permanent(error: Error) -> TaskError {
    TaskError::Permanent(error.to_string())
}

fn classify_transport(error: Error) -> TaskError {
    match error {
        Error::Omlx(_) | Error::Http(_) | Error::Io(_) | Error::Web(_) => {
            TaskError::Retryable(error.to_string())
        }
        other => TaskError::Permanent(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::Mutex;

    use crate::{
        ConversationDraft, EventStream, FileBlobStore, InferenceProvider, MessageDraft,
        ModelSummary, Result as AiResult, ToolPolicy,
    };
    use impress_core::item::ActorKind;
    use impress_core::store::ItemStore;
    use tokio::sync::mpsc;
    use tokio_stream::wrappers::ReceiverStream;

    struct ScriptedProvider {
        rounds: Mutex<VecDeque<Vec<StreamEvent>>>,
        requests: Mutex<Vec<crate::ChatRequest>>,
    }

    #[async_trait]
    impl InferenceProvider for ScriptedProvider {
        fn provider_id(&self) -> &str {
            "scripted"
        }

        fn endpoint_id(&self) -> &str {
            "executor-test"
        }

        async fn models(&self) -> AiResult<Vec<ModelSummary>> {
            Ok(vec![])
        }

        async fn stream(&self, request: crate::ChatRequest) -> AiResult<EventStream> {
            self.requests.lock().unwrap().push(request);
            let events = self.rounds.lock().unwrap().pop_front().unwrap();
            let (sender, receiver) = mpsc::channel(events.len().max(1));
            for event in events {
                sender.try_send(Ok(event)).unwrap();
            }
            drop(sender);
            Ok(ReceiverStream::new(receiver))
        }
    }

    struct ScriptedTools;

    #[async_trait]
    impl ToolAdapter for ScriptedTools {
        fn catalog(&self) -> BTreeMap<String, Vec<ToolDefinition>> {
            BTreeMap::from([(
                "scix".into(),
                vec![ToolDefinition {
                    name: "scix".into(),
                    description: "Search the literature".into(),
                    input_schema: json!({ "type": "object" }),
                }],
            )])
        }

        fn provider_id(&self, _tool_name: &str) -> String {
            "scripted-tools".into()
        }

        async fn call(&self, tool_name: &str, arguments: Value) -> AiResult<Value> {
            assert_eq!(tool_name, "scix");
            assert_eq!(arguments["query"], "stars");
            Ok(json!({ "papers": 3 }))
        }
    }

    #[test]
    fn registers_under_the_dispatchable_task_kind() {
        let directory = tempfile::tempdir().unwrap();
        let ai = Arc::new(
            AiStore::open(
                &directory.path().join("impress.sqlite"),
                "test",
                ActorKind::Agent,
            )
            .unwrap(),
        );
        let blobs = Arc::new(FileBlobStore::open(directory.path().join("blobs")).unwrap());
        let executor = OmlxTaskExecutor::new(
            ai,
            OmlxClient::new("http://127.0.0.1:8000", None).unwrap(),
            blobs,
        );
        assert_eq!(executor.task_kind(), INFERENCE_TASK_KIND);
        assert_eq!(executor.max_retries(), 2);
    }

    #[test]
    fn extracts_only_text_from_the_latest_user_turn() {
        let messages = vec![
            ModelMessage::text(Role::User, "old"),
            ModelMessage::text(Role::Assistant, "answer"),
            ModelMessage::text(Role::User, "new"),
        ];
        assert_eq!(latest_user_text(&messages), "new");
    }

    #[test]
    fn empty_research_policy_check_is_not_a_tool_use() {
        assert!(!research_context_was_used(
            &crate::ResearchContext::default()
        ));
        assert!(research_context_was_used(&crate::ResearchContext {
            sources: vec![],
            errors: vec!["search failed".into()],
        }));
    }

    #[test]
    fn cleans_common_model_title_wrappers() {
        assert_eq!(
            suggested_title("Title: **Galaxy Rotation Curves.**\nMore text").unwrap(),
            "Galaxy Rotation Curves"
        );
        assert!(suggested_title(" \n ").is_err());
    }

    #[test]
    fn preview_waits_for_prose_after_a_heading() {
        let text = "# Result\n\nThe first useful paragraph has arrived.\n\nMore follows.";
        assert_eq!(
            response_preview(text),
            Some(ResponsePreview {
                text: "# Result\n\nThe first useful paragraph has arrived.",
                paragraph_complete: true,
            })
        );
    }

    #[test]
    fn preview_uses_a_unicode_safe_sentence_fallback() {
        let sentence = format!(
            "{} This is a complete result sentence. trailing generation",
            "αβγδ ".repeat(40)
        );
        let preview = response_preview(&sentence).unwrap();
        assert!(preview.text.ends_with("sentence."));
        assert!(!preview.paragraph_complete);
        assert!(std::str::from_utf8(preview.text.as_bytes()).is_ok());
    }

    #[test]
    fn preview_never_exposes_unfinished_math_or_code() {
        let math = format!("{} The value is $x + y.\n\n", "context ".repeat(35));
        assert_eq!(response_preview(&math), None);
        let code = format!("{}\n```rust\nlet x = 1;\n\n", "context ".repeat(35));
        assert_eq!(response_preview(&code), None);
    }

    #[tokio::test]
    async fn provider_neutral_tool_loop_records_complete_lineage() {
        let directory = tempfile::tempdir().unwrap();
        let ai = Arc::new(
            AiStore::open(
                &directory.path().join("impress.sqlite"),
                "test:executor",
                ActorKind::Agent,
            )
            .unwrap(),
        );
        let blobs = Arc::new(FileBlobStore::open(directory.path().join("blobs")).unwrap());
        let conversation = ai
            .create_conversation(ConversationDraft {
                model: "scripted-model".into(),
                tool_policy: ToolPolicy {
                    enabled: vec!["scix".into()],
                },
                ..Default::default()
            })
            .unwrap();
        let queued = ai
            .queue_user_turn(conversation, MessageDraft::user("Find papers"))
            .unwrap();
        let provider = Arc::new(ScriptedProvider {
            rounds: Mutex::new(VecDeque::from([
                vec![
                    StreamEvent::ToolCallDelta {
                        index: 0,
                        id: Some("call-1".into()),
                        name: Some("scix".into()),
                        arguments: r#"{"query":"stars"}"#.into(),
                    },
                    StreamEvent::Done {
                        finish_reason: Some("tool_calls".into()),
                    },
                ],
                vec![
                    StreamEvent::Token {
                        text: "Three papers are relevant.".into(),
                    },
                    StreamEvent::Done {
                        finish_reason: Some("stop".into()),
                    },
                ],
            ])),
            requests: Mutex::new(vec![]),
        });
        let executor = AiTaskExecutor::with_provider(ai.clone(), provider.clone(), blobs)
            .with_tool_adapter(Arc::new(ScriptedTools));
        let task = ai.shared_store().get(queued.task_id).unwrap().unwrap();

        assert_eq!(
            executor
                .execute(&task, ai.shared_store().as_ref())
                .await
                .unwrap(),
            ExecutionOutcome::Complete
        );
        let requests = provider.requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        assert!(requests[1]
            .messages
            .iter()
            .any(|message| message.role == Role::Tool));
        drop(requests);

        let provenance = ai.task_provenance(queued.task_id).unwrap().unwrap();
        assert_eq!(
            provenance.run.payload["provider"],
            CoreValue::String("scripted".into())
        );
        assert_eq!(
            provenance.run.payload["endpoint"],
            CoreValue::String("executor-test".into())
        );
        assert_eq!(provenance.tool_invocations.len(), 1);
        assert_eq!(provenance.outputs.len(), 1);
    }

    #[tokio::test]
    async fn tool_limit_forces_a_final_tools_disabled_response() {
        let directory = tempfile::tempdir().unwrap();
        let ai = Arc::new(
            AiStore::open(
                &directory.path().join("impress.sqlite"),
                "test:tool-limit",
                ActorKind::Agent,
            )
            .unwrap(),
        );
        let blobs = Arc::new(FileBlobStore::open(directory.path().join("blobs")).unwrap());
        let conversation = ai
            .create_conversation(ConversationDraft {
                model: "scripted-model".into(),
                tool_policy: ToolPolicy {
                    enabled: vec!["scix".into()],
                },
                ..Default::default()
            })
            .unwrap();
        let queued = ai
            .queue_user_turn(conversation, MessageDraft::user("Find papers"))
            .unwrap();
        let provider = Arc::new(ScriptedProvider {
            rounds: Mutex::new(VecDeque::from([
                vec![
                    StreamEvent::ToolCallDelta {
                        index: 0,
                        id: Some("call-1".into()),
                        name: Some("scix".into()),
                        arguments: r#"{"query":"stars"}"#.into(),
                    },
                    StreamEvent::Done {
                        finish_reason: Some("tool_calls".into()),
                    },
                ],
                vec![
                    StreamEvent::Token {
                        text: "Three papers are relevant.".into(),
                    },
                    StreamEvent::Done {
                        finish_reason: Some("stop".into()),
                    },
                ],
            ])),
            requests: Mutex::new(vec![]),
        });
        let executor = AiTaskExecutor::with_provider(ai.clone(), provider.clone(), blobs)
            .with_tool_adapter(Arc::new(ScriptedTools))
            .with_max_tool_rounds(1);
        let task = ai.shared_store().get(queued.task_id).unwrap().unwrap();

        assert_eq!(
            executor
                .execute(&task, ai.shared_store().as_ref())
                .await
                .unwrap(),
            ExecutionOutcome::Complete
        );
        let requests = provider.requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        assert!(requests[1].tools.is_empty());
        assert!(requests[1].messages.iter().any(|message| {
            message.role == Role::System
                && message.content.iter().any(|part| {
                    matches!(part, ModelContentPart::Text { text } if text.contains("Answer the user now"))
                })
        }));
    }

    #[tokio::test]
    async fn title_executor_uses_local_model_and_updates_only_the_title() {
        let directory = tempfile::tempdir().unwrap();
        let ai = Arc::new(
            AiStore::open(
                &directory.path().join("impress.sqlite"),
                "test:titles",
                ActorKind::Agent,
            )
            .unwrap(),
        );
        let conversation = ai
            .create_conversation(ConversationDraft {
                model: "scripted-model".into(),
                ..Default::default()
            })
            .unwrap();
        ai.append_message(
            conversation,
            MessageDraft::user("Explain the origin of galaxy rotation curves"),
        )
        .unwrap();
        let task_id = ai.queue_title_suggestion(conversation).unwrap();
        let provider = Arc::new(ScriptedProvider {
            rounds: Mutex::new(VecDeque::from([vec![
                StreamEvent::Token {
                    text: "Title: Galaxy Rotation Curve Origins".into(),
                },
                StreamEvent::Done {
                    finish_reason: Some("stop".into()),
                },
            ]])),
            requests: Mutex::new(vec![]),
        });
        let executor = AiTitleTaskExecutor::with_provider(ai.clone(), provider.clone());
        let task = ai.shared_store().get(task_id).unwrap().unwrap();

        assert_eq!(
            executor
                .execute(&task, ai.shared_store().as_ref())
                .await
                .unwrap(),
            ExecutionOutcome::Complete
        );
        let view = ai.conversation_view(conversation).unwrap();
        assert_eq!(view.conversation.title, "Galaxy Rotation Curve Origins");
        assert_eq!(
            view.messages.len(),
            1,
            "title generation is not a chat turn"
        );
        assert!(ai.has_completed_run(task_id).unwrap());
        let requests = provider.requests.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].model, "scripted-model");
        assert!(requests[0].tools.is_empty());
        assert!(!requests[0].thinking);
    }
}
