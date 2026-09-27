//! `HistoryService` — the self-reflective layer's read (and controlled
//! write) side over the call log (L2, plan-self-reflective-layer § Call
//! log).
//!
//! L1 (`impress-core::call_context`, this crate's [`crate::audit`]) writes
//! one `core/verb-call@1.0.0` row per non-read-only call, whose id is the
//! `batch_id` every operation the call wrote carries. This service is the
//! agent- and human-facing surface over that join:
//!
//! * [`HistoryService::calls`] — a filtered page of the log ("what
//!   happened").
//! * [`HistoryService::why`] — every operation on an item, each joined to
//!   the call that wrote it ("why did this change").
//! * [`HistoryService::trace`] — every call sharing a trace id, as a tree
//!   built from `parent_call`.
//! * [`HistoryService::replay`] — re-runs recorded calls through the
//!   pipeline, refusing any whose arguments were not recorded in full
//!   (`not-replayable`, never guessed at).
//! * [`HistoryService::save_macro`] — turns a list of call ids into a
//!   stored, reviewable `impress/workflow@1.0.0` document (§ Workflows'
//!   `manual` trigger; W1 builds the runtime that executes one, this only
//!   writes the document, `state: "proposed"`).
//! * [`HistoryService::health`] — the audit sink's backlog, plus the log's
//!   own row count and oldest row.
//!
//! No domain logic beyond the join and the privacy-recorded-in-full check;
//! like every other service in this crate it converts arguments, reads the
//! store, and turns errors into `ok: false` plus a message.

use std::collections::BTreeMap;
use std::sync::Arc;

use chrono::{SecondsFormat, Utc};
use impress_core::item::{ActorKind, Item, ItemId, Priority, Value as ItemValue, Visibility};
use impress_core::query::{ItemQuery, Predicate, SortDescriptor};
use impress_core::schemas::VERB_CALL_SCHEMA;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_service_core::async_trait;
use impress_service_core::pipeline::{self, Call};
use impress_service_core::refusal::codes;
use impress_service_core::VerbDescriptor;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

use crate::store::store_instance;

/// The canonical spelling of a saved macro's kind — one new record kind,
/// pre-approved (D-R1) and named for this exact use by the plan's §
/// Workflows: `history-service_save-macro` "writes an `impress/workflow@1.0.0`
/// with `trigger: manual` whose steps are the calls". W1 builds the crate
/// that validates, plans and *runs* a workflow document; until then this is a
/// `state: "proposed"` document nothing executes — a record, not a runtime.
pub const WORKFLOW_SCHEMA: &str = "impress/workflow@1.0.0";

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

/// One call, as the history verbs report it.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CallSummary {
    /// The call id — the row's own id and every op's `batch_id`.
    pub call_id: String,
    pub verb: String,
    pub since: String,
    /// `{"kind": "agent"|"human"|"system"|"app"|"provider", "name": "…"?}`.
    pub caller: Value,
    pub trace_id: String,
    pub parent_call: Option<String>,
    /// The surface this call came from, when the call context carried one.
    pub surface: Option<String>,
    pub args: Value,
    pub ok: bool,
    pub code: Option<String>,
    pub message_len: u64,
    /// RFC 3339.
    pub started_at: String,
    pub duration_ms: u64,
    /// True once CL-6 compaction has reduced this row's `args`.
    pub compacted: bool,
}

/// One operation on an item, joined to the call that wrote it.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct WhyEntry {
    /// The operation row's id.
    pub operation_id: String,
    /// RFC 3339, the operation's own timestamp.
    pub applied_at: String,
    /// The join key — every op's `batch_id`.
    pub batch_id: String,
    /// The call that wrote this operation, when its row still exists. `None`
    /// only for a call the audit sink dropped (never silent — see
    /// [`HistoryService::health`]).
    pub call: Option<CallSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct WhyResult {
    pub ok: bool,
    pub id: String,
    pub message: String,
    /// Newest first.
    pub entries: Vec<WhyEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CallsResult {
    pub ok: bool,
    pub message: String,
    /// Newest first.
    pub calls: Vec<CallSummary>,
}

/// One trace, as a tree: every call under it, nested by `parent_call`.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct TraceNode {
    pub call: CallSummary,
    pub children: Vec<TraceNode>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct TraceResult {
    pub ok: bool,
    pub trace_id: String,
    pub message: String,
    /// The calls under this trace with no parent inside it.
    pub roots: Vec<TraceNode>,
}

/// What `replay` did (or would do) with one recorded call.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ReplayOutcome {
    pub call_id: String,
    pub verb: Option<String>,
    pub ok: bool,
    pub code: Option<String>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ReplayResult {
    pub ok: bool,
    pub dry_run: bool,
    pub message: String,
    pub results: Vec<ReplayOutcome>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SaveMacroResult {
    pub ok: bool,
    /// The new `impress/workflow@1.0.0` document's id.
    pub id: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct HistoryHealth {
    pub ok: bool,
    pub message: String,
    /// Rows the audit sink's writer thread has written.
    pub written: u64,
    /// Rows dropped for a full channel.
    pub dropped: u64,
    /// Rows the store refused.
    pub failed: u64,
    /// Calls that found no sink installed at all.
    pub no_sink: u64,
    pub channel_capacity: u64,
    /// `core/verb-call@1.0.0` rows currently in the store.
    pub rows: usize,
    /// The oldest row's `started_at`, when there is one.
    pub oldest: Option<String>,
}

// ---------------------------------------------------------------------------
// Service trait
// ---------------------------------------------------------------------------

/// The self-reflective layer's history verbs: what happened, why an item
/// changed, every call under a trace, replaying a recorded call, and saving
/// a list of calls as a reviewable macro.
#[impress_service]
pub trait HistoryService: Send + Sync + 'static {
    /// A filtered page of the call log — "what happened". Every filter is
    /// optional; `limit` of 0 means the default (50), clamped above 500.
    #[impress_method]
    #[impress_example(name = "default", args = r#"{"limit": 5}"#)]
    async fn calls(
        &self,
        since: Option<String>,
        until: Option<String>,
        verb: Option<String>,
        caller: Option<String>,
        trace_id: Option<String>,
        limit: i64,
    ) -> CallsResult;

    /// Why an item is the way it is: every operation that wrote it, newest
    /// first, each joined to the call that wrote it (its caller, the time,
    /// the requested verb, and the surface it came from when the call
    /// context carried one).
    #[impress_method]
    #[impress_example(
        name = "default",
        args = r#"{"id": "00000000-0000-0000-0000-000000000000"}"#
    )]
    async fn why(&self, id: String) -> WhyResult;

    /// Every call, as a tree built from `parent_call`, for one trace id —
    /// a surface click, the verb it ran, and any verb that ran nested
    /// inside it.
    #[impress_method]
    #[impress_example(name = "default", args = r#"{"trace_id": "t"}"#)]
    async fn trace(&self, trace_id: String) -> TraceResult;

    /// Re-invoke recorded calls through the pipeline, as
    /// `Agent("replay:<original caller>")`. Only a call whose arguments were
    /// recorded in full (never privacy-reduced, never compacted) can be
    /// replayed; every other one is refused `not-replayable`, by name,
    /// without running anything. `dry_run` lists what would run instead of
    /// running it.
    #[impress_method(
        safety = mutating,
        effects(
            reads = ["core/verb-call@1.0.0"],
            writes = [any("re-invokes an arbitrary recorded verb, whose own writes are its own")]
        )
    )]
    #[impress_example(
        name = "default",
        args = r#"{"call_ids": ["00000000-0000-0000-0000-000000000000"], "dry_run": true}"#
    )]
    async fn replay(&self, call_ids: Vec<String>, dry_run: bool) -> ReplayResult;

    /// Turn a list of recorded call ids into a stored, reviewable
    /// `impress/workflow@1.0.0` document (`trigger: manual`, `state:
    /// "proposed"`) — a macro a person can review and enable once W1's
    /// runtime exists to run it.
    #[impress_method(
        safety = mutating,
        effects(reads = ["core/verb-call@1.0.0"], writes = ["impress/workflow@1.0.0"])
    )]
    #[impress_example(
        name = "default",
        args = r#"{"call_ids": ["00000000-0000-0000-0000-000000000000"], "name": "my-macro"}"#
    )]
    async fn save_macro(&self, call_ids: Vec<String>, name: String) -> SaveMacroResult;

    /// The call log's own backlog: the audit sink's `written`/`dropped`/
    /// `failed`/`no_sink` counters and channel bound, plus how many
    /// `core/verb-call@1.0.0` rows exist and the oldest one's timestamp.
    #[impress_method]
    #[impress_example(name = "default", args = r#"{}"#)]
    async fn health(&self) -> HistoryHealth;
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

/// Store-backed `HistoryService`.
#[derive(Clone, Default)]
pub struct DefaultHistoryService {
    store: Option<Arc<SqliteItemStore>>,
}

impl DefaultHistoryService {
    pub fn new() -> Self {
        Self { store: None }
    }

    pub fn with_store(store: Arc<SqliteItemStore>) -> Self {
        Self { store: Some(store) }
    }

    fn store(&self) -> Arc<SqliteItemStore> {
        self.store.clone().unwrap_or_else(store_instance)
    }
}

fn payload_json(item: &Item) -> Value {
    serde_json::to_value(&item.payload).unwrap_or(Value::Object(Default::default()))
}

/// Whether a JSON value carries any of the audit layer's reduced shapes
/// (`summarize_field`/`hashed` in `impress_service_core::pipeline::audit`):
/// `{"len", "sha256_8"}`, `{"len", "first"}` or `{"len", "keys"}`, at any
/// depth. A value that never carries one was never privacy-reduced.
fn is_reduced(value: &Value) -> bool {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<&str> = map.keys().map(String::as_str).collect();
            keys.sort_unstable();
            let shape = |wanted: &[&str]| {
                let mut wanted = wanted.to_vec();
                wanted.sort_unstable();
                keys == wanted
            };
            if shape(&["len", "sha256_8"]) || shape(&["len", "first"]) || shape(&["len", "keys"]) {
                return true;
            }
            map.values().any(is_reduced)
        }
        Value::Array(items) => items.iter().any(is_reduced),
        _ => false,
    }
}

/// Whether the recorded call's arguments are still the full, original
/// arguments: not compacted (CL-6) and never reduced by the privacy filter.
/// Small scalars and id fields pass the filter unchanged (§ Call log's
/// table), so this is exact for them; a verb whose args carry only such
/// fields is always replayable, and one that carries a long string, a body
/// or an object never is.
fn args_are_full(payload: &Value) -> bool {
    if payload.get("compacted").and_then(Value::as_bool) == Some(true) {
        return false;
    }
    match payload.get("args") {
        Some(args) => !is_reduced(args),
        None => false,
    }
}

fn call_summary(item: &Item) -> CallSummary {
    let p = payload_json(item);
    CallSummary {
        call_id: item.id.to_string(),
        verb: p
            .get("verb")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        since: p
            .get("since")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        caller: p.get("caller").cloned().unwrap_or(Value::Null),
        trace_id: p
            .get("trace_id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        parent_call: p
            .get("parent_call")
            .and_then(Value::as_str)
            .map(str::to_string),
        surface: p.get("surface").and_then(Value::as_str).map(str::to_string),
        args: p.get("args").cloned().unwrap_or(Value::Null),
        ok: p.get("ok").and_then(Value::as_bool).unwrap_or(true),
        code: p.get("code").and_then(Value::as_str).map(str::to_string),
        message_len: p.get("message_len").and_then(Value::as_u64).unwrap_or(0),
        started_at: p
            .get("started_at")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        duration_ms: p.get("duration_ms").and_then(Value::as_u64).unwrap_or(0),
        compacted: p.get("compacted").and_then(Value::as_bool).unwrap_or(false),
    }
}

fn call_row(store: &SqliteItemStore, call_id: &str) -> Option<Item> {
    let uuid = uuid::Uuid::parse_str(call_id).ok()?;
    store.get(uuid).ok().flatten()
}

fn error_calls(message: String) -> CallsResult {
    CallsResult {
        ok: false,
        message,
        calls: vec![],
    }
}

#[async_trait::async_trait]
impl HistoryService for DefaultHistoryService {
    async fn calls(
        &self,
        since: Option<String>,
        until: Option<String>,
        verb: Option<String>,
        caller: Option<String>,
        trace_id: Option<String>,
        limit: i64,
    ) -> CallsResult {
        let store = self.store();
        let query = ItemQuery {
            schema: Some(VERB_CALL_SCHEMA.into()),
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            ..Default::default()
        };
        let items = match store.query(&query) {
            Ok(items) => items,
            Err(e) => return error_calls(e.to_string()),
        };
        let cap = if limit <= 0 {
            50usize
        } else {
            (limit as usize).min(500)
        };
        let mut summaries: Vec<CallSummary> = items.iter().map(call_summary).collect();
        summaries.retain(|c| {
            since.as_deref().is_none_or(|s| c.started_at.as_str() >= s)
                && until.as_deref().is_none_or(|u| c.started_at.as_str() <= u)
                && verb.as_deref().is_none_or(|v| c.verb == v)
                && trace_id.as_deref().is_none_or(|t| c.trace_id == t)
                && caller.as_deref().is_none_or(|want| {
                    c.caller
                        .get("name")
                        .and_then(Value::as_str)
                        .is_some_and(|name| name == want)
                        || c.caller.get("kind").and_then(Value::as_str) == Some(want)
                })
        });
        summaries.truncate(cap);
        CallsResult {
            ok: true,
            message: format!("{} call(s).", summaries.len()),
            calls: summaries,
        }
    }

    async fn why(&self, id: String) -> WhyResult {
        let target: ItemId = match id.parse() {
            Ok(uuid) => uuid,
            Err(e) => {
                return WhyResult {
                    ok: false,
                    id,
                    message: format!("not a UUID: {e}"),
                    entries: vec![],
                }
            }
        };
        let store = self.store();
        let ops = match store.operations_for(target, None) {
            Ok(ops) => ops,
            Err(e) => {
                return WhyResult {
                    ok: false,
                    id,
                    message: e.to_string(),
                    entries: vec![],
                }
            }
        };
        let mut entries: Vec<WhyEntry> = ops
            .iter()
            .filter_map(|op| {
                let batch_id = op.batch_id.clone()?;
                let call = call_row(&store, &batch_id).as_ref().map(call_summary);
                Some(WhyEntry {
                    operation_id: op.id.to_string(),
                    applied_at: op.created.to_rfc3339_opts(SecondsFormat::Millis, true),
                    batch_id,
                    call,
                })
            })
            .collect();
        entries.reverse(); // operations_for is oldest-first; "why" reads newest-first.
        WhyResult {
            ok: true,
            id,
            message: format!("{} operation(s) wrote this item.", entries.len()),
            entries,
        }
    }

    async fn trace(&self, trace_id: String) -> TraceResult {
        let store = self.store();
        let query = ItemQuery {
            schema: Some(VERB_CALL_SCHEMA.into()),
            predicates: vec![Predicate::Eq(
                "trace_id".into(),
                serde_json_to_item_value(&Value::String(trace_id.clone())),
            )],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = match store.query(&query) {
            Ok(items) => items,
            Err(e) => {
                return TraceResult {
                    ok: false,
                    trace_id,
                    message: e.to_string(),
                    roots: vec![],
                }
            }
        };
        let summaries: Vec<CallSummary> = items.iter().map(call_summary).collect();
        let by_id: BTreeMap<String, CallSummary> = summaries
            .iter()
            .map(|c| (c.call_id.clone(), c.clone()))
            .collect();
        let mut children: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for c in &summaries {
            if let Some(parent) = &c.parent_call {
                if by_id.contains_key(parent) {
                    children
                        .entry(parent.clone())
                        .or_default()
                        .push(c.call_id.clone());
                }
            }
        }
        fn build(
            id: &str,
            by_id: &BTreeMap<String, CallSummary>,
            children: &BTreeMap<String, Vec<String>>,
        ) -> TraceNode {
            let call = by_id.get(id).cloned().expect("id came from by_id");
            let kids = children
                .get(id)
                .into_iter()
                .flatten()
                .map(|kid| build(kid, by_id, children))
                .collect();
            TraceNode {
                call,
                children: kids,
            }
        }
        let roots: Vec<TraceNode> = summaries
            .iter()
            .filter(|c| {
                c.parent_call
                    .as_deref()
                    .is_none_or(|p| !by_id.contains_key(p))
            })
            .map(|c| build(&c.call_id, &by_id, &children))
            .collect();
        TraceResult {
            ok: true,
            trace_id,
            message: format!("{} call(s) under this trace.", summaries.len()),
            roots,
        }
    }

    async fn replay(&self, call_ids: Vec<String>, dry_run: bool) -> ReplayResult {
        let store = self.store();
        let mut results = Vec::with_capacity(call_ids.len());
        for call_id in &call_ids {
            let Some(item) = call_row(&store, call_id) else {
                results.push(ReplayOutcome {
                    call_id: call_id.clone(),
                    verb: None,
                    ok: false,
                    code: Some(codes::NOT_FOUND.to_string()),
                    message: format!("no call row for {call_id}"),
                });
                continue;
            };
            let payload = payload_json(&item);
            let verb_name = payload
                .get("verb")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            if !args_are_full(&payload) {
                results.push(ReplayOutcome {
                    call_id: call_id.clone(),
                    verb: Some(verb_name.clone()),
                    ok: false,
                    code: Some(codes::NOT_REPLAYABLE.to_string()),
                    message: format!(
                        "{call_id} ({verb_name}) was not recorded in full — privacy-reduced or compacted — and cannot be replayed"
                    ),
                });
                continue;
            }
            let Some(descriptor) = VerbDescriptor::find(&verb_name) else {
                results.push(ReplayOutcome {
                    call_id: call_id.clone(),
                    verb: Some(verb_name.clone()),
                    ok: false,
                    code: Some(codes::NOT_FOUND.to_string()),
                    message: format!("verb {verb_name} is not linked in this process"),
                });
                continue;
            };
            let args = payload.get("args").cloned().unwrap_or(json!({}));
            if dry_run {
                results.push(ReplayOutcome {
                    call_id: call_id.clone(),
                    verb: Some(verb_name.clone()),
                    ok: true,
                    code: None,
                    message: format!("would call {verb_name} with {args}"),
                });
                continue;
            }
            let original_caller = payload
                .get("caller")
                .and_then(|c| c.get("name"))
                .and_then(Value::as_str)
                .unwrap_or(&item.author);
            let call = Call::agent(format!("replay:{original_caller}"), args);
            match pipeline::invoke_on(store.clone(), descriptor, call).await {
                Ok(answer) => {
                    let ok = answer.get("ok").and_then(Value::as_bool).unwrap_or(true);
                    results.push(ReplayOutcome {
                        call_id: call_id.clone(),
                        verb: Some(verb_name),
                        ok,
                        code: answer
                            .get("code")
                            .and_then(Value::as_str)
                            .map(str::to_string),
                        message: answer
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or("replayed")
                            .to_string(),
                    });
                }
                Err(e) => {
                    results.push(ReplayOutcome {
                        call_id: call_id.clone(),
                        verb: Some(verb_name),
                        ok: false,
                        code: Some(codes::VERB_FAILED.to_string()),
                        message: e.to_string(),
                    });
                }
            }
        }
        let ok = results.iter().all(|r| r.ok);
        ReplayResult {
            ok,
            dry_run,
            message: format!(
                "{}/{} call(s) {}.",
                results.iter().filter(|r| r.ok).count(),
                results.len(),
                if dry_run { "would replay" } else { "replayed" }
            ),
            results,
        }
    }

    async fn save_macro(&self, call_ids: Vec<String>, name: String) -> SaveMacroResult {
        let store = self.store();
        let mut steps = Vec::with_capacity(call_ids.len());
        for call_id in &call_ids {
            let Some(item) = call_row(&store, call_id) else {
                return SaveMacroResult {
                    ok: false,
                    id: String::new(),
                    message: format!("no call row for {call_id}; nothing saved"),
                };
            };
            let payload = payload_json(&item);
            let verb = payload
                .get("verb")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            let args = payload.get("args").cloned().unwrap_or(json!({}));
            steps.push(json!({ "call": { "verb": verb, "args": args } }));
        }
        let author = pipeline::context::current()
            .map(|c| c.caller.to_json())
            .unwrap_or_else(|| json!({"kind": "agent", "name": "history-service"}));
        let now = Utc::now();
        let mut payload: BTreeMap<String, ItemValue> = BTreeMap::new();
        let doc = json!({
            "wire_version": 1,
            "name": name,
            "description": format!("Macro of {} recorded call(s).", steps.len()),
            "state": "proposed",
            "author": author,
            "trigger": { "manual": {} },
            "guards": {},
            "params": [],
            "sources": {},
            "steps": steps,
            "review": { "required": true },
        });
        if let Value::Object(fields) = doc {
            for (k, v) in fields {
                payload.insert(k, serde_json_to_item_value(&v));
            }
        }
        let id = uuid::Uuid::new_v4();
        let outcome = store.insert(Item {
            id,
            schema: WORKFLOW_SCHEMA.into(),
            payload,
            created: now,
            modified: now,
            author: "history-service".into(),
            author_kind: ActorKind::Agent,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::None,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: None,
            references: vec![],
            parent: None,
        });
        match outcome {
            Ok(id) => SaveMacroResult {
                ok: true,
                id: id.to_string(),
                message: format!(
                    "Saved macro '{name}' with {} step(s), proposed.",
                    call_ids.len()
                ),
            },
            Err(e) => SaveMacroResult {
                ok: false,
                id: String::new(),
                message: e.to_string(),
            },
        }
    }

    async fn health(&self) -> HistoryHealth {
        let store = self.store();
        let sink_health = crate::audit::health();
        let rows = store
            .count(&ItemQuery {
                schema: Some(VERB_CALL_SCHEMA.into()),
                ..Default::default()
            })
            .unwrap_or(0);
        let oldest = store
            .query(&ItemQuery {
                schema: Some(VERB_CALL_SCHEMA.into()),
                sort: vec![SortDescriptor {
                    field: "created".into(),
                    ascending: true,
                }],
                limit: Some(1),
                ..Default::default()
            })
            .ok()
            .and_then(|items| items.into_iter().next())
            .map(|item| call_summary(&item).started_at);
        HistoryHealth {
            ok: true,
            message: format!("{rows} call row(s) recorded."),
            written: sink_health["written"].as_u64().unwrap_or(0),
            dropped: sink_health["dropped"].as_u64().unwrap_or(0),
            failed: sink_health["failed"].as_u64().unwrap_or(0),
            no_sink: sink_health["no_sink"].as_u64().unwrap_or(0),
            channel_capacity: sink_health["channel_capacity"].as_u64().unwrap_or(0),
            rows,
            oldest,
        }
    }
}

/// `serde_json::Value` → `impress_core::item::Value`, for a predicate or a
/// hand-built payload (both otherwise want the crate's own value type).
fn serde_json_to_item_value(value: &Value) -> ItemValue {
    serde_json::from_value(value.clone()).unwrap_or(ItemValue::Null)
}

impress_service_impl! {
    service = HistoryService,
    safety = read_only,
    since = "0.1.0",
    effects = {
        reads: [any("history reads any kind's operations and every call row")],
        writes: [],
        reach: [],
    },
    impl = DefaultHistoryService,
    instance = DefaultHistoryService::new,
    strict_args = true,
    methods = [
        calls(
            /// RFC 3339 lower bound on `started_at`, inclusive.
            since: Option<String>,
            /// RFC 3339 upper bound on `started_at`, inclusive.
            until: Option<String>,
            /// Exact verb name (`imbib-tags-service_add-tag`).
            verb: Option<String>,
            /// Matches the caller's `name` exactly, or its `kind`
            /// ("human", "agent", "system").
            caller: Option<String>,
            trace_id: Option<String>,
            /// Page size; 0 for the default (50), clamped above 500.
            limit: i64,
        ) -> CallsResult,
        why(
            /// The item's id, a lowercase UUID string, of any record kind.
            id: String,
        ) -> WhyResult,
        trace(
            /// The trace id every nested call under one entry point shares.
            trace_id: String,
        ) -> TraceResult,
        replay(
            /// Call ids to re-invoke, as `core/verb-call@1.0.0` row ids.
            call_ids: Vec<String>,
            /// List what would run, and why a call cannot be, without
            /// running anything.
            dry_run: bool,
        ) -> ReplayResult,
        save_macro(
            /// The call ids to turn into a workflow's steps, in order.
            call_ids: Vec<String>,
            /// The saved workflow's `name`.
            name: String,
        ) -> SaveMacroResult,
        health() -> HistoryHealth,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_core::item::Value as CoreValue;
    use impress_service_core::pipeline::Call as PipeCall;
    use impress_service_core::VerbDescriptor;

    fn item(store: &SqliteItemStore) -> uuid::Uuid {
        crate::test_support::make_item(store, "test")
            .parse()
            .unwrap()
    }

    fn set_starred(store: Arc<SqliteItemStore>, id: uuid::Uuid, caller: &str) -> Value {
        let verb = VerbDescriptor::find("triage-service_set-starred").expect("linked");
        impress_service_core::runtime::block_on(pipeline::invoke_on(
            store,
            verb,
            PipeCall::agent(caller, json!({"id": id.to_string(), "starred": true})),
        ))
        .expect("verb ran")
    }

    /// The Tier A proof: an item created and starred through the real
    /// pipeline, then `why` names the call, its caller and the verb.
    #[test]
    fn why_names_the_call_its_caller_and_the_verb() {
        let store = crate::test_support::test_store();
        let id = item(&store);
        let answer = set_starred(store.clone(), id, "test-agent");
        assert_eq!(answer["ok"], true, "{answer}");
        crate::audit::flush();

        let svc = DefaultHistoryService::with_store(store);
        let result = impress_service_core::runtime::block_on(svc.why(id.to_string()));
        assert!(result.ok, "{}", result.message);
        assert_eq!(result.entries.len(), 1, "one operation wrote this item");
        let call = result.entries[0]
            .call
            .as_ref()
            .expect("the call row was written before we flushed");
        assert_eq!(call.verb, "triage-service_set-starred");
        assert_eq!(call.caller, json!({"kind": "agent", "name": "test-agent"}));
        assert!(!result.entries[0].applied_at.is_empty());
    }

    #[test]
    fn trace_nests_a_nested_call_under_its_parent() {
        let store = crate::test_support::test_store();
        let id_a = item(&store);
        let id_b = item(&store);
        let verb = VerbDescriptor::find("triage-service_set-starred").expect("linked");
        let trace_id = uuid::Uuid::new_v4().to_string();
        let call_a = PipeCall::agent("test", json!({"id": id_a.to_string(), "starred": true}))
            .with_trace(trace_id.clone());
        let call_b = PipeCall::agent("test", json!({"id": id_b.to_string(), "starred": true}))
            .with_trace(trace_id.clone());
        impress_service_core::runtime::block_on(pipeline::invoke_on(store.clone(), verb, call_a))
            .unwrap();
        impress_service_core::runtime::block_on(pipeline::invoke_on(store.clone(), verb, call_b))
            .unwrap();
        crate::audit::flush();

        let svc = DefaultHistoryService::with_store(store);
        let result = impress_service_core::runtime::block_on(svc.trace(trace_id.clone()));
        assert!(result.ok, "{}", result.message);
        assert_eq!(result.roots.len(), 2, "both calls are roots, no parent");
        assert!(result.roots.iter().all(|r| r.call.trace_id == trace_id));
    }

    #[test]
    fn replay_refuses_a_call_whose_args_were_privacy_reduced() {
        let store = crate::test_support::test_store();
        let id = item(&store);
        // A long string argument is reduced to {len, sha256_8} by the audit
        // layer's own privacy rule, so the recorded call is not full.
        let long = "x".repeat(200);
        let verb = VerbDescriptor::find("triage-service_add-tag").expect("linked");
        let answer = impress_service_core::runtime::block_on(pipeline::invoke_on(
            store.clone(),
            verb,
            PipeCall::agent("test", json!({"id": id.to_string(), "tag": long})),
        ))
        .expect("verb ran");
        assert_eq!(answer["ok"], true, "{answer}");
        crate::audit::flush();

        let calls = impress_service_core::runtime::block_on(
            DefaultHistoryService::with_store(store.clone()).calls(
                None,
                None,
                Some("triage-service_add-tag".into()),
                None,
                None,
                0,
            ),
        );
        let call_id = calls
            .calls
            .first()
            .expect("one call recorded")
            .call_id
            .clone();

        let svc = DefaultHistoryService::with_store(store);
        let result = impress_service_core::runtime::block_on(svc.replay(vec![call_id], false));
        assert!(!result.ok);
        assert_eq!(
            result.results[0].code.as_deref(),
            Some(codes::NOT_REPLAYABLE)
        );
    }

    #[test]
    fn replay_dry_run_lists_a_full_call_without_running_it() {
        let store = crate::test_support::test_store();
        let id = item(&store);
        set_starred(store.clone(), id, "test");
        crate::audit::flush();

        let calls = impress_service_core::runtime::block_on(
            DefaultHistoryService::with_store(store.clone()).calls(None, None, None, None, None, 0),
        );
        let call_id = calls
            .calls
            .first()
            .expect("one call recorded")
            .call_id
            .clone();

        let svc = DefaultHistoryService::with_store(store);
        let result = impress_service_core::runtime::block_on(svc.replay(vec![call_id], true));
        assert!(result.ok, "{result:?}");
        assert!(result.dry_run);
        assert!(result.results[0].message.contains("would call"));
    }

    #[test]
    fn save_macro_writes_a_proposed_workflow_document() {
        let store = crate::test_support::test_store();
        let id = item(&store);
        set_starred(store.clone(), id, "test");
        crate::audit::flush();

        let calls = impress_service_core::runtime::block_on(
            DefaultHistoryService::with_store(store.clone()).calls(None, None, None, None, None, 0),
        );
        let call_id = calls
            .calls
            .first()
            .expect("one call recorded")
            .call_id
            .clone();

        let svc = DefaultHistoryService::with_store(store.clone());
        let result = impress_service_core::runtime::block_on(
            svc.save_macro(vec![call_id], "my-macro".into()),
        );
        assert!(result.ok, "{}", result.message);
        let row = store
            .get(uuid::Uuid::parse_str(&result.id).unwrap())
            .unwrap()
            .expect("workflow row exists");
        assert_eq!(row.schema, WORKFLOW_SCHEMA);
        assert_eq!(
            row.payload.get("state"),
            Some(&CoreValue::String("proposed".into()))
        );
        let steps = row.payload.get("steps").expect("steps field");
        assert!(matches!(steps, CoreValue::Array(v) if v.len() == 1));
    }

    #[test]
    fn health_reports_the_sinks_counters_and_a_row_count() {
        let store = crate::test_support::test_store();
        let id = item(&store);
        set_starred(store.clone(), id, "test");
        crate::audit::flush();

        let svc = DefaultHistoryService::with_store(store);
        let health = impress_service_core::runtime::block_on(svc.health());
        assert!(health.ok);
        assert!(health.rows >= 1);
        assert!(health.channel_capacity > 0);
    }
}
