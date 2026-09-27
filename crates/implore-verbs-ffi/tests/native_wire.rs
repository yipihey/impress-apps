use implore_verbs_ffi::{dispatch_verb_async, install_native_host, ImploreVerbHost, NativeReply};
use serde_json::{json, Value};

struct Fixture;

#[async_trait::async_trait]
impl ImploreVerbHost for Fixture {
    async fn invoke(&self, method: String, _args_json: String) -> NativeReply {
        let (status, value) = match method.as_str() {
            "plot_series" => (200, json!({"svg":"<svg>energy</svg>"})),
            "rg_slice_raw" => (200, json!({"values":[1.0,2.0],"mean":1.5})),
            "rg_statistics" => (200, json!({"mean":1.5,"std":0.5})),
            "rg_slice_png" => (200, json!({"png_base64":"iVBORw0K"})),
            "plot_histogram" => (400, json!({"error":"No RG dataset loaded"})),
            _ => (404, json!({"error":"unknown fixture method"})),
        };
        NativeReply {
            status,
            body_json: value.to_string(),
        }
    }
}

#[tokio::test]
async fn async_dispatch_preserves_values_and_reports_native_refusal() {
    install_native_host(Box::new(Fixture));
    let caller = r#"{"kind":"app","name":"implore"}"#;
    for (name, args, expected) in [
        (
            "plot-series",
            r#"{"series":["energy"]}"#,
            "<svg>energy</svg>",
        ),
        ("rg-slice-raw", r#"{"params_json":"{}"}"#, "values"),
        ("rg-statistics", r#"{"params_json":"{}"}"#, "mean"),
        ("rg-slice-png", r#"{"format":"base64"}"#, "png_base64"),
    ] {
        let result = dispatch_verb_async(
            format!("implore-service_{name}"),
            args.into(),
            caller.into(),
        )
        .await;
        assert_eq!(result.status, 200, "{name}: {}", result.body_json);
        let body: Value = serde_json::from_str(&result.body_json).unwrap();
        assert!(
            body.as_str().is_some_and(|s| s.contains(expected)),
            "{name}: {body}"
        );
    }

    let refused = dispatch_verb_async(
        "implore-service_plot-histogram".into(),
        r#"{"quantity":"velocity_magnitude"}"#.into(),
        caller.into(),
    )
    .await;
    assert_eq!(refused.status, 400);
    let body: Value = serde_json::from_str(&refused.body_json).unwrap();
    assert_eq!(body["ok"], false);
    assert_eq!(body["code"], "invalid-argument");
    assert!(body["message"].as_str().unwrap().contains("No RG dataset"));
}
