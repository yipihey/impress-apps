//! The policy layer's review point (ADR-0034 D3, plan-verb-pipeline
//! § Policy): with a review policy configured, a mutating verb from an agent
//! is queued — answered `review-pending`, not run — and the same verb from
//! the person runs. Its own test binary because the policy is
//! process-global.

use std::sync::{Arc, Mutex};

use impress_core::query::ItemQuery;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_service_core::pipeline::policy::{self, ReviewAgents, ReviewQueue};
use impress_service_core::pipeline::{self, Call, CallerIdentity};
use impress_service_core::{Refusal, VerbDescriptor};

// The whole linked inventory: a test binary links only what it names.
#[allow(unused_imports)]
use impress_capabilities as _force_link_inventory;
use serde_json::{json, Value};

struct Queue(Mutex<Vec<(String, String)>>);

impl ReviewQueue for Queue {
    fn enqueue(
        &self,
        caller: &CallerIdentity,
        verb: &VerbDescriptor,
        _args: &Value,
    ) -> Result<String, Refusal> {
        let id = format!("review-{}", self.0.lock().unwrap().len() + 1);
        self.0
            .lock()
            .unwrap()
            .push((caller.to_string(), verb.name.to_string()));
        Ok(id)
    }
}

fn run(store: &Arc<SqliteItemStore>, caller: CallerIdentity, verb: &str, args: Value) -> Value {
    let descriptor = VerbDescriptor::find(verb).unwrap_or_else(|| panic!("{verb} is linked"));
    impress_service_core::runtime::block_on(pipeline::invoke_on(
        store.clone(),
        descriptor,
        Call::new(caller, args),
    ))
    .unwrap_or_else(|e| panic!("{verb}: {e}"))
}

#[test]
fn a_mutating_verb_from_an_agent_is_queued_and_from_the_person_runs() {
    policy::install(Arc::new(ReviewAgents::WRITES));
    let queue = Arc::new(Queue(Mutex::new(Vec::new())));
    policy::install_queue(queue.clone());
    let store = Arc::new(SqliteItemStore::open_in_memory().expect("store"));

    let agent = run(
        &store,
        CallerIdentity::agent("mcp:test"),
        "collection-service_create",
        json!({ "binding": "generic", "name": "queued", "kind_scope": "any" }),
    );
    assert_eq!(agent["ok"], false, "{agent}");
    assert_eq!(agent["code"], "review-pending");
    assert_eq!(agent["surface_id"], "review-1");
    assert_eq!(agent["verb"], "collection-service_create");
    assert_eq!(
        queue.0.lock().unwrap().as_slice(),
        &[(
            "agent:mcp:test".to_string(),
            "collection-service_create".to_string()
        )]
    );
    let collections = store
        .count(&ItemQuery {
            schema: Some("collection".into()),
            ..Default::default()
        })
        .expect("count");
    assert_eq!(collections, 0, "nothing was written");

    let read = run(
        &store,
        CallerIdentity::agent("mcp:test"),
        "collection-service_tree",
        json!({ "binding": "generic" }),
    );
    assert!(
        read.get("code").and_then(Value::as_str) != Some("review-pending"),
        "a read-only verb is never reviewed: {read}"
    );

    let person = run(
        &store,
        CallerIdentity::Person,
        "collection-service_create",
        json!({ "binding": "generic", "name": "made", "kind_scope": "any" }),
    );
    assert_eq!(person["ok"], true, "{person}");
    assert_eq!(
        queue.0.lock().unwrap().len(),
        1,
        "the person was not queued"
    );
}
