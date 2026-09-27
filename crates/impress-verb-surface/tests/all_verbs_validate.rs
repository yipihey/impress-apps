//! Completeness statement 1 (plan-auto-gui-and-self-docs.md § "What complete
//! means"): `verb_surface` returns a valid `SurfaceSpec` for every verb in
//! the linked inventory. This test links every service crate except
//! `capabilities-service` itself (see `Cargo.toml`'s comment on the
//! dev-dependency cycle that would otherwise create), so it proves the
//! property over the ~433-verb inventory minus the 3 this plan adds.

use impress_service_core::VerbDescriptor;
use impress_surface::validate;

#[test]
fn every_linked_verb_gets_a_form_that_validates_with_zero_errors() {
    impress_capabilities::force_link();

    let mut count = 0usize;
    let mut failures: Vec<String> = Vec::new();

    for verb in VerbDescriptor::iter() {
        count += 1;
        let spec = impress_verb_surface::verb_surface(verb);
        let problems = validate::validate(&spec);
        let errors: Vec<_> = problems.into_iter().filter(|p| p.is_error()).collect();
        if !errors.is_empty() {
            failures.push(format!("{}: {:?}", verb.name, errors));
        }
    }

    assert!(
        count > 300,
        "expected the full inventory to be linked, saw {count} verbs"
    );
    assert!(
        failures.is_empty(),
        "{} of {count} verbs produced an invalid surface:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn the_catalogue_itself_validates() {
    let spec = impress_verb_surface::catalogue();
    let problems = validate::validate(&spec);
    assert!(problems.iter().all(|p| !p.is_error()), "{problems:?}");
}

#[test]
fn print_form_class_counts() {
    impress_capabilities::force_link();
    let mut a = 0usize; // every arg maps to a typed field
    let mut b = 0usize; // at least one raw-json field
    let mut total = 0usize;
    for verb in VerbDescriptor::iter() {
        total += 1;
        let schema = (verb.input_schema)();
        let mut all_typed = true;
        if let Some(props) = schema.get("properties").and_then(|p| p.as_object()) {
            for prop in props.values() {
                if impress_verb_surface::argument_is_raw_json(prop) {
                    all_typed = false;
                }
            }
        }
        if all_typed {
            a += 1
        } else {
            b += 1
        }
    }
    eprintln!("VERBS total={total} class_a={a} class_b={b}");
}
