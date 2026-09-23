//! The worked example from `docs/plan-agent-surfaces.md` ("The vocabulary
//! (normative)"), loaded from the committed JSON file rather than built by hand
//! in Rust — so what ships as documentation (the `.surface.json`, which S8's
//! `surface_examples` verb and S9's demo capability both point agents at) is the
//! exact bytes this crate's own tests exercise, never a second, driftable copy.

use crate::spec::SurfaceSpec;

const SIGNAL_EXPLORER_JSON: &str = include_str!("../examples/signal-explorer.surface.json");

/// The "Signal explorer" surface from the plan, parsed. Panics if the committed
/// JSON does not parse — which would mean the file and this crate's own types
/// have drifted, a build-time bug worth a hard failure rather than an `Option`
/// every caller has to handle.
pub fn example_signal_explorer() -> SurfaceSpec {
    serde_json::from_str(SIGNAL_EXPLORER_JSON)
        .unwrap_or_else(|e| panic!("examples/signal-explorer.surface.json failed to parse: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::validate::validate;

    #[test]
    fn the_worked_example_parses_and_validates_clean() {
        let spec = example_signal_explorer();
        assert_eq!(spec.surface, "1.0");
        assert_eq!(spec.name, "Signal explorer");
        let problems = validate(&spec);
        assert!(problems.is_empty(), "unexpected problems: {problems:?}");
    }
}
