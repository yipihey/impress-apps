//! The per-call overhead of the chain on the hottest verbs (plan-verb-pipeline
//! P2's bench; ADR-0034 D2's budget: the span ≤ 5 µs, the whole chain under
//! ~20 µs for a read-only call).
//!
//! Ignored by default — timings mean nothing in a debug build with the rest
//! of the suite running. Run it alone, in release:
//!
//! ```text
//! cargo test -p impress-capabilities --release --test pipeline_bench -- --ignored --nocapture
//! ```
//!
//! For each verb it times the raw handler (the one measurement that calls
//! `descriptor.handler` beside the chain, which is why this file is on the
//! call-site test's allow list) and the same call through
//! `pipeline::invoke`, and prints the difference per call.

use std::sync::Arc;
use std::time::Instant;

use impress_core::sqlite_store::SqliteItemStore;
use impress_service_core::pipeline::{self, Call, CallerIdentity};
use impress_service_core::VerbDescriptor;

// The whole linked inventory: a test binary links only what it names.
#[allow(unused_imports)]
use impress_capabilities as _force_link_inventory;
use serde_json::{json, Value};

const ROUNDS: u32 = 2000;

fn bench(name: &'static str, args: Value, store: &Arc<SqliteItemStore>) -> (f64, f64) {
    let verb = VerbDescriptor::find(name).unwrap_or_else(|| panic!("{name} is linked"));
    fn rt<F: std::future::Future>(f: F) -> F::Output {
        impress_service_core::runtime::block_on(f)
    }
    // Warm both paths (the store's first open, the schema's first build).
    for _ in 0..50 {
        let _ = rt(pipeline::invoke_on(
            store.clone(),
            verb,
            Call::new(CallerIdentity::agent("bench"), args.clone()),
        ));
        let _ = rt((verb.handler)(args.clone()));
    }
    let raw_start = Instant::now();
    for _ in 0..ROUNDS {
        let _ = rt(pipeline::context::scope(
            Arc::new(pipeline::CallContext {
                call_id: String::new(),
                trace_id: String::new(),
                parent_call: None,
                caller: CallerIdentity::agent("bench"),
                verb: name,
                store_override: Some(store.clone()),
            }),
            (verb.handler)(args.clone()),
        ));
    }
    let raw = raw_start.elapsed().as_secs_f64() * 1e6 / f64::from(ROUNDS);
    let chain_start = Instant::now();
    for _ in 0..ROUNDS {
        let _ = rt(pipeline::invoke_on(
            store.clone(),
            verb,
            Call::new(CallerIdentity::agent("bench"), args.clone()),
        ));
    }
    let chain = chain_start.elapsed().as_secs_f64() * 1e6 / f64::from(ROUNDS);
    (raw, chain)
}

#[test]
#[ignore = "a timing; run alone in release with --ignored --nocapture"]
fn per_call_overhead_of_the_chain() {
    let store = Arc::new(SqliteItemStore::open_in_memory().expect("store"));
    let layout_args = json!({ "app_id": "bench", "device": "bench-device" });
    let pane_args =
        json!({ "app_id": "bench", "device": "bench-device", "target": {"focused": true} });
    let cases: Vec<(&'static str, Value)> = vec![
        (
            "imbib-text-service_decode-latex",
            json!({ "input": "Caf\\'{e} and Schr\\\"{o}dinger" }),
        ),
        (
            "surface-demo-service_series",
            json!({ "freq": 1.5, "n": 64 }),
        ),
        ("layout-service_get-layout", layout_args),
        ("layout-service_get-pane", pane_args),
        (
            "store-query-service_list-items",
            json!({ "schema_ref": "collection", "limit": 10, "offset": 0 }),
        ),
    ];
    println!(
        "\n{:<40} {:>10} {:>10} {:>10}",
        "verb", "raw µs", "chain µs", "delta µs"
    );
    let mut worst = 0.0f64;
    for (name, args) in cases {
        let (raw, chain) = bench(name, args, &store);
        let delta = chain - raw;
        worst = worst.max(delta);
        println!("{name:<40} {raw:>10.2} {chain:>10.2} {delta:>10.2}");
    }
    println!("worst overhead: {worst:.2} µs per call (budget: ~20 µs for a read-only call)");
}
