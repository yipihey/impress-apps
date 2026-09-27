//! The interpreter's plan: one loop over a [`Scenario`]'s steps, run against
//! an abstract [`Caller`] (SC-1's "one interpreter, two `Caller`s" — Tier A
//! and Tier B differ only in how a step reaches a verb, a surface or a
//! layout tree; this module knows none of that).
//!
//! This crate never runs a verb itself: `impress-scenario-service` supplies
//! the `Caller` (a pipeline call for Tier A, an HTTP client for Tier B), so
//! this crate stays pure (no `impress-core`, no `tokio` runtime dependency
//! beyond the trait's `async_trait` signature).

use std::collections::BTreeMap;
use std::time::Instant;

use async_trait::async_trait;
use serde_json::Value;

use crate::spec::{
    CallStep, Check, EventBody, Expect, ExpectEffects, FieldExpect, GestureStep, Scenario, Step,
    WaitBody,
};
use crate::{template, validate};
use impress_service_core::report::{CapabilityResult, Tier};

/// What a scenario step needs to do outside this crate. Every method
/// returns a plain `String` error — the interpreter's job is to say *which
/// step* failed, not to model every caller's error type.
#[async_trait]
pub trait Caller: Send {
    /// Run one verb call, as the identity `as_ident` names it
    /// (`"person"` or `"agent:<name>"`). Returns the verb's raw result
    /// value even on a refusal envelope (`{"ok": false, ...}`) — expectation
    /// checking, not this trait, decides whether that is a failure.
    async fn call(&mut self, verb: &str, args: Value, as_ident: &str) -> Result<CallOutcome, String>;

    /// Dispatch a human surface event. Tier A refuses with a clear message
    /// (no surface-hosting store per scenario in S1); Tier B posts to
    /// `/api/surface/{id}/dispatch`.
    async fn event(&mut self, event: &EventBody) -> Result<CallOutcome, String>;

    /// Run a human layout gesture — a verb aimed at the layout specifically.
    async fn gesture(&mut self, gesture: &Value) -> Result<CallOutcome, String>;

    /// Wait for a job to reach `state`, or a log line to appear, within
    /// `timeout_ms`. Returns an error naming what did not happen in time.
    async fn wait(&mut self, wait: &WaitBody) -> Result<(), String>;

    /// Insert one seed record before the first step runs (Tier A: a row in
    /// the scratch store; Tier B: unsupported today — seeding a live app's
    /// store is out of S1's scope, and `run` refuses naming that before any
    /// step executes).
    async fn seed(&mut self, kind: &str, payload: &Value) -> Result<Value, String>;

    /// Whether `kind` was written by any step run so far (the effects spy,
    /// SC-2). `Ok(false)` when the caller tracks no effects at all (Tier B
    /// without a spy) is indistinguishable from "not written" — a scenario
    /// with `expect_effects` on Tier B without spy support simply fails,
    /// which is correct: the assertion was never checked.
    fn wrote(&self, kind: &str) -> bool;
}

/// The result of one call/event/gesture, as far as expectation-checking
/// needs it.
#[derive(Debug, Clone, Default)]
pub struct CallOutcome {
    pub result: Value,
    /// The HTTP status, when the caller ran over the wire; `None` for Tier
    /// A, where there is no status to check.
    pub status: Option<u16>,
}

/// Run every step of `scenario` against `caller`, producing one
/// [`CapabilityResult`] the way every other Tier A/B catalogue already
/// does (SC-1: one report shape, not three).
pub async fn run(scenario: &Scenario, caller: &mut dyn Caller) -> CapabilityResult {
    let started = Instant::now();
    let tier: Tier = scenario.tier.into();

    if let Some(reason) = validate::unmet_requirement(scenario) {
        return skipped(scenario, tier, started, reason);
    }

    let mut captures: BTreeMap<String, Value> = BTreeMap::new();

    for seed in &scenario.seed {
        match caller.seed(&seed.kind, &seed.payload).await {
            Ok(inserted) => {
                if let Some(name) = &seed.r#as {
                    captures.insert(name.clone(), inserted);
                }
            }
            Err(e) => {
                return failed(
                    scenario,
                    tier,
                    started,
                    format!("seed `{}`: {e}", seed.kind),
                );
            }
        }
    }

    for (index, step) in scenario.steps.iter().enumerate() {
        if let Err(detail) = run_step(step, index, &mut captures, caller).await {
            run_teardown(scenario, &mut captures, caller).await;
            return failed(scenario, tier, started, detail);
        }
    }

    run_teardown(scenario, &mut captures, caller).await;

    if let Some(expect) = &scenario.expect_effects {
        if let Some(missing) = missing_effect(expect, caller) {
            return failed(
                scenario,
                tier,
                started,
                format!("expected effect on `{missing}` was not observed"),
            );
        }
    }

    passed(scenario, tier, started)
}

async fn run_teardown(scenario: &Scenario, captures: &mut BTreeMap<String, Value>, caller: &mut dyn Caller) {
    for (index, step) in scenario.teardown.iter().enumerate() {
        // Teardown failures are logged into nothing today (S1 has no
        // failure channel for a passed scenario's cleanup) but must never
        // panic the runner — best effort, silently.
        let _ = run_step(step, index, captures, caller).await;
    }
}

fn missing_effect(expect: &ExpectEffects, caller: &dyn Caller) -> Option<String> {
    expect.writes.iter().find(|k| !caller.wrote(k)).cloned()
}

async fn run_step(
    step: &Step,
    index: usize,
    captures: &mut BTreeMap<String, Value>,
    caller: &mut dyn Caller,
) -> Result<(), String> {
    let captures_value = Value::Object(captures.clone().into_iter().collect());
    match step {
        Step::Call(call_step) => run_call(call_step, index, &captures_value, captures, caller).await,
        Step::Event(event_step) => {
            let resolved = template::resolve(
                &serde_json::to_value(&event_step.event).map_err(|e| e.to_string())?,
                &captures_value,
            )
            .map_err(|e| format!("step {index} (event): {e}"))?;
            let event: EventBody =
                serde_json::from_value(resolved).map_err(|e| format!("step {index} (event): {e}"))?;
            caller
                .event(&event)
                .await
                .map(|_| ())
                .map_err(|e| format!("step {index} (event): {e}"))
        }
        Step::Gesture(GestureStep { gesture }) => {
            let resolved = template::resolve(gesture, &captures_value)
                .map_err(|e| format!("step {index} (gesture): {e}"))?;
            caller
                .gesture(&resolved)
                .await
                .map(|_| ())
                .map_err(|e| format!("step {index} (gesture): {e}"))
        }
        Step::Wait(wait_step) => caller
            .wait(&wait_step.wait)
            .await
            .map_err(|e| format!("step {index} (wait): {e}")),
    }
}

async fn run_call(
    call_step: &CallStep,
    index: usize,
    captures_value: &Value,
    captures: &mut BTreeMap<String, Value>,
    caller: &mut dyn Caller,
) -> Result<(), String> {
    let args = template::resolve(&call_step.args, captures_value)
        .map_err(|e| format!("step {index} (`{}`): {e}", call_step.call))?;
    let outcome = caller
        .call(&call_step.call, args, &call_step.r#as)
        .await
        .map_err(|e| format!("step {index} (`{}`): {e}", call_step.call))?;

    if let Some(expect) = &call_step.expect {
        check_expect(expect, &outcome).map_err(|detail| {
            format!("step {index} (`{}`): {detail}", call_step.call)
        })?;
    }

    for (name, path) in &call_step.capture {
        let captured = json_path_get(&outcome.result, path).ok_or_else(|| {
            format!(
                "step {index} (`{}`): capture `{name}` path `{path}` did not resolve",
                call_step.call
            )
        })?;
        captures.insert(name.clone(), captured.clone());
    }
    Ok(())
}

fn check_expect(expect: &Expect, outcome: &CallOutcome) -> Result<(), String> {
    if let Some(ok) = expect.ok {
        let actual = outcome.result.get("ok").and_then(Value::as_bool);
        if actual != Some(ok) {
            return Err(format!("expected ok={ok}, got {actual:?} (result: {})", outcome.result));
        }
    }
    if let Some(code) = &expect.code {
        let actual = outcome.result.get("code").and_then(Value::as_str);
        if actual != Some(code.as_str()) {
            return Err(format!("expected code=\"{code}\", got {actual:?}"));
        }
    }
    if let Some(status) = expect.status {
        if outcome.status != Some(status) {
            return Err(format!("expected status={status}, got {:?}", outcome.status));
        }
    }
    for field in &expect.fields {
        check_field(field, &outcome.result)?;
    }
    Ok(())
}

fn check_field(field: &FieldExpect, result: &Value) -> Result<(), String> {
    let path = &field.path;
    let value = json_path_get(result, path);
    match &field.check {
        Check::Equals(expected) => {
            if value != Some(expected) {
                return Err(format!("{path}: expected {expected}, got {value:?}"));
            }
        }
        Check::Contains(needle) => {
            let hay = value.and_then(Value::as_str).unwrap_or_default();
            if !hay.contains(needle.as_str()) {
                return Err(format!("{path}: expected to contain \"{needle}\", got \"{hay}\""));
            }
        }
        Check::Gte(min) => {
            let n = value.and_then(Value::as_f64);
            if n.is_none_or(|n| n < *min) {
                return Err(format!("{path}: expected >= {min}, got {n:?}"));
            }
        }
        Check::Lte(max) => {
            let n = value.and_then(Value::as_f64);
            if n.is_none_or(|n| n > *max) {
                return Err(format!("{path}: expected <= {max}, got {n:?}"));
            }
        }
        Check::Within { value: target, tol } => {
            let n = value.and_then(Value::as_f64);
            if n.is_none_or(|n| (n - target).abs() > *tol) {
                return Err(format!("{path}: expected {target} +/- {tol}, got {n:?}"));
            }
        }
        Check::Len(expected_len) => {
            let len = value.and_then(|v| match v {
                Value::Array(a) => Some(a.len()),
                Value::String(s) => Some(s.chars().count()),
                Value::Object(m) => Some(m.len()),
                _ => None,
            });
            if len != Some(*expected_len) {
                return Err(format!("{path}: expected len={expected_len}, got {len:?}"));
            }
        }
        Check::Present(want) => {
            let present = value.is_some();
            if present != *want {
                return Err(format!("{path}: expected present={want}, got {present}"));
            }
        }
        Check::Absent(want) => {
            let absent = value.is_none();
            if absent != *want {
                return Err(format!("{path}: expected absent={want}, got {absent}"));
            }
        }
    }
    Ok(())
}

/// A minimal `$.a.b.0` walk, matching the plan's spelling for `capture` and
/// `fields[].path`. `$` alone is the whole value.
fn json_path_get<'a>(value: &'a Value, path: &str) -> Option<&'a Value> {
    let path = path.strip_prefix('$').unwrap_or(path);
    let mut cur = value;
    for segment in path.split('.').filter(|s| !s.is_empty()) {
        cur = match cur {
            Value::Object(map) => map.get(segment)?,
            Value::Array(items) => items.get(segment.parse::<usize>().ok()?)?,
            _ => return None,
        };
    }
    Some(cur)
}

fn passed(scenario: &Scenario, tier: Tier, started: Instant) -> CapabilityResult {
    CapabilityResult {
        id: scenario.id.clone(),
        description: scenario.description.clone(),
        tier,
        pass: true,
        detail: "every step ran and every expectation held".to_string(),
        duration_ms: started.elapsed().as_millis() as u64,
        skipped: false,
    }
}

fn failed(scenario: &Scenario, tier: Tier, started: Instant, detail: String) -> CapabilityResult {
    CapabilityResult {
        id: scenario.id.clone(),
        description: scenario.description.clone(),
        tier,
        pass: false,
        detail,
        duration_ms: started.elapsed().as_millis() as u64,
        skipped: false,
    }
}

fn skipped(scenario: &Scenario, tier: Tier, started: Instant, reason: String) -> CapabilityResult {
    CapabilityResult {
        id: scenario.id.clone(),
        description: scenario.description.clone(),
        tier,
        pass: false,
        detail: format!("skipped: {reason}"),
        duration_ms: started.elapsed().as_millis() as u64,
        skipped: true,
    }
}
