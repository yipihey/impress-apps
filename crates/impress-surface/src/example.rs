//! The worked example from `docs/plan-agent-surfaces.md` ("The vocabulary
//! (normative)"), loaded from the committed JSON file rather than built by hand
//! in Rust — so what ships as documentation (the `.surface.json`, which S8's
//! `surface_examples` verb and S9's demo capability both point agents at) is the
//! exact bytes this crate's own tests exercise, never a second, driftable copy.

use crate::spec::SurfaceSpec;

const SIGNAL_EXPLORER_JSON: &str = include_str!("../examples/signal-explorer.surface.json");
const PAPER_TRIAGE_JSON: &str = include_str!("../examples/paper-triage.surface.json");

/// The "Signal explorer" surface from the plan, parsed. Panics if the committed
/// JSON does not parse — which would mean the file and this crate's own types
/// have drifted, a build-time bug worth a hard failure rather than an `Option`
/// every caller has to handle.
pub fn example_signal_explorer() -> SurfaceSpec {
    serde_json::from_str(SIGNAL_EXPLORER_JSON)
        .unwrap_or_else(|e| panic!("examples/signal-explorer.surface.json failed to parse: {e}"))
}

/// The "Paper triage" surface (wave 5 V3): a `query` source over the user's
/// own unread papers (`publication` / `imbib/bibliography-entry`), a table of
/// title/year/first-author, and a row of buttons that star, flag or tag the
/// selected row through the kit `triage-service_*` verbs
/// (`crates/impress-store-service/src/triage_service.rs`) — present in the
/// app, the CLI and MCP alike, never a second definition of triage for
/// surfaces. See `docs/agent-surfaces.md`'s second worked example for the
/// loop an agent runs with it, and this crate's report for the one
/// vocabulary gap it hit (there is no template form that projects a
/// multi-id selection down to one id — see the module docs on `on_select`
/// below). Parses and panics the same way [`example_signal_explorer`] does.
pub fn example_paper_triage() -> SurfaceSpec {
    serde_json::from_str(PAPER_TRIAGE_JSON)
        .unwrap_or_else(|e| panic!("examples/paper-triage.surface.json failed to parse: {e}"))
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

    /// The `on_select` handler sets `state.selected` straight from
    /// `{{event.value}}`, with no indexing into it — `impress-surface`'s
    /// template language walks dotted object keys only (`template.rs`:
    /// `resolve_path` matches `Value::Object` and returns `MissingPath` for
    /// anything else, including an array), so there is no `{{event.value.0}}`
    /// form that would project a multi-id selection down to one id. This
    /// surface is therefore honest about being single-select: it works only
    /// if the host's `select` event on `papers-table` carries the clicked
    /// row's id directly as `event.value` (a string), not wrapped in an
    /// array. A host that emits an array of ids for every table selection
    /// (as ADR-0031's pane channels do for a published selection) cannot
    /// drive this surface's buttons without a template indexing form the
    /// vocabulary deliberately does not have — see this crate's (V3) report.
    #[test]
    fn paper_triage_parses_and_validates_clean() {
        let spec = example_paper_triage();
        assert_eq!(spec.surface, "1.0");
        assert_eq!(spec.name, "Paper triage");
        let problems = validate(&spec);
        assert!(problems.is_empty(), "unexpected problems: {problems:?}");
    }
}
