//! The pipeline holds by construction (ADR-0034 D2, plan-verb-pipeline P2,
//! completeness 1–3).
//!
//! 1. **One invoker, N interfaces.** Every place in the repository that
//!    calls a descriptor's handler is enumerated from source and must be the
//!    pipeline itself; every entry path (table PL1) is checked to go through
//!    it. A new `descriptor.handler` call site anywhere fails this test.
//! 2. **Identity is the transport's.** An agent that sends `actor: "human"`
//!    on a layout verb is recorded as the agent (PL-3, D-P2); the person is
//!    recorded as the person.
//! 3. **The audit row joins the operations.** A mutating verb through the
//!    pipeline leaves one `core/verb-call@1.0.0` row whose id is the
//!    `batch_id` of every operation it wrote, with the caller on it.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use impress_core::query::ItemQuery;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_service_core::pipeline::{self, Call, CallerIdentity};
use impress_service_core::VerbDescriptor;

// The whole linked inventory: a test binary links only what it names.
#[allow(unused_imports)]
use impress_capabilities as _force_link_inventory;
use serde_json::{json, Value};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root")
}

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if path.is_dir() {
            if name == "target" || name.starts_with("target-") || name == ".git" {
                continue;
            }
            rust_files(&path, out);
        } else if name.ends_with(".rs") {
            out.push(path);
        }
    }
}

/// The one file that may call a descriptor's handler: the pipeline's
/// handler step. The bench baseline is the one measurement that needs the
/// raw handler beside the chain, and says so.
const HANDLER_CALLERS_ALLOWED: &[&str] = &[
    "crates/impress-service-core/src/pipeline/mod.rs",
    "crates/impress-capabilities/tests/pipeline_bench.rs",
];

/// Every entry path in plan-verb-pipeline table PL1, and the text that
/// proves it enters the chain.
const ENTRY_PATHS: &[(&str, &str, &str)] = &[
    (
        "(a)(b) MCP flat and grouped",
        "crates/impress-mcp/src/inventory_bridge.rs",
        "impress_capabilities::call_as(",
    ),
    (
        "(c) CLI",
        "crates/impress-service-core/src/cli.rs",
        "crate::pipeline::invoke_blocking(",
    ),
    (
        "(d1) surface runtime, linked verb",
        "crates/impress-surface-service/src/runtime.rs",
        "call::call_async_as(",
    ),
    (
        "(d2) surface HTTP mirror (was a bypass)",
        "crates/impress-surface-service/src/service.rs",
        "pipeline::invoke_with(descriptor, call,",
    ),
    (
        "(e2) FFI layout apply (was a bypass)",
        "crates/impress-store-ffi/src/layout.rs",
        "pipeline::invoke_sync_with(&LAYOUT_APPLY,",
    ),
    (
        "(f) impel-tools (the FFI verb host's (e1) route)",
        "crates/impel-tools/src/lib.rs",
        "impress_service_core::pipeline::invoke_blocking(",
    ),
    (
        "(h1) impress-mcp-host",
        "crates/impress-mcp-host/src/lib.rs",
        "impress_service_core::pipeline::invoke_blocking(",
    ),
    (
        "(h2) impress-ai-tools",
        "crates/impress-ai-tools/src/lib.rs",
        "impress_service_core::pipeline::invoke(",
    ),
    (
        "call.rs (the shared seat)",
        "crates/impress-service-core/src/call.rs",
        "pipeline::invoke(descriptor.verb,",
    ),
];

#[test]
fn every_handler_call_site_is_the_pipeline() {
    let root = repo_root();
    let mut files = Vec::new();
    rust_files(&root.join("crates"), &mut files);
    rust_files(&root.join("apps"), &mut files);
    let mut offenders = BTreeSet::new();
    for file in &files {
        let Ok(text) = fs::read_to_string(file) else {
            continue;
        };
        // A descriptor reader names one of the descriptor types; the
        // pattern alone would also catch unrelated `handler` fields
        // (imprint-core's runner host).
        let reads_descriptors = text.contains("McpToolDescriptor")
            || text.contains("CliSubcommand")
            || text.contains("VerbDescriptor")
            || text.contains("impress_service_core");
        if !reads_descriptors {
            continue;
        }
        let rel = file
            .strip_prefix(&root)
            .unwrap_or(file)
            .to_string_lossy()
            .to_string();
        if HANDLER_CALLERS_ALLOWED.contains(&rel.as_str()) {
            continue;
        }
        for (number, line) in text.lines().enumerate() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("//") {
                continue;
            }
            // Spelled in two pieces so this file does not match itself.
            if line.contains(concat!(".handler", ")(")) || line.contains(concat!(".apply", ")(")) {
                offenders.insert(format!("{rel}:{}: {}", number + 1, line.trim()));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "a descriptor's handler is called outside the pipeline (ADR-0034 D2: every path \
         runs `impress_service_core::pipeline::invoke`):\n  {}",
        offenders.into_iter().collect::<Vec<_>>().join("\n  ")
    );
}

#[test]
fn every_entry_path_enters_the_chain() {
    let root = repo_root();
    let mut missing = Vec::new();
    for (path_name, file, proof) in ENTRY_PATHS {
        let text = fs::read_to_string(root.join(file))
            .unwrap_or_else(|e| panic!("{file} ({path_name}): {e}"));
        if !text.contains(proof) {
            missing.push(format!("{path_name}: {file} does not contain `{proof}`"));
        }
    }
    assert!(missing.is_empty(), "{}", missing.join("\n"));
}

fn scratch() -> Arc<SqliteItemStore> {
    Arc::new(SqliteItemStore::open_in_memory().expect("in-memory store"))
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

fn authors_of(
    store: &SqliteItemStore,
    schema: impress_core::SchemaRef,
) -> BTreeSet<(String, String)> {
    store
        .query(&ItemQuery {
            schema: Some(schema),
            ..Default::default()
        })
        .expect("query")
        .into_iter()
        .map(|item| (item.author, format!("{:?}", item.author_kind)))
        .collect()
}

/// PL-3 / D-P2: `actor: "human"` from an agent is recorded as the agent, on
/// the operations the verb wrote and on the call row.
#[test]
fn an_agents_claim_to_be_human_is_recorded_as_the_agent() {
    let store = scratch();
    let answer = run(
        &store,
        CallerIdentity::agent("mcp:test"),
        "layout-service_split",
        json!({
            "app_id": "pipeline-test",
            "device": "pipeline-device",
            "target": {"focused": true},
            "direction": "horizontal",
            "after": true,
            "actor": "human",
        }),
    );
    assert_eq!(answer["ok"], true, "{answer}");
    impress_store_service::audit::flush().expect("audit flush");

    let ops = authors_of(&store, impress_core::schema::refs::CORE_OPERATION);
    assert!(!ops.is_empty(), "the split wrote operations");
    for (author, kind) in &ops {
        assert_eq!(kind, "Agent", "{author} on an operation");
        assert!(
            !author.starts_with("human"),
            "an agent's claim was believed: {author}"
        );
    }
    let calls = authors_of(&store, impress_core::schemas::VERB_CALL_SCHEMA);
    assert_eq!(
        calls,
        BTreeSet::from([("agent:mcp:test".to_string(), "Agent".to_string())])
    );
}

/// The person, saying nothing, is the person.
#[test]
fn the_person_is_recorded_as_the_person() {
    let store = scratch();
    let answer = run(
        &store,
        CallerIdentity::Person,
        "layout-service_split",
        json!({
            "app_id": "pipeline-test",
            "device": "pipeline-device",
            "target": {"focused": true},
            "direction": "horizontal",
            "after": true,
        }),
    );
    assert_eq!(answer["ok"], true, "{answer}");
    impress_store_service::audit::flush().expect("audit flush");
    let ops = authors_of(&store, impress_core::schema::refs::CORE_OPERATION);
    assert!(ops.iter().all(|(_, kind)| kind == "Human"), "{ops:?}");
    let calls = authors_of(&store, impress_core::schemas::VERB_CALL_SCHEMA);
    assert_eq!(
        calls,
        BTreeSet::from([("human".to_string(), "Human".to_string())])
    );
}

/// D-R2: the call row's id is the `batch_id` of the operations the verb
/// wrote; D-R3: a read-only verb leaves no row.
#[test]
fn the_call_row_is_the_batch_of_its_operations() {
    let store = scratch();
    let created = run(
        &store,
        CallerIdentity::agent("cli"),
        "collection-service_create",
        json!({ "binding": "generic", "name": "pipeline", "kind_scope": "any" }),
    );
    let id = created["collection"]["id"]
        .as_str()
        .unwrap_or_else(|| panic!("a created collection has an id: {created}"))
        .to_string();
    let renamed = run(
        &store,
        CallerIdentity::agent("cli"),
        "collection-service_rename",
        json!({ "binding": "generic", "id": id, "name": "renamed" }),
    );
    assert_eq!(renamed["ok"], true, "{renamed}");
    impress_store_service::audit::flush().expect("audit flush");

    let ops = store
        .operations_for(id.parse().expect("uuid"), None)
        .expect("ops");
    assert!(!ops.is_empty(), "rename wrote an operation");
    let batches: BTreeSet<Option<String>> = ops.iter().map(|op| op.batch_id.clone()).collect();
    let calls = store
        .query(&ItemQuery {
            schema: Some(impress_core::schemas::VERB_CALL_SCHEMA.into()),
            ..Default::default()
        })
        .expect("calls");
    let call_ids: BTreeSet<Option<String>> = calls.iter().map(|c| Some(c.id.to_string())).collect();
    assert!(
        batches.is_subset(&call_ids),
        "every op's batch_id is a call row id: ops {batches:?}, calls {call_ids:?}"
    );
    let rename_row = calls
        .iter()
        .find(|c| {
            c.payload
                .get("verb")
                .map(|v| format!("{v:?}"))
                .is_some_and(|v| v.contains("collection-service_rename"))
        })
        .expect("the rename's call row");
    assert_eq!(rename_row.author, "agent:cli");

    let before = calls.len();
    let _ = run(
        &store,
        CallerIdentity::agent("cli"),
        "collection-service_tree",
        json!({ "binding": "generic" }),
    );
    impress_store_service::audit::flush().expect("audit flush");
    let after = store
        .count(&ItemQuery {
            schema: Some(impress_core::schemas::VERB_CALL_SCHEMA.into()),
            ..Default::default()
        })
        .expect("count");
    if std::env::var("IMPRESS_CALL_LOG").as_deref() != Ok("all") {
        assert_eq!(after, before, "a read-only verb is not recorded (D-R3)");
    }
}

/// A strict service's refusal is unchanged by the move into the chain:
/// `{ok: false, code: "invalid-argument", message naming the tool and the
/// field, wire_version}`.
#[test]
fn a_strict_refusal_is_byte_identical_to_the_invokers() {
    let store = scratch();
    let answer = run(
        &store,
        CallerIdentity::agent("cli"),
        "layout-service_split",
        json!({ "app_id": "x", "target": {"focused": true}, "direction": "horizontal", "after": true, "nope": 1 }),
    );
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["code"], "invalid-argument");
    assert_eq!(answer["wire_version"], 1);
    let message = answer["message"].as_str().unwrap();
    assert!(message.starts_with("layout-service_split: "), "{message}");
    assert!(message.contains("unknown field 'nope'"), "{message}");
}

/// CollectionService omits `strict_args`; the default must now refuse an
/// unknown key before its otherwise lenient serde argument struct sees it.
#[test]
fn an_implicit_strict_service_refuses_an_unknown_key() {
    let descriptor = VerbDescriptor::find("collection-service_tree").expect("linked");
    assert!(descriptor.strict, "an omitted flag defaults to strict");
    let answer = run(
        &scratch(),
        CallerIdentity::agent("cli"),
        descriptor.name,
        json!({ "binding": "generic", "nope": 1 }),
    );
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["code"], "invalid-argument");
    assert!(answer["message"]
        .as_str()
        .unwrap()
        .contains("unknown field 'nope'"));
}
