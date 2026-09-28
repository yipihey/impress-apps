//! Execute every headless example against owned scratch state. Setup and
//! readback are shared with the effects-spy binary; both verify JSON Schemas
//! and the example's expected result. An explicit Tier B example never runs
//! here, even when its verb also has a headless implementation.

use impress_service_core::pipeline::CallerIdentity;
use impress_service_core::report::tier_a::{is_tier_a, run_linked_example_with_args, Outcome};
use impress_service_core::{ExampleTier, VerbDescriptor};

#[path = "support/example_fixtures.rs"]
mod example_fixtures;

fn verbs() -> Vec<&'static VerbDescriptor> {
    impress_capabilities::force_link();
    let mut out: Vec<_> = VerbDescriptor::iter().collect();
    out.sort_by_key(|v| v.name);
    out
}

#[tokio::test]
async fn every_tier_a_example_passes() {
    let store = example_fixtures::store();
    let verbs = verbs();
    let mut ran = 0;
    let mut with_examples = 0;
    let mut failures = Vec::new();
    let eligible = verbs.iter().filter(|v| is_tier_a(v)).count();
    for verb in verbs.into_iter().filter(|v| is_tier_a(v)) {
        let examples: Vec<_> = verb
            .examples
            .iter()
            .filter(|ex| ex.tier == ExampleTier::A)
            .collect();
        if !examples.is_empty() {
            with_examples += 1;
        }
        for example in examples {
            let args = match example_fixtures::prepare(verb, example, &store).await {
                Ok(args) => args,
                Err(error) => {
                    failures.push(format!("{} / {} fixture: {error}", verb.name, example.name));
                    continue;
                }
            };
            ran += 1;
            match run_linked_example_with_args(
                verb,
                example,
                args.clone(),
                CallerIdentity::system("tier-a"),
                example_fixtures::validate_schema,
            )
            .await
            {
                Outcome::Failed(error) => failures.push(error),
                Outcome::Passed { result } => {
                    if let Err(error) =
                        example_fixtures::verify(verb, example, &store, &args, &result)
                    {
                        failures.push(format!(
                            "{} / {} readback: {error}",
                            verb.name, example.name
                        ));
                    }
                }
            }
        }
    }
    eprintln!(
        "Tier A: {eligible} headless verbs, {with_examples} with examples, {ran} examples ran"
    );
    assert!(
        failures.is_empty(),
        "{} Tier A example(s) failed:\n- {}",
        failures.len(),
        failures.join("\n- ")
    );
}
