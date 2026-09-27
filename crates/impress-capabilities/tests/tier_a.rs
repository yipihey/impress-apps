//! Runs every Tier A-eligible verb's examples end to end (plan
//! auto-gui-and-self-docs.md, work package G3; § Examples as tests).
//!
//! The generic execution and `expect`-shape check live in
//! `impress_service_core::report::tier_a` (a leaf module with no store
//! dependency, shared by every service). This file supplies the one thing
//! that module deliberately does not own: a store for the linked handlers to
//! run against. Until P2 lands a per-call store override, every example in
//! this process shares the one scratch store `tests/effects.rs` installs —
//! same limitation, same reason (see that file's module docs and this
//! module's own doc on [`impress_service_core::report::tier_a`]).
//!
//! `cargo test -p impress-capabilities --test tier_a` — no app, no network,
//! no device.

use std::fs;
use std::sync::Arc;

use impress_core::sqlite_store::SqliteItemStore;
use impress_service_core::report::tier_a::{is_tier_a, run_all};
use impress_service_core::VerbDescriptor;

fn scratch_store() -> Arc<SqliteItemStore> {
    static STORE: std::sync::OnceLock<Arc<SqliteItemStore>> = std::sync::OnceLock::new();
    STORE
        .get_or_init(|| {
            // A store of this test binary's own, distinct from
            // `tests/effects.rs`'s (a different process, a different temp
            // dir) — the two test binaries never share one.
            let dir = std::env::temp_dir().join(format!("impress-tier-a-{}", std::process::id()));
            fs::create_dir_all(&dir).expect("scratch dir");
            let path = dir.join("impress.sqlite");
            std::env::set_var("IMPRESS_STORE_PATH", &path);
            std::env::set_var("IMBIB_STORE_PATH", &path);
            std::env::set_var("HOME", &dir);
            let store = Arc::new(SqliteItemStore::open(&path).expect("open scratch store"));
            impress_store_service::install_store(store.clone()).expect("install scratch store");
            store
        })
        .clone()
}

fn verbs() -> Vec<&'static VerbDescriptor> {
    impress_capabilities::force_link();
    let mut out: Vec<_> = VerbDescriptor::iter().collect();
    out.sort_by_key(|v| v.name);
    out
}

#[tokio::test]
async fn every_tier_a_example_passes() {
    let _store = scratch_store();
    let verbs = verbs();

    let eligible: usize = verbs.iter().filter(|v| is_tier_a(v)).count();
    let with_examples: usize = verbs
        .iter()
        .filter(|v| is_tier_a(v) && !v.examples.is_empty())
        .count();

    let results = run_all(verbs.iter().copied()).await;
    let ran = results.len();
    let failures: Vec<String> = results
        .into_iter()
        .filter(|r| !r.outcome.is_pass())
        .map(|r| match r.outcome {
            impress_service_core::report::tier_a::Outcome::Failed(msg) => msg,
            impress_service_core::report::tier_a::Outcome::Passed { .. } => unreachable!(),
        })
        .collect();

    eprintln!(
        "Tier A: {eligible} verbs are headless, {with_examples} of them have examples, \
         {ran} examples ran"
    );

    assert!(
        failures.is_empty(),
        "{} Tier A example(s) failed:\n- {}",
        failures.len(),
        failures.join("\n- ")
    );
}
