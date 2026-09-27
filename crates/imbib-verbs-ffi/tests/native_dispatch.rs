use imbib_verbs_ffi::{
    dispatch_verb_async, initialize_verb_store, register_native_backend, ImbibNativeCallbacks,
    NativeCallResult,
};

struct Fixture {
    status: u16,
    json: &'static str,
}

#[async_trait::async_trait]
impl ImbibNativeCallbacks for Fixture {
    async fn invoke(&self, method: String, args_json: String) -> NativeCallResult {
        assert_eq!(method, "get_notes");
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&args_json).unwrap()["cite_key"],
            "Key2026"
        );
        NativeCallResult {
            status: self.status,
            body_json: self.json.into(),
        }
    }
}

#[tokio::test]
async fn pipeline_preserves_native_value_and_refusal() {
    let root = tempfile::tempdir().unwrap();
    initialize_verb_store(root.path().join("impress.sqlite").display().to_string()).unwrap();
    register_native_backend(Box::new(Fixture {
        status: 200,
        json: r#""A saved note""#,
    }))
    .unwrap();
    let call = || {
        dispatch_verb_async(
            "imbib-app-service_get-notes".into(),
            r#"{"cite_key":"Key2026"}"#.into(),
            r#"{"kind":"app","name":"imbib"}"#.into(),
        )
    };
    let success = call().await;
    assert_eq!(success.status, 200, "{}", success.body_json);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&success.body_json).unwrap(),
        "A saved note"
    );

    register_native_backend(Box::new(Fixture {
        status: 404,
        json: r#"{"code":"not-found","message":"missing paper"}"#,
    }))
    .unwrap();
    let refused = call().await;
    assert_eq!(refused.status, 404, "{}", refused.body_json);
    let body: serde_json::Value = serde_json::from_str(&refused.body_json).unwrap();
    assert_eq!(body["ok"], false);
    assert_eq!(body["code"], "not-found");
}
