//! The invoker pipeline (ADR-0034 D2, plan-verb-pipeline P2).
//!
//! One ordered, hand-rolled chain that EVERY path running a verb goes
//! through — MCP flat and grouped, the CLI, the surface runtime and its HTTP
//! mirror, the FFI verb host and the FFI layout `apply`, impel-tools,
//! mcp-host, impress-ai-tools. Each concern is written once, here, as a
//! layer; adding one changes no entry path. A test in
//! `crates/impress-capabilities/tests/pipeline.rs` enumerates every
//! `descriptor.handler` call site in the repository and fails when one is
//! outside this module.
//!
//! The layers, in order (ADR-0034 D2's ordering rule: nothing that can refuse
//! runs after a side effect; identity before policy; the span encloses
//! invoke and envelope; audit records the final code):
//!
//! 1. **identity** — the caller the entry path established
//!    ([`CallerIdentity`]); a call that runs inside another call inherits its
//!    caller and trace and records the outer call as its parent.
//! 2. **strict args** — the schema check ([`crate::strict`]) for a service
//!    declaring `strict_args`; refused `invalid-argument` naming the field
//!    (moved here from the generated invoker, which now parses nothing but
//!    its own args struct).
//! 3. **reachability** — one rule and one probe ([`reachability`]).
//! 4. **policy** — `(caller, class, verb) → run | review | deny`
//!    ([`policy`]).
//! 5. **span** — a `tracing` span per call: name, caller, ids, sizes,
//!    outcome, duration; never an argument value.
//! 6. **invoke** — the generated handler, under the task-local
//!    [`context::CallContext`].
//! 7. **envelope** — `ok`/`code` read off the result (the value itself is
//!    unchanged: `wire_version` is the verb's own, D-G6 is G-side work).
//! 8. **audit** — one `core/verb-call@1.0.0` record per non-read-only call
//!    ([`audit`]).
//!
//! Hand-rolled rather than tower (ADR-0034 § Alternatives): the chain must
//! wrap the two bypasses that carry no request type, which
//! [`invoke_sync_with`] and [`invoke_with`] do by taking the handler step as
//! a closure.

pub mod audit;
pub mod context;
pub mod identity;
pub mod policy;
pub mod reachability;

use std::sync::{Arc, Once};
use std::time::Instant;

use serde_json::Value;

use crate::descriptor::{SafetyClass, VerbDescriptor};
use crate::{BoxError, ServiceFuture};
pub use context::CallContext;
pub use identity::CallerIdentity;

/// One call, as an entry path hands it to the pipeline.
#[derive(Debug, Clone)]
pub struct Call {
    pub args: Value,
    pub caller: CallerIdentity,
    /// The trace to join, when the transport carried one (`traceparent`).
    pub trace_id: Option<String>,
    /// The call this one runs for, when the transport says so.
    pub parent_call: Option<String>,
    /// A per-call store override (H-P2-3), set by [`invoke_on`].
    pub store: Option<Arc<dyn std::any::Any + Send + Sync>>,
}

impl Call {
    pub fn new(caller: CallerIdentity, args: Value) -> Self {
        Self {
            args,
            caller,
            trace_id: None,
            parent_call: None,
            store: None,
        }
    }

    pub fn person(args: Value) -> Self {
        Self::new(CallerIdentity::Person, args)
    }

    pub fn agent(name: impl Into<String>, args: Value) -> Self {
        Self::new(CallerIdentity::agent(name), args)
    }

    pub fn with_trace(mut self, trace_id: impl Into<String>) -> Self {
        self.trace_id = Some(trace_id.into());
        self
    }
}

/// Why the pipeline did not run the handler, or what the handler said.
#[derive(Debug, thiserror::Error)]
pub enum PipelineError {
    /// The verb's app is not running (the reachability layer). `Display` is
    /// the text impress-mcp has always answered for this.
    #[error("{}", reachability::reason_text(app, verb))]
    Unavailable {
        app: &'static str,
        verb: &'static str,
    },
    /// The handler's own error, as it returned it.
    #[error("{0}")]
    Handler(BoxError),
}

/// A hook a linked crate registers to run once, before the first call in
/// the process: how `impress-store-service` installs the audit sink without
/// this crate reaching the store. Submitted through `inventory`, so linking
/// the crate is installing the hook.
pub struct Installer {
    pub name: &'static str,
    pub install: fn(),
}

inventory::collect!(Installer);

fn run_installers() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        for installer in inventory::iter::<Installer> {
            (installer.install)();
        }
    });
}

/// What the layers before the handler produced.
struct Prepared {
    context: Arc<CallContext>,
    args: Value,
    started: Instant,
    started_at: String,
    arg_bytes: usize,
    span: tracing::Span,
}

/// The layers before the handler: identity, strict args, reachability,
/// policy, the span. `Ok(Err(value))` is a refusal envelope to answer
/// without running the handler.
fn prepare(
    verb: &'static VerbDescriptor,
    call: Call,
) -> Result<Result<Prepared, Value>, PipelineError> {
    run_installers();
    let Call {
        args,
        caller,
        trace_id,
        parent_call,
        store,
    } = call;
    let args = if args.is_null() {
        Value::Object(Default::default())
    } else {
        args
    };

    // 1. identity — inherit the enclosing call's, when there is one.
    let outer = context::current();
    let (caller, trace_id, parent_call, store) = match &outer {
        Some(outer) => (
            outer.caller.clone(),
            Some(outer.trace_id.clone()),
            Some(outer.call_id.clone()),
            store.or_else(|| outer.store_override.clone()),
        ),
        None => (caller, trace_id, parent_call, store),
    };
    let call_id = uuid::Uuid::new_v4().to_string();
    let trace_id = trace_id.unwrap_or_else(|| call_id.clone());

    // 2. strict args.
    if verb.strict {
        let schema = (verb.input_schema)();
        if let Err(refusal) = crate::strict::check_args(verb.name, &args, &schema) {
            return Ok(Err(crate::strict::refusal_value(&refusal)));
        }
    }

    // 3. reachability.
    if let Some(app) = reachability::unavailable_app(verb.name) {
        return Err(PipelineError::Unavailable {
            app,
            verb: verb.name,
        });
    }

    // 4. policy.
    match policy::decide(&caller, verb) {
        policy::Decision::Run => {}
        policy::Decision::Review => return Ok(Err(policy::queue(&caller, verb, &args))),
        policy::Decision::Deny(reason) => return Ok(Err(policy::deny(verb, reason))),
    }

    // 5. span.
    let arg_bytes = audit::approx_size(&args);
    let span = tracing::info_span!(
        target: "verb",
        "verb",
        name = verb.name,
        caller = %caller,
        call_id = %call_id,
        trace_id = %trace_id,
        parent_call = parent_call.as_deref().unwrap_or(""),
        arg_bytes,
        ok = tracing::field::Empty,
        code = tracing::field::Empty,
        result_bytes = tracing::field::Empty,
        duration_us = tracing::field::Empty,
    );
    let context = Arc::new(CallContext {
        call_id,
        trace_id,
        parent_call,
        caller,
        verb: verb.name,
        store_override: store,
    });
    Ok(Ok(Prepared {
        context,
        args,
        started: Instant::now(),
        started_at: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        arg_bytes,
        span,
    }))
}

/// `ok` and `code` as the envelope layer reads them off a result.
fn outcome(result: &Result<Value, BoxError>) -> (bool, Option<String>, usize, usize) {
    match result {
        Ok(value) => {
            let ok = value.get("ok").and_then(Value::as_bool).unwrap_or(true);
            let code = value
                .get("code")
                .and_then(Value::as_str)
                .map(str::to_string);
            let message_len = value
                .get("message")
                .and_then(Value::as_str)
                .map_or(0, str::len);
            (ok, code, message_len, audit::approx_size(value))
        }
        Err(error) => (
            false,
            Some(crate::refusal::codes::VERB_FAILED.to_string()),
            error.to_string().len(),
            0,
        ),
    }
}

/// The layers after the handler: envelope and audit.
fn finish(verb: &'static VerbDescriptor, prepared: Prepared, result: &Result<Value, BoxError>) {
    let Prepared {
        context,
        span,
        started,
        started_at,
        arg_bytes,
        ..
    } = prepared;
    let duration = started.elapsed();
    let (ok, code, message_len, result_bytes) = outcome(result);
    span.record("ok", ok);
    span.record("code", code.as_deref().unwrap_or(""));
    span.record("result_bytes", result_bytes);
    span.record("duration_us", duration.as_micros() as u64);
    drop(span);

    if verb.safety.class != SafetyClass::ReadOnly || audit::log_all() {
        let args_summary = audit::summarize_args(&prepared.args, &(verb.input_schema)());
        audit::record(audit::VerbCallRecord {
            call_id: context.call_id.clone(),
            verb: verb.name,
            since: verb.since,
            caller: context.caller.clone(),
            trace_id: context.trace_id.clone(),
            parent_call: context.parent_call.clone(),
            args: args_summary,
            ok,
            code,
            message_len,
            started_at,
            duration_ms: duration.as_millis() as u64,
            arg_bytes,
            result_bytes,
            store_override: context.store_override.clone(),
        });
    }
}

/// Run `verb` through the chain with its own handler as the handler step.
pub async fn invoke(verb: &'static VerbDescriptor, call: Call) -> Result<Value, PipelineError> {
    invoke_with(verb, call, verb.handler).await
}

/// Run `verb` through the chain on `store` instead of the process-wide
/// store (H-P2-3, D-R9): a Tier A scenario's per-scenario store. The
/// store-tier crates read it back with [`context::store_override`].
pub async fn invoke_on<S: std::any::Any + Send + Sync>(
    store: Arc<S>,
    verb: &'static VerbDescriptor,
    mut call: Call,
) -> Result<Value, PipelineError> {
    call.store = Some(store);
    invoke(verb, call).await
}

/// Run the chain around `work` as the handler step — for a path whose
/// handler is not the descriptor's `fn` (the surface HTTP mirror runs the
/// verb on the FFI's own service instance).
pub async fn invoke_with<F>(
    verb: &'static VerbDescriptor,
    call: Call,
    work: F,
) -> Result<Value, PipelineError>
where
    F: FnOnce(Value) -> ServiceFuture,
{
    let prepared = match prepare(verb, call)? {
        Ok(prepared) => prepared,
        Err(refused) => return Ok(refused),
    };
    let entered = prepared.span.clone();
    let result = {
        let _guard = entered.enter();
        let future = work(prepared.args.clone());
        drop(_guard);
        tracing::Instrument::instrument(context::scope(prepared.context.clone(), future), entered)
            .await
    };
    finish(verb, prepared, &result);
    result.map_err(PipelineError::Handler)
}

/// [`invoke_with`] for a synchronous handler step (the FFI's layout
/// `apply`, a sync call from Swift). The task-local context is set with
/// `sync_scope`, so the store stamps `batch_id` on what `work` writes.
pub fn invoke_sync_with<F>(
    verb: &'static VerbDescriptor,
    call: Call,
    work: F,
) -> Result<Value, PipelineError>
where
    F: FnOnce(Value) -> Result<Value, BoxError>,
{
    let prepared = match prepare(verb, call)? {
        Ok(prepared) => prepared,
        Err(refused) => return Ok(refused),
    };
    let result = {
        let _guard = prepared.span.enter();
        context::sync_scope(prepared.context.clone(), || work(prepared.args.clone()))
    };
    finish(verb, prepared, &result);
    result.map_err(PipelineError::Handler)
}

/// [`invoke`] from a synchronous context (CLI dispatch, an FFI shim), on
/// the shared service runtime.
pub fn invoke_blocking(verb: &'static VerbDescriptor, call: Call) -> Result<Value, PipelineError> {
    crate::runtime::block_on(invoke(verb, call))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::descriptor::{Safety, Source};
    use serde_json::json;
    use std::sync::Mutex;

    fn schema() -> Value {
        json!({"type": "object", "properties": {"n": {"type": "integer"}}})
    }
    fn echo(args: Value) -> ServiceFuture {
        Box::pin(async move {
            Ok(json!({"ok": true, "echo": args, "call": context::current_call_id()}))
        })
    }
    fn failing(_: Value) -> ServiceFuture {
        Box::pin(async { Err("boom".into()) })
    }
    static ECHO: VerbDescriptor = VerbDescriptor {
        name: "t-service_echo",
        service: "t-service",
        method: "echo",
        description: "d",
        input_schema: schema,
        output_schema: schema,
        safety: Safety {
            class: SafetyClass::Mutating,
            idempotent: false,
        },
        since: "0.1.0",
        deprecated: None,
        aliases: &[],
        examples: &[],
        strict: true,
        source: Source::Linked,
        handler: echo,
    };
    static FAILING: VerbDescriptor = VerbDescriptor {
        name: "t-service_fail",
        method: "fail",
        handler: failing,
        strict: false,
        ..ECHO
    };

    struct Captured(Mutex<Vec<audit::VerbCallRecord>>);
    impl audit::Sink for Captured {
        fn record(&self, record: audit::VerbCallRecord) {
            self.0.lock().unwrap().push(record);
        }
    }

    /// The sink is process-global and the tests run in parallel, so they
    /// share one.
    fn captured() -> Arc<Captured> {
        static SINK: std::sync::OnceLock<Arc<Captured>> = std::sync::OnceLock::new();
        SINK.get_or_init(|| {
            let sink = Arc::new(Captured(Mutex::new(Vec::new())));
            audit::install(sink.clone());
            sink
        })
        .clone()
    }

    #[test]
    fn a_strict_verb_refuses_an_unknown_field_before_the_handler() {
        let answer = invoke_blocking(&ECHO, Call::person(json!({"nn": 1}))).unwrap();
        assert_eq!(answer["ok"], false);
        assert_eq!(answer["code"], "invalid-argument");
        assert!(answer["message"]
            .as_str()
            .unwrap()
            .contains("t-service_echo"));
        assert!(answer["message"].as_str().unwrap().contains("'nn'"));
        assert_eq!(answer["wire_version"], crate::wire::WIRE_VERSION);
    }

    #[test]
    fn null_arguments_are_an_empty_object() {
        let answer = invoke_blocking(&ECHO, Call::person(Value::Null)).unwrap();
        assert_eq!(answer["echo"], json!({}));
    }

    #[test]
    fn the_handler_runs_under_a_call_context_and_the_audit_row_carries_it() {
        let sink = captured();
        let answer = invoke_blocking(&ECHO, Call::agent("test", json!({"n": 7}))).unwrap();
        let call_id = answer["call"]
            .as_str()
            .expect("the handler saw its call id");
        let records = sink.0.lock().unwrap();
        let record = records
            .iter()
            .find(|r| r.call_id == call_id)
            .expect("one audit record for the mutating call");
        assert_eq!(record.verb, "t-service_echo");
        assert_eq!(record.caller, CallerIdentity::agent("test"));
        assert!(record.ok);
        assert_eq!(record.args, json!({"n": 7}));
        assert_eq!(
            record.trace_id, call_id,
            "a fresh call starts its own trace"
        );
    }

    #[test]
    fn a_nested_call_inherits_the_caller_and_the_trace() {
        fn nested(_: Value) -> ServiceFuture {
            Box::pin(async {
                let outer = context::current().unwrap();
                let inner = invoke(&ECHO, Call::person(json!({}))).await.unwrap();
                let inner_ctx = inner["call"].as_str().unwrap().to_string();
                Ok(json!({"outer": outer.call_id, "inner": inner_ctx, "trace": outer.trace_id}))
            })
        }
        static OUTER: VerbDescriptor = VerbDescriptor {
            name: "t-service_outer",
            method: "outer",
            handler: nested,
            strict: false,
            ..ECHO
        };
        let sink = captured();
        let answer =
            invoke_blocking(&OUTER, Call::agent("mcp", json!({})).with_trace("trace-1")).unwrap();
        assert_eq!(answer["trace"], "trace-1");
        let records = sink.0.lock().unwrap();
        let inner = records
            .iter()
            .find(|r| r.call_id == answer["inner"].as_str().unwrap())
            .unwrap();
        assert_eq!(
            inner.caller,
            CallerIdentity::agent("mcp"),
            "not the Person it claimed"
        );
        assert_eq!(inner.trace_id, "trace-1");
        assert_eq!(inner.parent_call.as_deref(), answer["outer"].as_str());
    }

    #[test]
    fn a_handler_error_is_the_pipelines_handler_error() {
        let err = invoke_blocking(&FAILING, Call::person(json!({}))).unwrap_err();
        assert!(matches!(err, PipelineError::Handler(_)));
        assert_eq!(err.to_string(), "boom");
    }

    #[test]
    fn the_sync_chain_sets_the_context_too() {
        let seen = invoke_sync_with(&ECHO, Call::person(json!({})), |_| {
            Ok(json!({"call": context::current_call_id()}))
        })
        .unwrap();
        assert!(seen["call"].is_string());
        assert!(context::current().is_none());
    }

    #[test]
    fn the_store_override_reaches_the_handler() {
        fn reads_store(_: Value) -> ServiceFuture {
            Box::pin(async { Ok(json!(context::store_override::<u64>().map(|s| *s))) })
        }
        static READS: VerbDescriptor = VerbDescriptor {
            name: "t-service_reads",
            method: "reads",
            handler: reads_store,
            strict: false,
            ..ECHO
        };
        let seen =
            crate::runtime::block_on(invoke_on(Arc::new(9u64), &READS, Call::person(json!({}))))
                .unwrap();
        assert_eq!(seen, json!(9));
    }
}
