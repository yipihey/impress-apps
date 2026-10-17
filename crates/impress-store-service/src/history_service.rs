//! `HistoryService` — the self-reflective layer's read (and controlled
//! write) side over the call log, now koine's (`koine_notebook::history`,
//! docs/plan-koine-kit-moves.md KM10): `calls`, `why`, `trace`, `replay`,
//! `save_macro`, `propose_workflows` and `health` over the store port, read
//! from the rows koine-notebook's sink writes (this crate's [`crate::audit`]
//! installs it). This module re-exports it so every
//! `impress_store_service::history_service` path still resolves; the tests
//! below keep proving it over SQLite.

pub use koine_notebook::history::*;

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use chrono::{SecondsFormat, Utc};
    use impress_core::item::{ActorKind, Item, Priority, Visibility};
    use impress_core::sqlite_store::SqliteItemStore;
    use impress_core::store::ItemStore;
    use impress_service_core::pipeline;
    use impress_service_core::refusal::codes;
    use serde_json::{json, Value};

    use super::*;

    use impress_core::item::Value as CoreValue;
    use impress_core::store::FieldMutation;
    use impress_service_core::pipeline::Call as PipeCall;
    use impress_service_core::VerbDescriptor;

    fn item(store: &SqliteItemStore) -> uuid::Uuid {
        crate::test_support::make_item(store, "manuscript")
            .parse()
            .unwrap()
    }

    fn paper(store: &SqliteItemStore) -> uuid::Uuid {
        let now = Utc::now();
        let id = uuid::Uuid::new_v4();
        store
            .insert(Item {
                id,
                schema: impress_core::schema::refs::IMBIB_BIBLIOGRAPHY_ENTRY,
                payload: Default::default(),
                created: now,
                modified: now,
                author: "test".into(),
                author_kind: ActorKind::Human,
                logical_clock: 0,
                origin: None,
                canonical_id: None,
                tags: vec![],
                flag: None,
                is_read: false,
                is_starred: false,
                priority: Priority::None,
                visibility: Visibility::Private,
                message_type: None,
                produced_by: None,
                version: None,
                batch_id: None,
                references: vec![],
                parent: None,
            })
            .expect("insert paper");
        id
    }

    fn affected_call(
        store: &SqliteItemStore,
        id: uuid::Uuid,
        field: &str,
        started_at: chrono::DateTime<Utc>,
        caller: impress_service_core::pipeline::CallerIdentity,
    ) -> String {
        let call_id = uuid::Uuid::new_v4().to_string();
        let mut payload = serde_json::json!({
            "verb": "imbib-library-service_retention-cleanup",
            "caller": caller.to_json(),
            "started_at": started_at.to_rfc3339_opts(SecondsFormat::Millis, true),
        })
        .as_object()
        .unwrap()
        .clone();
        payload.insert(field.into(), json!([id.to_string()]));
        impress_core::call_context::record_verb_call(store, &call_id, &caller, payload)
            .expect("record call");
        call_id
    }

    fn set_starred(store: Arc<SqliteItemStore>, id: uuid::Uuid, caller: &str) -> Value {
        let verb = VerbDescriptor::find("triage-service_set-starred").expect("linked");
        impress_service_core::runtime::block_on(pipeline::invoke_on(
            store,
            verb,
            PipeCall::agent(caller, json!({"id": id.to_string(), "starred": true})),
        ))
        .expect("verb ran")
    }

    /// The Tier A proof: an item created and starred through the real
    /// pipeline, then `why` names the call, its caller and the verb.
    #[test]
    fn why_names_the_call_its_caller_and_the_verb() {
        let store = crate::test_support::test_store();
        let id = item(&store);
        let answer = set_starred(store.clone(), id, "test-agent");
        assert_eq!(answer["ok"], true, "{answer}");
        crate::audit::flush().expect("audit flush");

        let svc = DefaultHistoryService::with_store(store);
        let result = impress_service_core::runtime::block_on(svc.why(id.to_string()));
        assert!(result.ok, "{}", result.message);
        assert_eq!(result.entries.len(), 1, "one operation wrote this item");
        let call = result.entries[0]
            .call
            .as_ref()
            .expect("the call row was written before we flushed");
        assert_eq!(call.verb, "triage-service_set-starred");
        assert_eq!(call.caller, json!({"kind": "agent", "name": "test-agent"}));
        assert!(!result.entries[0].applied_at.is_empty());
        assert!(result.entries[0].operation_id.is_some());
    }

    #[test]
    fn why_shows_workflow_caller_for_a_deleted_paper_without_an_operation() {
        let store = crate::test_support::test_store();
        let id = paper(&store);
        let now = Utc::now();
        let inserted_call = affected_call(
            &store,
            id,
            "inserted_ids",
            now - chrono::Duration::hours(2),
            impress_service_core::pipeline::CallerIdentity::agent("importer"),
        );
        store.delete(id).expect("direct delete");
        let deleted_call = affected_call(
            &store,
            id,
            "deleted_ids",
            now - chrono::Duration::hours(1),
            impress_service_core::pipeline::CallerIdentity::system("imbib.retention-cleanup"),
        );
        assert!(store.operations_for(id, None).unwrap().is_empty());

        let result = impress_service_core::runtime::block_on(
            DefaultHistoryService::with_store(store).why(id.to_string()),
        );
        assert!(result.ok, "{}", result.message);
        assert_eq!(result.entries.len(), 2);
        assert_eq!(result.entries[0].batch_id, deleted_call);
        assert_eq!(result.entries[1].batch_id, inserted_call);
        assert!(result
            .entries
            .iter()
            .all(|entry| entry.operation_id.is_none()));
        assert_eq!(
            result.entries[0].call.as_ref().unwrap().caller,
            json!({"kind": "system", "name": "imbib.retention-cleanup"})
        );
    }

    #[test]
    fn why_does_not_duplicate_an_operation_linked_call_that_names_the_item() {
        let store = crate::test_support::test_store();
        let id = item(&store);
        set_starred(store.clone(), id, "test-agent");
        crate::audit::flush().expect("audit flush");
        let call_id = store.operations_for(id, None).unwrap()[0]
            .batch_id
            .clone()
            .unwrap();
        store
            .update(
                call_id.parse().unwrap(),
                vec![FieldMutation::SetPayload(
                    "deleted_ids".into(),
                    CoreValue::Array(vec![CoreValue::String(id.to_string())]),
                )],
            )
            .unwrap();

        let result = impress_service_core::runtime::block_on(
            DefaultHistoryService::with_store(store).why(id.to_string()),
        );
        assert!(result.ok, "{}", result.message);
        assert_eq!(result.entries.len(), 1);
        assert!(result.entries[0].operation_id.is_some());
        assert_eq!(result.entries[0].batch_id, call_id);
    }

    #[test]
    fn trace_nests_a_nested_call_under_its_parent() {
        let store = crate::test_support::test_store();
        let id_a = item(&store);
        let id_b = item(&store);
        let verb = VerbDescriptor::find("triage-service_set-starred").expect("linked");
        let trace_id = uuid::Uuid::new_v4().to_string();
        let call_a = PipeCall::agent("test", json!({"id": id_a.to_string(), "starred": true}))
            .with_trace(trace_id.clone());
        let call_b = PipeCall::agent("test", json!({"id": id_b.to_string(), "starred": true}))
            .with_trace(trace_id.clone());
        impress_service_core::runtime::block_on(pipeline::invoke_on(store.clone(), verb, call_a))
            .unwrap();
        impress_service_core::runtime::block_on(pipeline::invoke_on(store.clone(), verb, call_b))
            .unwrap();
        crate::audit::flush().expect("audit flush");

        let svc = DefaultHistoryService::with_store(store);
        let result = impress_service_core::runtime::block_on(svc.trace(trace_id.clone()));
        assert!(result.ok, "{}", result.message);
        assert_eq!(result.roots.len(), 2, "both calls are roots, no parent");
        assert!(result.roots.iter().all(|r| r.call.trace_id == trace_id));
    }

    #[test]
    fn replay_refuses_a_call_whose_args_were_privacy_reduced() {
        let store = crate::test_support::test_store();
        let id = item(&store);
        // A long string argument is reduced to {len, sha256_8} by the audit
        // layer's own privacy rule, so the recorded call is not full.
        let long = "x".repeat(200);
        let verb = VerbDescriptor::find("triage-service_add-tag").expect("linked");
        let answer = impress_service_core::runtime::block_on(pipeline::invoke_on(
            store.clone(),
            verb,
            PipeCall::agent("test", json!({"id": id.to_string(), "tag": long})),
        ))
        .expect("verb ran");
        assert_eq!(answer["ok"], true, "{answer}");
        crate::audit::flush().expect("audit flush");

        let calls = impress_service_core::runtime::block_on(
            DefaultHistoryService::with_store(store.clone()).calls(
                None,
                None,
                Some("triage-service_add-tag".into()),
                None,
                None,
                0,
            ),
        );
        let call_id = calls
            .calls
            .first()
            .expect("one call recorded")
            .call_id
            .clone();

        let svc = DefaultHistoryService::with_store(store);
        let result = impress_service_core::runtime::block_on(svc.replay(vec![call_id], false));
        assert!(!result.ok);
        assert_eq!(
            result.results[0].code.as_deref(),
            Some(codes::NOT_REPLAYABLE)
        );
    }

    #[test]
    fn replay_dry_run_lists_a_full_call_without_running_it() {
        let store = crate::test_support::test_store();
        let id = item(&store);
        set_starred(store.clone(), id, "test");
        crate::audit::flush().expect("audit flush");

        let calls = impress_service_core::runtime::block_on(
            DefaultHistoryService::with_store(store.clone()).calls(None, None, None, None, None, 0),
        );
        let call_id = calls
            .calls
            .first()
            .expect("one call recorded")
            .call_id
            .clone();

        let svc = DefaultHistoryService::with_store(store);
        let result = impress_service_core::runtime::block_on(svc.replay(vec![call_id], true));
        assert!(result.ok, "{result:?}");
        assert!(result.dry_run);
        assert!(result.results[0].message.contains("would call"));
    }

    #[test]
    fn runtime_provider_is_resolved_for_mutation_mining_and_replay_preview() {
        use impress_service_core::provider::{RegistrationRequest, Registry, SchemaValidator};
        use impress_service_core::registry_runtime;

        struct RestoreRegistry(Arc<Registry>);
        impl Drop for RestoreRegistry {
            fn drop(&mut self) {
                registry_runtime::install(self.0.clone());
            }
        }
        let _restore = RestoreRegistry(registry_runtime::current());

        struct AcceptSchema;
        impl SchemaValidator for AcceptSchema {
            fn validate(&self, _: &Value) -> Result<(), String> {
                Ok(())
            }
            fn validate_instance(&self, _: &Value, _: &Value) -> Result<(), String> {
                Ok(())
            }
        }

        let registry = Arc::new(Registry::new().with_validator(Arc::new(AcceptSchema)));
        let request: RegistrationRequest = serde_json::from_value(json!({
            "provider":{"id":"history-provider-fixture","language":"Python","version":"1.0.0","endpoint":"http://127.0.0.1:1"},
            "verbs":[{"name":"history-provider-fixture-service_change","description":"Change a value",
                "input_schema":{"type":"object","properties":{"value":{"type":"string","description":"Value"}},"required":["value"],"additionalProperties":false},
                "output_schema":{"type":"object","properties":{"ok":{"type":"boolean"}}},
                "safety":{"class":"mutating"},"since":"1.0.0",
                "examples":[{"name":"change","args":{"value":"hello"}}]}]
        }))
        .unwrap();
        registry.register(request).unwrap();
        registry
            .set_trusted("history-provider-fixture", true)
            .unwrap();
        registry_runtime::install(registry);
        let name = "history-provider-fixture-service_change";

        let store = crate::test_support::test_store();
        let call_id = uuid::Uuid::new_v4().to_string();
        let payload = json!({
            "verb":name,"args":{"value":"hello"},"args_replayable":true,
            "caller":{"kind":"agent","name":"fixture"},"ok":true
        })
        .as_object()
        .unwrap()
        .clone();
        impress_core::call_context::record_verb_call(
            &*store,
            &call_id,
            &pipeline::CallerIdentity::agent("fixture"),
            payload,
        )
        .unwrap();
        let result = impress_service_core::runtime::block_on(
            DefaultHistoryService::with_store(store).replay(vec![call_id], true),
        );
        assert!(result.ok, "{result:?}");
        assert!(result.results[0].message.contains(name));
    }

    #[test]
    fn save_macro_writes_a_proposed_workflow_document() {
        let store = crate::test_support::test_store();
        let id = item(&store);
        set_starred(store.clone(), id, "test");
        crate::audit::flush().expect("audit flush");

        let calls = impress_service_core::runtime::block_on(
            DefaultHistoryService::with_store(store.clone()).calls(None, None, None, None, None, 0),
        );
        let call_id = calls
            .calls
            .first()
            .expect("one call recorded")
            .call_id
            .clone();

        let svc = DefaultHistoryService::with_store(store.clone());
        let result = impress_service_core::runtime::block_on(
            svc.save_macro(vec![call_id], "my-macro".into()),
        );
        assert!(result.ok, "{}", result.message);
        let row = store
            .get(uuid::Uuid::parse_str(&result.id).unwrap())
            .unwrap()
            .expect("workflow row exists");
        assert_eq!(row.schema, WORKFLOW_SCHEMA);
        assert_eq!(
            row.payload.get("state"),
            Some(&CoreValue::String("proposed".into()))
        );
        let steps = row.payload.get("steps").expect("steps field");
        assert!(matches!(steps, CoreValue::Array(v) if v.len() == 1));
    }

    #[test]
    fn health_reports_the_sinks_counters_and_a_row_count() {
        let store = crate::test_support::test_store();
        let id = item(&store);
        set_starred(store.clone(), id, "test");
        crate::audit::flush().expect("audit flush");

        let svc = DefaultHistoryService::with_store(store);
        let health = impress_service_core::runtime::block_on(svc.health());
        assert!(health.ok);
        assert!(health.rows >= 1);
        assert!(health.channel_capacity > 0);
    }

    fn add_tag(store: Arc<SqliteItemStore>, id: uuid::Uuid, tag: &str, caller: &str) -> Value {
        let verb = VerbDescriptor::find("triage-service_add-tag").expect("linked");
        impress_service_core::runtime::block_on(pipeline::invoke_on(
            store,
            verb,
            PipeCall::agent(caller, json!({"id": id.to_string(), "tag": tag})),
        ))
        .expect("verb ran")
    }

    /// W4's proof, the engine half (the engine is koine's
    /// `impress-workflow-service`, KM4): a workflow mined by
    /// `history-service_propose-workflows` is written `state: proposed`
    /// (never `enabled`), and `run_once`'s own row filter
    /// (`r.spec.state == WorkflowState::Enabled`) means the engine never
    /// runs it, however far past `start_delay` the clock is.
    #[test]
    fn a_proposed_workflow_never_runs_through_the_engine() {
        use impress_service_core::pipeline::{self, Call as PipeCall};
        use impress_service_core::VerbDescriptor;
        use impress_workflow_service::{CallStore, WorkflowEngine};

        let store = crate::test_support::test_store();

        // Three identical two-step triage sessions by one caller — W4's
        // miner input (see `three_identical_triage_sequences_...` above for the
        // mining half).
        let star = VerbDescriptor::find("triage-service_set-starred").expect("linked");
        let tag = VerbDescriptor::find("triage-service_add-tag").expect("linked");
        for _ in 0..3 {
            let id = uuid::Uuid::new_v4();
            let mut payload = std::collections::BTreeMap::new();
            payload.insert(
                "title".to_string(),
                impress_core::item::Value::String("paper".into()),
            );
            store
                .insert(impress_core::item::Item {
                    id,
                    schema: impress_core::schema::refs::IMBIB_BIBLIOGRAPHY_ENTRY,
                    payload,
                    created: chrono::Utc::now(),
                    modified: chrono::Utc::now(),
                    author: "test".into(),
                    author_kind: impress_core::item::ActorKind::Agent,
                    logical_clock: 0,
                    origin: None,
                    canonical_id: None,
                    tags: vec![],
                    flag: None,
                    is_read: false,
                    is_starred: false,
                    priority: impress_core::item::Priority::None,
                    visibility: impress_core::item::Visibility::Private,
                    message_type: None,
                    produced_by: None,
                    version: None,
                    batch_id: None,
                    references: vec![],
                    parent: None,
                })
                .expect("insert paper");
            impress_service_core::runtime::block_on(pipeline::invoke_on(
                store.clone(),
                star,
                PipeCall::agent(
                    "triage-agent",
                    serde_json::json!({"id": id.to_string(), "starred": true}),
                ),
            ))
            .expect("star ran");
            impress_service_core::runtime::block_on(pipeline::invoke_on(
                store.clone(),
                tag,
                PipeCall::agent(
                    "triage-agent",
                    serde_json::json!({"id": id.to_string(), "tag": "reading/queue"}),
                ),
            ))
            .expect("tag ran");
        }
        crate::audit::flush().expect("audit flush");

        let svc = DefaultHistoryService::with_store(store.clone());
        let proposal = impress_service_core::runtime::block_on(svc.propose_workflows(None, 0, 0));
        assert_eq!(proposal.proposed.len(), 1, "{:?}", proposal.proposed);

        let workspace = tempfile::tempdir().unwrap();
        let mut engine = WorkflowEngine::new(0, 90_000);
        // Well past `start_delay`, and the proposed row's `manual` trigger
        // has no autonomous fire path anyway — the filter this asserts is
        // `run_once`'s row-state filter, which runs before any trigger is
        // even looked at.
        let outcomes = engine.run_once(&CallStore::of(store.clone()), 1_000_000, workspace.path());
        assert!(
            outcomes.is_empty(),
            "a proposed workflow must never run: {outcomes:?}"
        );
    }

    /// The negative half of the same proof: three *different* two-step
    /// sequences by the same caller never repeat, so nothing is proposed.
    #[test]
    fn three_different_sequences_propose_nothing() {
        let store = crate::test_support::test_store();
        let a = item(&store);
        let b = item(&store);
        let c = item(&store);
        set_starred(store.clone(), a, "triage-agent");
        add_tag(store.clone(), a, "x", "triage-agent");
        add_tag(store.clone(), b, "y", "triage-agent");
        set_starred(store.clone(), b, "triage-agent");
        set_starred(store.clone(), c, "triage-agent");
        set_starred(store.clone(), c, "triage-agent");
        crate::audit::flush().expect("audit flush");

        let svc = DefaultHistoryService::with_store(store);
        let result = impress_service_core::runtime::block_on(svc.propose_workflows(None, 0, 0));
        assert!(result.ok, "{}", result.message);
        assert!(result.proposed.is_empty(), "{:?}", result.proposed);
    }

    #[test]
    fn privacy_reduced_arguments_are_not_embedded_in_a_proposal() {
        let store = crate::test_support::test_store();
        let long_tag = "private-context-".repeat(12);
        for _ in 0..3 {
            let id = item(&store);
            set_starred(store.clone(), id, "triage-agent");
            add_tag(store.clone(), id, &long_tag, "triage-agent");
        }
        crate::audit::flush().expect("audit flush");

        let svc = DefaultHistoryService::with_store(store);
        let result = impress_service_core::runtime::block_on(svc.propose_workflows(None, 0, 0));
        assert!(result.ok, "{}", result.message);
        assert!(result.proposed.is_empty(), "{:?}", result.proposed);
    }
}
