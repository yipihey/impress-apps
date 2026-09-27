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

use std::time::Duration;

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
/// gate (P1's `VerbDescriptor::budget_ms`, not yet declared on any verb).
const EXAMPLE_TIMEOUT: Duration = Duration::from_secs(30);

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
    let call = (v.handler)(args);
    match tokio::time::timeout(EXAMPLE_TIMEOUT, call).await {
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
    }
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
}
