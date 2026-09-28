//! The scenario-run verb has broad Tier B reach; this example explicitly
//! selects its in-memory Tier A interpreter and never opens a host socket.
#![cfg(feature = "scenario")]
use impress_service_core::{
    pipeline::{self, Call, CallerIdentity},
    report::tier_a::{run_linked_tier_b_example_with_args, Outcome},
    ExampleTier, VerbDescriptor,
};
#[path = "support/example_fixtures.rs"]
mod example_fixtures;

#[tokio::test]
async fn external_runner_example_can_select_owned_scratch_execution() {
    impress_capabilities::force_link();
    let verb = VerbDescriptor::find("impress-scenario-service_scenario-run")
        .expect("scenario runner linked");
    let example = verb
        .examples
        .iter()
        .find(|ex| ex.name == "run-owned-noop")
        .expect("stored run example");
    assert_eq!(example.tier, ExampleTier::B);
    let store = example_fixtures::store();
    let args = example_fixtures::prepare(verb, example, &store)
        .await
        .expect("owned scenario fixture");
    assert_eq!(args["tier"], "a", "this proof must never dial an app");
    assert!(args.get("base_url").is_none());
    let outcome = run_linked_tier_b_example_with_args(
        verb,
        example,
        args.clone(),
        CallerIdentity::system("g3-scratch-scenario"),
        |args, caller| pipeline::invoke(verb, Call::new(caller, args)),
        example_fixtures::validate_schema,
    )
    .await;
    let Outcome::Passed { result } = outcome else {
        panic!("scenario-run example: {outcome:?}");
    };
    example_fixtures::verify(verb, example, &store, &args, &result)
        .expect("completed stored scenario");
}

#[tokio::test]
async fn selftest_examples_select_headless_catalogues() {
    impress_capabilities::force_link();
    // Establish the owned process paths before any linked catalogue can initialize.
    let _store = example_fixtures::store();
    for name in [
        "layout-selftest-service_run-selftest",
        "surface-selftest-service_run-selftest",
        "imprint-selftest-service_run-selftest",
    ] {
        let verb = VerbDescriptor::find(name).expect("selftest linked");
        let example = verb
            .examples
            .iter()
            .find(|ex| ex.name == "owned-headless-catalogue")
            .expect("headless catalogue example");
        let args = example.args_value();
        assert_eq!(args["tier"], "a", "this proof must never dial an app");
        let outcome = run_linked_tier_b_example_with_args(
            verb,
            example,
            args,
            CallerIdentity::system("g3-scratch-selftest"),
            |args, caller| pipeline::invoke(verb, Call::new(caller, args)),
            example_fixtures::validate_schema,
        )
        .await;
        let Outcome::Passed { result } = outcome else {
            panic!("{name}: {outcome:?}");
        };
        assert!(result["total"].as_u64().is_some_and(|count| count > 0));
        assert_eq!(result["passed"], result["total"]);
    }
}
