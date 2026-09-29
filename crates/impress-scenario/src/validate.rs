//! Structural validation of a [`Scenario`], independent of any caller.
//!
//! `validate` checks what a spec alone can prove: capture names referenced
//! before they exist, an empty step list, and `wait.log` bounds/needles. It
//! cannot check that a `call` step names a real verb (this crate
//! has no inventory) — `impress-scenario-service`'s `validate` verb adds
//! that check with the inventory it links.

use std::collections::BTreeSet;

use crate::spec::{Requires, Scenario, Step};

/// One structural problem, with the step index it was found at (`None` for
/// a scenario-level problem).
#[derive(Debug, Clone, PartialEq)]
pub struct Problem {
    pub step: Option<usize>,
    pub message: String,
}

/// Every structural problem found. Empty means the spec is well-formed —
/// not that every verb it calls exists.
pub fn validate(scenario: &Scenario) -> Vec<Problem> {
    let mut problems = Vec::new();

    if scenario.steps.is_empty() {
        problems.push(Problem {
            step: None,
            message: "a scenario needs at least one step".to_string(),
        });
    }

    let mut known: BTreeSet<String> = scenario
        .seed
        .iter()
        .filter_map(|s| s.r#as.clone())
        .collect();

    for (index, step) in scenario.steps.iter().chain(&scenario.teardown).enumerate() {
        let args = match step {
            Step::Call(call) => serde_json::json!({
                "args": call.args,
                "expect": call.expect,
                "capture": call.capture
            }),
            Step::BestEffort(step) => step.best_effort.args.clone(),
            Step::Store(step) => {
                if step.store.schema_ref.trim().is_empty()
                    || !(1..=10_000).contains(&step.store.max_rows)
                {
                    problems.push(Problem {
                        step: Some(index),
                        message: "store requires a schema_ref and max_rows in 1..=10000".into(),
                    });
                }
                serde_json::to_value(&step.store).expect("store spec serializes")
            }
            Step::Event(step) => serde_json::to_value(&step.event).expect("event serializes"),
            Step::Gesture(step) => step.gesture.clone(),
            Step::Wait(step) => serde_json::to_value(&step.wait).expect("wait serializes"),
        };
        for reference in referenced_captures(&args) {
            if !known.contains(&reference) {
                problems.push(Problem { step: Some(index), message: format!(
                    "`{{{{state.{reference}}}}}` is referenced before `{reference}` is captured or seeded"
                ) });
            }
        }
        if let Step::Wait(wait) = step {
            match &wait.wait {
                crate::spec::WaitBody::Log { log } => {
                    if !(1..=60_000).contains(&log.timeout_ms) {
                        problems.push(Problem {
                            step: Some(index),
                            message: "wait.log timeout_ms must be in 1..=60000".into(),
                        });
                    }
                    if log.contains.trim().is_empty()
                        || log
                            .also_contains
                            .iter()
                            .any(|needle| needle.trim().is_empty())
                    {
                        problems.push(Problem {
                            step: Some(index),
                            message: "wait.log requires non-empty message needles".into(),
                        });
                    }
                }
                crate::spec::WaitBody::LogCursor { log_cursor }
                    if log_cursor.capture.trim().is_empty() =>
                {
                    problems.push(Problem {
                        step: Some(index),
                        message: "wait.log_cursor requires a capture name".into(),
                    });
                }
                _ => {}
            }
        }
        match step {
            Step::Call(call) => known.extend(call.capture.keys().cloned()),
            Step::Store(step) => known.extend(step.capture.keys().cloned()),
            Step::Gesture(step) => known.extend(step.capture.keys().cloned()),
            Step::Wait(wait) => {
                if let crate::spec::WaitBody::LogCursor { log_cursor } = &wait.wait {
                    if !log_cursor.capture.trim().is_empty() {
                        known.insert(log_cursor.capture.clone());
                    }
                }
            }
            _ => {}
        }
    }

    problems
}

/// Every `state.<name>` reference's first segment, anywhere inside `value`
/// — a light scan (not `impress_surface::template::Template::parse`,
/// which would flag this as a public dependency this module does not need)
/// good enough to catch a typo before a run.
fn referenced_captures(value: &serde_json::Value) -> Vec<String> {
    let mut out = Vec::new();
    scan(value, &mut out);
    out
}

fn scan(value: &serde_json::Value, out: &mut Vec<String>) {
    match value {
        serde_json::Value::String(s) => {
            let mut rest = s.as_str();
            while let Some(start) = rest.find("{{state.") {
                let after = &rest[start + "{{state.".len()..];
                if let Some(end) = after.find("}}") {
                    let path = &after[..end];
                    let name = path.split('.').next().unwrap_or(path);
                    if !name.is_empty() {
                        out.push(name.to_string());
                    }
                    rest = &after[end + 2..];
                } else {
                    break;
                }
            }
        }
        serde_json::Value::Array(items) => items.iter().for_each(|v| scan(v, out)),
        serde_json::Value::Object(map) => map.values().for_each(|v| scan(v, out)),
        _ => {}
    }
}

/// Whether `scenario.requires` holds, given the runner's knowledge of what
/// app is up, what preset exists, and what kinds are present. Returns
/// `None` when the runner has no way to check requirements at all (this
/// pure crate) — always `None` here, since `Requires` is checked by the
/// caller, which owns the store/app it can inspect. Kept as a named
/// function so [`crate::interpret::run`] has one place to change if S2
/// gives this crate a way to check requirements itself.
pub fn unmet_requirement(_scenario: &Scenario) -> Option<String> {
    None
}

/// Read-only accessor kept for symmetry with `unmet_requirement`, exercised
/// by `impress-scenario-service` when it decides to skip before calling
/// `interpret::run` at all (`Requires` alone, no caller involved).
pub fn requires_ok(
    requires: &Requires,
    app_up: impl Fn(&str) -> bool,
    preset_exists: impl Fn(&str) -> bool,
    kind_present: impl Fn(&str) -> bool,
) -> Option<String> {
    if let Some(app) = &requires.app {
        if !app_up(app) {
            return Some(format!("app `{app}` is not running"));
        }
    }
    if let Some(preset) = &requires.preset {
        if !preset_exists(preset) {
            return Some(format!("preset `{preset}` is not shipped"));
        }
    }
    for kind in &requires.kinds_present {
        if !kind_present(kind) {
            return Some(format!("no `{kind}` row is present"));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::{CallStep, Scenario, SeedRecord, Step, Tier};
    use serde_json::json;

    fn base(steps: Vec<Step>) -> Scenario {
        Scenario {
            wire_version: 1,
            id: "t".to_string(),
            description: "d".to_string(),
            tier: Tier::A,
            requires: None,
            seed: Vec::new(),
            steps,
            teardown: Vec::new(),
            expect_effects: None,
        }
    }

    fn call(args: serde_json::Value) -> Step {
        Step::Call(CallStep {
            call: "x".to_string(),
            args,
            r#as: "agent:scenario".to_string(),
            expect: None,
            capture: Default::default(),
        })
    }

    #[test]
    fn empty_steps_is_a_problem() {
        let problems = validate(&base(vec![]));
        assert!(problems
            .iter()
            .any(|p| p.message.contains("at least one step")));
    }

    #[test]
    fn a_capture_referenced_before_it_exists_is_a_problem() {
        let scenario = base(vec![call(json!({"name": "{{state.missing}}"}))]);
        let problems = validate(&scenario);
        assert_eq!(problems.len(), 1);
        assert!(problems[0].message.contains("missing"));
    }

    #[test]
    fn a_seeded_capture_is_known() {
        let mut scenario = base(vec![call(json!({"name": "{{state.paper}}"}))]);
        scenario.seed = vec![SeedRecord {
            kind: "imbib/bibliography-entry".to_string(),
            payload: json!({}),
            r#as: Some("paper".to_string()),
        }];
        assert!(validate(&scenario).is_empty());
    }

    #[test]
    fn a_capture_from_an_earlier_step_is_known_to_a_later_one() {
        let mut first = call(json!({}));
        if let Step::Call(c) = &mut first {
            c.capture.insert("name".to_string(), "$.name".to_string());
        }
        let second = call(json!({"name": "{{state.name}}"}));
        let scenario = base(vec![first, second]);
        assert!(validate(&scenario).is_empty());
    }

    #[test]
    fn log_cursor_and_gesture_captures_are_known_to_later_steps() {
        let scenario: Scenario = serde_json::from_value(json!({
            "wire_version": 1,
            "id": "cursor",
            "description": "captured cursors",
            "tier": "b",
            "steps": [
                {"wait": {"log_cursor": {"capture": "before"}}},
                {"gesture": {"verb": "split"}, "capture": {"tile": "$.focused"}},
                {"wait": {"log": {
                    "category": "layout",
                    "contains": "pane {{state.tile}}",
                    "also_contains": ["Console"],
                    "after": "{{state.before}}",
                    "timeout_ms": 3000
                }}}
            ]
        }))
        .unwrap();
        assert!(validate(&scenario).is_empty());
    }

    #[test]
    fn log_wait_requires_prior_cursor_and_a_bounded_nonempty_needle_set() {
        let scenario: Scenario = serde_json::from_value(json!({
            "wire_version": 1,
            "id": "bad-log-wait",
            "description": "invalid log wait",
            "tier": "b",
            "steps": [{"wait": {"log": {
                "category": "layout",
                "contains": "",
                "also_contains": [""],
                "after": "{{state.missing}}",
                "timeout_ms": 60001
            }}}]
        }))
        .unwrap();
        let problems = validate(&scenario);
        assert!(problems.iter().any(|p| p.message.contains("missing")));
        assert!(problems.iter().any(|p| p.message.contains("1..=60000")));
        assert!(problems
            .iter()
            .any(|p| p.message.contains("non-empty message needles")));
    }
}
