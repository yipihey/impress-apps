//! This repository's stored scenario documents (`crates/*/scenarios/*.json`):
//! each one parses and validates, and every Tier A one runs headlessly
//! against a scratch store. The scenario verbs and runner are koine's
//! (`impress-scenario-service`, docs/plan-koine-kit-moves.md KM4); this test
//! stays here because the documents call impress's verbs, so it links the
//! whole inventory (`force_link`) and runs on the SQLite scratch store that
//! `force_link` installs, as the scenario verbs do in impress's hosts. A Tier
//! B document is validated, not run (it needs a live app).

use std::path::{Path, PathBuf};

use impress_scenario::{validate, Scenario, Tier};
use impress_scenario_service::TierACaller;

/// The repo root, from this crate's manifest dir.
fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("workspace root exists")
}

/// Every `scenarios/*.json` file directly under any `crates/*/scenarios/`
/// directory, sorted for a stable test order.
fn every_scenario_document() -> Vec<PathBuf> {
    let crates_dir = repo_root().join("crates");
    let mut found = Vec::new();
    for entry in std::fs::read_dir(&crates_dir).expect("crates/ exists") {
        let entry = entry.expect("readable crates/ entry");
        let scenarios_dir = entry.path().join("scenarios");
        if !scenarios_dir.is_dir() {
            continue;
        }
        for doc in std::fs::read_dir(&scenarios_dir).expect("readable scenarios/ dir") {
            let doc = doc.expect("readable scenarios/ entry");
            if doc.path().extension().and_then(|e| e.to_str()) == Some("json") {
                found.push(doc.path());
            }
        }
    }
    found.sort();
    found
}

fn load(path: &Path) -> Scenario {
    let text =
        std::fs::read_to_string(path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|e| panic!("{} is not a valid scenario document: {e}", path.display()))
}

#[test]
fn every_stored_scenario_document_is_structurally_valid() {
    let docs = every_scenario_document();
    assert!(
        !docs.is_empty(),
        "expected at least one scenarios/*.json document under crates/*/scenarios/ (S2)"
    );
    for path in &docs {
        let scenario = load(path);
        let problems = validate::validate(&scenario);
        assert!(problems.is_empty(), "{}: {problems:?}", path.display());
        assert_eq!(
            scenario.wire_version,
            1,
            "{}: expected wire_version 1",
            path.display()
        );
    }
}

#[tokio::test]
async fn every_tier_a_document_runs_headlessly() {
    let docs = every_scenario_document();
    let mut ran = 0;
    for path in &docs {
        let scenario = load(path);
        if scenario.tier != Tier::A {
            continue;
        }
        ran += 1;
        impress_capabilities::force_link();
        let mut caller = TierACaller::open().expect("open scratch store");
        let result = impress_scenario::run(&scenario, &mut caller).await;
        assert!(
            result.pass && !result.skipped,
            "{}: `{}` did not pass: {}",
            path.display(),
            scenario.id,
            result.detail
        );
    }
    // Not an error for zero Tier A documents to exist today (S2 converted
    // Tier B catalogues) — this loop just proves any that do exist actually
    // pass headlessly, the same way `proof_scenarios.rs` does for S1's four.
    let _ = ran;
}
