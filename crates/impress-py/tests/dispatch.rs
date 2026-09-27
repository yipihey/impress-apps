//! Rust tests of the underlying functions `impress_py` exposes to Python
//! (plan-verb-pipeline-and-transport.md § P6's proof line names
//! `imbib-text-service_decode-latex`) — no Python interpreter involved.

use impress::{call_local, list_verb_infos};
use serde_json::json;

#[test]
fn list_verb_infos_includes_decode_latex() {
    let verbs = list_verb_infos();
    let decode_latex = verbs
        .iter()
        .find(|v| v.name == "imbib-text-service_decode-latex")
        .expect("decode-latex in the linked inventory");
    assert_eq!(decode_latex.service, "imbib-text-service");
    assert!(!decode_latex.description.is_empty());
    assert!(decode_latex.input_schema.is_object());
    assert!(!verbs.is_empty());
}

#[test]
fn call_local_runs_decode_latex_through_the_pipeline() {
    let result = call_local(
        "imbib-text-service_decode-latex",
        json!({ "input": "Caf\\'{e}" }),
    )
    .expect("decode-latex succeeds");
    assert_eq!(result.as_str(), Some("Café"));
}

#[test]
fn call_local_unknown_verb_is_an_error() {
    let error = call_local("does-not-exist_no-such-verb", json!({})).unwrap_err();
    assert!(
        error.contains("no such verb"),
        "unexpected message: {error}"
    );
}
