//! koine plan-koine-trust TR-D11 over impress's inventory: a verb that
//! reaches out of the process is `external`, so its egress is visible to the
//! consent policy and to MCP's `openWorldHint`.

use impress_service_core::VerbDescriptor;

#[test]
fn a_verb_that_reaches_out_is_external() {
    impress_capabilities::force_link();
    let problems = impress_service_core::report::reach_class_disagreements(VerbDescriptor::iter());
    assert!(
        problems.is_empty(),
        "reach and class disagree:\n- {}",
        problems.join("\n- ")
    );
}
