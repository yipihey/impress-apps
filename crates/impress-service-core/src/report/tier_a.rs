//! The Tier A example runner (plan-auto-gui-and-self-docs.md, work package
//! G3; § Examples as tests).
//!
//! An example is written once, beside the method
//! (`#[impress_example(name, args, expect)]`), and read three ways: the
//! reference page prints it, a generated form's `state` is prefilled from
//! it, and *this module* runs it against whatever store the calling process
//! has installed and checks the result against `expect`, when the example
//! states one.
//!
//! This module owns none of the store setup — it has no dependency on
//! `impress-core` or any `*-service` crate, only on
//! [`crate::VerbDescriptor`] and [`crate::Example`], so it stays a leaf every
//! service crate can share. The caller (today, `impress-capabilities`'s
//! `tests/tier_a.rs`) installs a scratch store the way
//! `crates/impress-capabilities/tests/effects.rs` already does, then calls
//! [`run_all`]. P2's per-call store override will let this module open its
//! own scratch store per example instead of depending on whatever the
//! process installed once — until then, every Tier A example in one process
//! shares one store, so an example must not assume a *clean* store, only
//! that the store exists (queries return `[]`, not an error).
//!
//! A verb is Tier A-eligible when its declared `effects.reach` never leaves
//! the process (`Reach::is_external`) — the same predicate
//! `crates/impress-capabilities/tests/effects.rs`'s `is_headless` uses,
//! duplicated here rather than shared because that test crate depends on
//! this one, not the other way around. A verb outside that set (`needs_app`,
//! network, a device, a subprocess) keeps its exception in the effects
//! table with a `tier = b`/`needs app` reason; this runner never touches it.

use std::time::{Duration, Instant};

use serde_json::Value;

use crate::descriptor::{Example, Reach, VerbDescriptor};

/// A verb is Tier A-eligible when nothing it declares leaves the process.
pub fn is_tier_a(v: &VerbDescriptor) -> bool {
    !v.effects.reach.iter().any(Reach::is_external)
}

/// How one example's run went.
#[derive(Debug)]
pub enum Outcome {
    /// The handler returned and, when the example named an `expect`, the
    /// result matched it.
    Passed { result: Value },
    /// The handler returned an error, timed out, or the result did not
    /// match `expect`. The message is what a test should print.
    Failed(String),
}

impl Outcome {
    pub fn is_pass(&self) -> bool {
        matches!(self, Outcome::Passed { .. })
    }
}

/// One example's outcome, identified by the verb and example name.
#[derive(Debug)]
pub struct ExampleResult {
    pub verb: &'static str,
    pub example: &'static str,
    pub outcome: Outcome,
}

/// How long a single example may run before this runner calls it a failure.
/// Generous: this is a correctness check, not the `budget_ms` performance
/// gate below.
const EXAMPLE_TIMEOUT: Duration = Duration::from_secs(30);

/// The multiplier this runner applies to a verb's declared `budget_ms`
/// before failing an example on it (D-P2). Chosen over a re-run: the
/// self-hosted runners are oversubscribed and shared
/// (`docs/self-hosted-runners.md`, impress-mac-3/-4 capped off) — a re-run
/// on the same loaded box would likely be slow again, costing wall-clock
/// twice for the same false positive, where a slack factor pays the cost
/// once and still catches a *real* regression (one that blows the budget by
/// more than the slack, not just crosses it under load). `3` is generous
/// enough that a verb whose budget was measured on a quiet machine does not
/// flake under a loaded CI runner, while a genuine several-times-over
/// regression still fails.
const BUDGET_SLACK_FACTOR: u32 = 3;

/// Run every example of one Tier A-eligible verb, checking `expect` where
/// given. Does nothing (returns an empty vec) for a verb outside Tier A —
/// call [`is_tier_a`] first if the caller wants to say so explicitly.
pub async fn run_verb(v: &'static VerbDescriptor) -> Vec<ExampleResult> {
    if !is_tier_a(v) {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(v.examples.len());
    for ex in v.examples {
        let outcome = run_one(v, ex).await;
        out.push(ExampleResult {
            verb: v.name,
            example: ex.name,
            outcome,
        });
    }
    out
}

async fn run_one(v: &'static VerbDescriptor, ex: &Example) -> Outcome {
    let args = ex.args_value();
    // Through the pipeline like every other path (ADR-0034 D2), as the
    // Tier A runner: a system caller, so policy never queues it for review.
    let call = crate::pipeline::invoke(
        v,
        crate::pipeline::Call::new(crate::pipeline::CallerIdentity::system("tier-a"), args),
    );
    let started = Instant::now();
    let outcome = match tokio::time::timeout(EXAMPLE_TIMEOUT, call).await {
        Err(_) => Outcome::Failed(format!(
            "`{}` example `{}` did not finish in {:?}",
            v.name, ex.name, EXAMPLE_TIMEOUT
        )),
        Ok(Err(e)) => Outcome::Failed(format!("`{}` example `{}` failed: {e}", v.name, ex.name)),
        Ok(Ok(result)) => {
            if let Some(expect) = ex.expect {
                match serde_json::from_str::<Value>(expect) {
                    Err(e) => Outcome::Failed(format!(
                        "`{}` example `{}` has an `expect` that is not JSON: {e}",
                        v.name, ex.name
                    )),
                    Ok(expected) => {
                        if shape_matches(&expected, &result) {
                            Outcome::Passed { result }
                        } else {
                            Outcome::Failed(format!(
                                "`{}` example `{}`: expected shape {expected}, got {result}",
                                v.name, ex.name
                            ))
                        }
                    }
                }
            } else {
                Outcome::Passed { result }
            }
        }
    };
    // D-P2: a Tier A example whose verb declares `budget_ms` fails when it
    // blows that budget by more than `BUDGET_SLACK_FACTOR` — checked after
    // (never instead of) correctness, so a failing example is reported for
    // failing, not for running long while broken.
    if outcome.is_pass() {
        if let Some(budget_ms) = v.budget_ms {
            let elapsed_ms = started.elapsed().as_millis() as u64;
            let ceiling_ms = budget_ms.saturating_mul(u64::from(BUDGET_SLACK_FACTOR));
            if elapsed_ms > ceiling_ms {
                return Outcome::Failed(format!(
                    "`{}` example `{}` took {elapsed_ms}ms, over its {budget_ms}ms budget \
                     (even with {BUDGET_SLACK_FACTOR}x CI slack, ceiling {ceiling_ms}ms)",
                    v.name, ex.name
                ));
            }
        }
    }
    outcome
}

/// Whether `actual` matches the shape `expected` describes. This is a
/// **subset** match, not equality: every key `expected` names must be
/// present in `actual` with an equal (recursively matching) value, but
/// `actual` may carry other keys `expected` does not mention (a
/// `revision`, a timestamp, a generated id). An array in `expected` must
/// match `actual`'s array elementwise and in length — an example that
/// wants "at least N" should assert on a scalar (`"count": 1`) instead.
/// Anything else (numbers, strings, bools, null) is compared for equality.
fn shape_matches(expected: &Value, actual: &Value) -> bool {
    match (expected, actual) {
        (Value::Object(e), Value::Object(a)) => e
            .iter()
            .all(|(k, ev)| a.get(k).is_some_and(|av| shape_matches(ev, av))),
        (Value::Array(e), Value::Array(a)) => {
            e.len() == a.len() && e.iter().zip(a).all(|(ev, av)| shape_matches(ev, av))
        }
        (e, a) => e == a,
    }
}

/// Run every example of every Tier A-eligible verb in `verbs`. A verb with
/// zero examples contributes nothing (its absence is a separate check —
/// `docs/verb-coverage.md`/the effects exception table, not this runner's).
pub async fn run_all(
    verbs: impl IntoIterator<Item = &'static VerbDescriptor>,
) -> Vec<ExampleResult> {
    let mut out = Vec::new();
    for v in verbs {
        out.extend(run_verb(v).await);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shape_matches_is_a_subset_check() {
        let expected = serde_json::json!({"ok": true, "n": 3});
        let actual = serde_json::json!({"ok": true, "n": 3, "revision": 7});
        assert!(shape_matches(&expected, &actual));

        let mismatched = serde_json::json!({"ok": false, "n": 3});
        assert!(!shape_matches(&mismatched, &actual));

        let missing_key = serde_json::json!({"ok": true, "missing": 1});
        assert!(!shape_matches(&missing_key, &actual));
    }

    #[test]
    fn shape_matches_arrays_elementwise() {
        let expected = serde_json::json!({"x": [1, 2, 3]});
        assert!(shape_matches(
            &expected,
            &serde_json::json!({"x": [1, 2, 3], "extra": true})
        ));
        assert!(!shape_matches(&expected, &serde_json::json!({"x": [1, 2]})));
    }

    use crate::descriptor::{Effects, Safety, SafetyClass, Source};
    use crate::ServiceFuture;

    fn schema() -> Value {
        serde_json::json!({})
    }

    fn instant_ok(_: Value) -> ServiceFuture {
        Box::pin(async { Ok(serde_json::json!({"ok": true})) })
    }

    fn slow_ok(_: Value) -> ServiceFuture {
        Box::pin(async {
            tokio::time::sleep(Duration::from_millis(60)).await;
            Ok(serde_json::json!({"ok": true}))
        })
    }

    fn budgeted_verb(
        name: &'static str,
        budget_ms: Option<u64>,
        handler: fn(Value) -> ServiceFuture,
    ) -> VerbDescriptor {
        VerbDescriptor {
            name,
            service: "tier-a-budget-test",
            method: "x",
            description: "d",
            input_schema: schema,
            output_schema: schema,
            safety: Safety {
                class: SafetyClass::ReadOnly,
                idempotent: true,
            },
            effects: Effects::NONE,
            since: "0.1.0",
            deprecated: None,
            aliases: &[],
            examples: &[Example {
                name: "default",
                args: "{}",
                expect: None,
            }],
            strict: false,
            budget_ms,
            source: Source::Linked,
            handler,
        }
    }

    #[tokio::test]
    async fn an_example_over_budget_even_with_slack_fails() {
        static VERB: std::sync::OnceLock<VerbDescriptor> = std::sync::OnceLock::new();
        let verb = VERB.get_or_init(|| budgeted_verb("tier-a-budget-test_slow", Some(1), slow_ok));
        let results = run_verb(verb).await;
        assert_eq!(results.len(), 1);
        assert!(
            !results[0].outcome.is_pass(),
            "a call several times over a 1ms budget must fail, not just log"
        );
        if let Outcome::Failed(message) = &results[0].outcome {
            assert!(message.contains("budget"), "{message}");
        }
    }

    #[tokio::test]
    async fn an_example_inside_budget_passes() {
        static VERB: std::sync::OnceLock<VerbDescriptor> = std::sync::OnceLock::new();
        let verb =
            VERB.get_or_init(|| budgeted_verb("tier-a-budget-test_fast", Some(1_000), instant_ok));
        let results = run_verb(verb).await;
        assert_eq!(results.len(), 1);
        assert!(results[0].outcome.is_pass());
    }

    #[tokio::test]
    async fn no_budget_declared_means_no_ceiling() {
        static VERB: std::sync::OnceLock<VerbDescriptor> = std::sync::OnceLock::new();
        let verb =
            VERB.get_or_init(|| budgeted_verb("tier-a-budget-test_unbudgeted", None, slow_ok));
        let results = run_verb(verb).await;
        assert_eq!(results.len(), 1);
        assert!(
            results[0].outcome.is_pass(),
            "no budget_ms means no ceiling, however long the call took"
        );
    }
}
