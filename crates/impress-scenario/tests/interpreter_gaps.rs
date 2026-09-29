use async_trait::async_trait;
use impress_scenario::{
    run, template, validate, CallOutcome, Caller, EventBody, Scenario, WaitBody,
};
use serde_json::{json, Value};

#[derive(Default)]
struct Fixture {
    calls: Vec<(String, Value)>,
    truncated: bool,
    gesture_refused: bool,
    timeline: Vec<&'static str>,
    waits: Vec<WaitBody>,
}
#[async_trait]
impl Caller for Fixture {
    async fn call(&mut self, verb: &str, args: Value, _: &str) -> Result<CallOutcome, String> {
        self.timeline.push("call");
        self.calls.push((verb.into(), args.clone()));
        let result = match verb {
            "unavailable" => return Err("owned host unavailable".into()),
            "refusal" => json!({"ok":false,"code":"forbidden"}),
            "store-query-service_list-items" => {
                let start = args["offset"].as_u64().unwrap();
                let end = (start + args["limit"].as_u64().unwrap()).min(102);
                json!({"ok":true,"total":102,"items":(start..end).map(|n| json!({"id":n.to_string()})).collect::<Vec<_>>()})
            }
            "store-query-service_get-item" => {
                json!({"ok":true,"item":{"id":args["id"],"schema_ref":"manuscript"},
                "payload":json!({"title":if args["id"]=="101" {"match"} else {"other"}}).to_string(),"truncated":self.truncated})
            }
            _ => args,
        };
        Ok(CallOutcome {
            result,
            status: Some(200),
        })
    }
    async fn event(&mut self, _: &EventBody) -> Result<CallOutcome, String> {
        Err("unused".into())
    }
    async fn gesture(&mut self, _: &Value) -> Result<CallOutcome, String> {
        self.timeline.push("gesture");
        Ok(CallOutcome {
            result: if self.gesture_refused {
                json!({"ok":false,"code":"invalid-argument"})
            } else {
                json!({"ok":true,"focused":7})
            },
            status: Some(200),
        })
    }
    async fn wait(&mut self, wait: &WaitBody) -> Result<(), String> {
        self.timeline.push("wait");
        self.waits.push(wait.clone());
        Ok(())
    }
    async fn log_cursor(&mut self) -> Result<String, String> {
        self.timeline.push("cursor");
        Ok("2026-09-28T12:00:00.000Z".into())
    }
    async fn seed(&mut self, _: &str, _: &Value) -> Result<Value, String> {
        Err("unused".into())
    }
    fn wrote(&self, _: &str) -> bool {
        false
    }
}
fn scenario(steps: Value) -> Scenario {
    serde_json::from_value(json!({"wire_version":1,"id":"gaps","description":"owned fixture","tier":"a","steps":steps})).unwrap()
}
fn execute(s: &Scenario, fixture: &mut Fixture) -> impress_service_core::report::CapabilityResult {
    impress_service_core::runtime::block_on(run(s, fixture))
}
#[test]
fn escaped_templates_survive_nested_and_serialized_surface_specs() {
    let input = json!({"root":{"text":"{{!state.value}}"},"spec":"{\"text\":\"{{!state.text}}\"}","uuid":"{{!uuid}}","mixed":"id {{state.id}}: {{!state.id}}","number":"{{state.count}}"});
    let result = template::resolve(&input, &json!({"id":"owned","count":3})).unwrap();
    assert_eq!(result["root"]["text"], "{{state.value}}");
    assert_eq!(result["spec"], "{\"text\":\"{{state.text}}\"}");
    assert_eq!(result["uuid"], "{{uuid}}");
    assert_eq!(result["mixed"], "id owned: {{state.id}}");
    assert_eq!(result["number"], 3);
    assert!(template::resolve(&json!("{{!state.bad"), &Value::Null).is_err());
    assert!(template::resolve(&json!("{{state.missing}}"), &Value::Null).is_err());
    assert!(validate(&scenario(
        json!([{"call":"echo","args":input,"capture":{}}])
    ))
    .iter()
    .any(|p| p.message.contains("id")));
    assert!(validate(&scenario(
        json!([{"call":"echo","args":{"literal":"{{!state.missing}}"}}])
    ))
    .is_empty());
}
#[test]
fn optional_operational_failures_are_reported_and_later_assertions_still_run() {
    let s = scenario(json!([
        {"best_effort":{"call":"unavailable","args":{}}},
        {"best_effort":{"call":"refusal","args":{}}},
        {"call":"echo","args":{"ok":true},"expect":{"ok":true}}
    ]));
    let mut f = Fixture::default();
    let report = execute(&s, &mut f);
    assert!(report.pass, "{}", report.detail);
    assert_eq!(f.calls.len(), 3);
    assert!(report.detail.contains("owned host unavailable"));
    assert!(report.detail.contains("forbidden"));
    let invalid =
        scenario(json!([{"best_effort":{"call":"echo","args":{"id":"{{state.missing}}"}}}]));
    let mut f = Fixture::default();
    assert!(!execute(&invalid, &mut f).pass);
    assert!(f.calls.is_empty());
    let asserted = json!({"wire_version":1,"id":"bad","description":"bad","tier":"a","steps":[{"best_effort":{"call":"echo","expect":{"ok":true}}}]});
    assert!(serde_json::from_value::<Scenario>(asserted).is_err());
}

#[test]
fn a_log_wait_uses_a_pre_mutation_cursor_and_capture_aware_case_insensitive_needles() {
    let s = scenario(json!([
        {"wait": {"log_cursor": {"capture": "before"}}},
        {"gesture": {"verb": "split"}, "capture": {"console": "$.focused"}},
        {"wait": {"log": {
            "category": "layout",
            "contains": "pane {{state.console}} console: ",
            "also_contains": ["search 'layout'", "levels info,warning,error"],
            "after": "{{state.before}}",
            "timeout_ms": 3000
        }}},
        {"call": "layout-service_close", "args": {"target": {"id": "{{state.console}}"}}}
    ]));
    let mut f = Fixture::default();
    let report = execute(&s, &mut f);
    assert!(report.pass, "{}", report.detail);
    assert_eq!(f.timeline, vec!["cursor", "gesture", "wait", "call"]);
    assert_eq!(f.calls[0].1, json!({"target": {"id": 7}}));
    let [WaitBody::Log { log }] = f.waits.as_slice() else {
        panic!("expected one resolved log wait: {:?}", f.waits);
    };
    assert_eq!(log.category, "layout");
    assert_eq!(log.contains, "pane 7 console: ");
    assert_eq!(
        log.also_contains,
        vec![
            "search 'layout'".to_string(),
            "levels info,warning,error".to_string()
        ]
    );
    assert_eq!(log.after.as_deref(), Some("2026-09-28T12:00:00.000Z"));
    assert_eq!(log.timeout_ms, 3000);
}

#[test]
fn refused_gesture_cannot_be_hidden_by_a_successful_result_capture() {
    let s = scenario(json!([
        {"gesture": {"verb": "split"}, "capture": {"console": "$.focused"}}
    ]));
    let mut f = Fixture {
        gesture_refused: true,
        ..Fixture::default()
    };
    let report = execute(&s, &mut f);
    assert!(!report.pass);
    assert!(report.detail.contains("action did not return ok=true"));
}
#[test]
fn store_predicate_pages_and_captures_a_real_payload_match() {
    let s = scenario(json!([
        {"store":{"schema_ref":"manuscript","where":[{"path":"$.payload.title","equals":"match"}],"max_rows":102},"capture":{"chosen":"$.item.id"}},
        {"call":"echo","args":{"id":"{{state.chosen}}"},"expect":{"fields":[{"path":"$.id","equals":"101"}]}}
    ]));
    assert!(validate(&s).is_empty());
    let mut f = Fixture::default();
    let report = execute(&s, &mut f);
    assert!(report.pass, "{}", report.detail);
    assert!(f
        .calls
        .iter()
        .any(|(v, a)| v.ends_with("list-items") && a["offset"] == 100));
    assert_eq!(f.calls.last().unwrap().1["id"], "101");
}
#[test]
fn store_scan_bound_and_truncated_payload_fail_instead_of_guessing() {
    let s = scenario(
        json!([{"store":{"schema_ref":"manuscript","where":[{"path":"$.payload.title","equals":"match"}],"max_rows":2}}]),
    );
    let mut f = Fixture::default();
    let report = execute(&s, &mut f);
    assert!(!report.pass);
    assert!(report.detail.contains("max_rows=2"));
    let mut f = Fixture {
        truncated: true,
        ..Default::default()
    };
    assert!(execute(&s, &mut f).detail.contains("truncated"));
    let s = scenario(json!([{"store":{"schema_ref":"manuscript","max_rows":0}}]));
    let mut f = Fixture::default();
    assert!(!execute(&s, &mut f).pass);
    assert!(f.calls.is_empty());
}

#[test]
fn resolved_empty_schema_is_rejected_before_a_store_read() {
    let s = scenario(json!([
        {"call":"echo","args":{"kind":""},"capture":{"kind":"$.kind"}},
        {"store":{"schema_ref":"{{state.kind}}"}}
    ]));
    let mut f = Fixture::default();
    let report = execute(&s, &mut f);
    assert!(!report.pass);
    assert!(report.detail.contains("resolved schema_ref"));
    assert_eq!(f.calls.len(), 1);
    assert_eq!(f.calls[0].0, "echo");
}

#[test]
fn expectations_compare_captured_json_without_reinterpreting_its_templates() {
    let rows = json!([{"name":"{{state.surface-owned}}"}]);
    let s = scenario(json!([
        {"call":"echo","args":{"rows":[{"name":"{{!state.surface-owned}}"}]},"capture":{"before":"$.rows"}},
        {"call":"echo","args":{"rows":[{"name":"{{!state.surface-owned}}"}]},"expect":{"fields":[{"path":"rows","equals":"{{state.before}}"}]}}
    ]));
    let mut f = Fixture::default();
    let report = execute(&s, &mut f);
    assert!(report.pass, "{}", report.detail);
    assert_eq!(f.calls[1].1["rows"], rows);
    let mut changed = s.clone();
    if let impress_scenario::Step::Call(step) = &mut changed.steps[1] {
        step.args = json!({"rows":[]});
    }
    assert!(!execute(&changed, &mut Fixture::default()).pass);
    let invalid = scenario(
        json!([{"call":"echo","expect":{"fields":[{"path":"rows","equals":"{{state.missing}}"}]}}]),
    );
    let mut f = Fixture::default();
    assert!(!execute(&invalid, &mut f).pass);
    assert!(f.calls.is_empty());
}

#[test]
fn required_cleanup_failure_fails_but_all_cleanup_is_attempted() {
    let mut s = scenario(json!([{"call":"echo","args":{"ok":true},"expect":{"ok":true}}]));
    s.teardown = serde_json::from_value(json!([
        {"call":"refusal","expect":{"ok":true}},
        {"call":"echo","args":{"cleanup":"second"}}
    ]))
    .unwrap();
    let mut f = Fixture::default();
    let report = execute(&s, &mut f);
    assert!(!report.pass, "{}", report.detail);
    assert!(report.detail.contains("teardown"));
    assert_eq!(f.calls.last().unwrap().1["cleanup"], "second");
    s.teardown[0] = serde_json::from_value(json!({"best_effort":{"call":"refusal"}})).unwrap();
    assert!(execute(&s, &mut Fixture::default()).pass);
}
