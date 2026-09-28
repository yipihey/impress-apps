//! The pre-P5b adapter surface still routes by its canonical descriptor name.
//! This is transport parity, not a substitute for the hosted native fixtures:
//! the owned HTTP server proves every retired forwarder reaches its owner,
//! preserves a successful value, and preserves a business refusal unchanged.

use impress_service_core::pipeline::{self, Call};
use impress_service_core::VerbDescriptor;
use serde_json::{json, Value};

#[tokio::test]
async fn every_retired_adapter_method_routes_without_a_second_schema_or_fallback() {
    impress_capabilities::force_link();
    let fixture: Value =
        serde_json::from_str(include_str!("fixtures/transport-before-p5b.json")).unwrap();
    let names = fixture["verbs"].as_array().unwrap();
    // The plan's 200 counted client/helpers as methods. At the retirement
    // boundary there are 185 actual trait implementations (including W3's
    // retention verb): 118 imbib, 37 imprint, 20 implore, 10 impart.
    assert_eq!(names.len(), 185);

    let mut server = mockito::Server::new_async().await;
    let mut previous = Vec::new();
    for app in ["IMBIB", "IMPRINT", "IMPLORE", "IMPART"] {
        for (key, value) in [
            (format!("IMPRESS_{app}_HTTP_URL"), server.url()),
            (format!("{app}_BACKEND"), "http".into()),
        ] {
            previous.push((key.clone(), std::env::var_os(&key)));
            std::env::set_var(key, value);
        }
    }
    let status = server
        .mock("GET", "/api/status")
        .with_status(200)
        .expect(4)
        .create_async()
        .await;
    // An app client never falls back to a store; even this test's explicit
    // scratch-store environment cannot mask a missing remote request.
    impress_app_transport::install(false);
    for name in names.iter().map(|name| name.as_str().unwrap()) {
        let descriptor = VerbDescriptor::find(name).unwrap_or_else(|| panic!("lost {name}"));
        assert!(pipeline::reachability::owner_of(name).is_some(), "{name}");
        let path = format!("/api/verb/{name}");
        let result = json!({"ok":true,"transport_proof":name});
        let positive = server
            .mock("POST", path.as_str())
            .match_body(mockito::Matcher::Json(json!({})))
            .with_status(200)
            .with_body(result.to_string())
            .expect(1)
            .create_async()
            .await;
        assert_eq!(
            pipeline::invoke(descriptor, Call::person(json!({})))
                .await
                .unwrap(),
            result,
            "{name} did not reach its app"
        );
        positive.assert_async().await;
        positive.remove_async().await;

        let refusal = json!({"ok":false,"code":"not-found","message":name,"wire_version":1});
        let negative = server
            .mock("POST", path.as_str())
            .with_status(404)
            .with_body(refusal.to_string())
            .expect(1)
            .create_async()
            .await;
        assert_eq!(
            pipeline::invoke(descriptor, Call::person(json!({})))
                .await
                .unwrap(),
            refusal,
            "{name} swallowed a remote refusal"
        );
        negative.assert_async().await;
        negative.remove_async().await;
    }
    status.assert_async().await;
    for (key, value) in previous {
        if let Some(value) = value {
            std::env::set_var(key, value);
        } else {
            std::env::remove_var(key);
        }
    }
}
