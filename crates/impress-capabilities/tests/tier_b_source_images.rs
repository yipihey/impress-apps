//! Explicit macOS subprocess proof. PDFKit receives only the synthetic PDF
//! installed in this process's owned scratch root; no GUI app is launched.
#![cfg(target_os = "macos")]

use impress_service_core::pipeline::{self, Call, CallerIdentity};
use impress_service_core::report::tier_a::{run_linked_tier_b_example_with_args, Outcome};
use impress_service_core::{ExampleTier, VerbDescriptor};

#[path = "support/example_fixtures.rs"]
mod example_fixtures;

#[tokio::test]
#[ignore = "explicit isolated PDFKit subprocess proof; run with --ignored on macOS"]
async fn source_image_examples_render_owned_pdf() {
    impress_capabilities::force_link();
    let store = example_fixtures::store();
    let mut ran = 0;
    for name in [
        "source-service_get-page-image",
        "source-service_get-figure-image",
    ] {
        let verb = VerbDescriptor::find(name).expect("source image verb linked");
        for example in verb.examples.iter().filter(|ex| ex.tier == ExampleTier::B) {
            let args = example_fixtures::prepare(verb, example, &store)
                .await
                .expect("owned fixture");
            let outcome = run_linked_tier_b_example_with_args(
                verb,
                example,
                args.clone(),
                CallerIdentity::system("g3-owned-pdfkit"),
                |args, caller| pipeline::invoke(verb, Call::new(caller, args)),
                example_fixtures::validate_schema,
            )
            .await;
            let Outcome::Passed { result } = outcome else {
                panic!("{name} / {}: {outcome:?}", example.name);
            };
            example_fixtures::verify(verb, example, &store, &args, &result)
                .expect("image readback");
            assert!(
                result["_mcp_content"]
                    .as_array()
                    .expect("image content")
                    .iter()
                    .any(|content| {
                        content["type"] == "image"
                            && content["mimeType"] == "image/png"
                            && content["data"]
                                .as_str()
                                .is_some_and(|data| data.starts_with("iVBORw0KGgo"))
                    }),
                "missing PNG signature: {name}"
            );
            ran += 1;
        }
    }
    assert_eq!(ran, 2, "both image examples must execute");
}
