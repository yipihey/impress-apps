//! List / resolve review-request checkpoints in a workspace store.
//! Smoke-test companion for impel-taskd (and a minimal human-loop CLI
//! until the imbib review queue ships).
//!
//! Usage:
//!   cargo run -p impel-taskd --example review_cli -- <workspace-dir> list
//!   cargo run -p impel-taskd --example review_cli -- <workspace-dir> resolve <review-id> approved|rejected
//!   cargo run -p impel-taskd --example review_cli -- <workspace-dir> seed "<question>" tag1,tag2

use impress_core::item::{ActorKind, Value};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::query::ItemQuery;
use impress_core::sqlite_store::{SqliteItemStore, StoreConfig};
use impress_core::store::ItemStore;

fn main() {
    let mut args = std::env::args().skip(1);
    let workspace = args.next().expect("workspace dir");
    let cmd = args.next().unwrap_or_else(|| "list".into());

    let store = SqliteItemStore::open_with_config(
        &std::path::Path::new(&workspace).join("impress.sqlite"),
        StoreConfig {
            author: "tom".into(),
            author_kind: ActorKind::Human,
            ..StoreConfig::default()
        },
    )
    .expect("open store");

    match cmd.as_str() {
        "list" => {
            let reviews = store
                .query(&ItemQuery {
                    schema: Some("review-request@1.0.0".into()),
                    ..Default::default()
                })
                .expect("query");
            for r in reviews {
                let q = match r.payload.get("question") {
                    Some(Value::String(s)) => s.clone(),
                    _ => "(no question)".into(),
                };
                let resolution = match r.payload.get("resolution") {
                    Some(Value::String(s)) => s.clone(),
                    _ => "UNRESOLVED".into(),
                };
                let tags = match r.payload.get("context_proposed_tags") {
                    Some(Value::Array(a)) => a
                        .iter()
                        .filter_map(|v| match v {
                            Value::String(s) => Some(s.as_str()),
                            _ => None,
                        })
                        .collect::<Vec<_>>()
                        .join(", "),
                    _ => String::new(),
                };
                println!("{} [{}] {} — proposes: [{}]", r.id, resolution, q, tags);
            }
        }
        "resolve" => {
            let id: uuid::Uuid = args
                .next()
                .expect("review id")
                .parse()
                .expect("valid uuid");
            let resolution = args.next().unwrap_or_else(|| "approved".into());
            store
                .apply_operation(OperationSpec {
                    target_id: id,
                    op_type: OperationType::SetPayload(
                        "resolution".into(),
                        Value::String(resolution.clone()),
                    ),
                    intent: OperationIntent::Editorial,
                    reason: Some("review_cli".into()),
                    batch_id: None,
                    author: "tom".into(),
                    author_kind: ActorKind::Human,
                    retention: RetentionTier::Durable,
                })
                .expect("apply");
            println!("review {id} → {resolution}");
        }
        "seed" => {
            // Demo/testing helper: create a review-request the way
            // KeywordTagExecutor does.
            use chrono::Utc;
            use impress_core::item::{Item, Priority, Visibility};
            use std::collections::BTreeMap;
            let question = args.next().unwrap_or_else(|| "Apply proposed tags?".into());
            let tags: Vec<Value> = args
                .next()
                .unwrap_or_default()
                .split(',')
                .filter(|s| !s.is_empty())
                .map(|s| Value::String(s.trim().to_string()))
                .collect();
            let mut payload = BTreeMap::new();
            payload.insert("question".into(), Value::String(question.clone()));
            payload.insert("context_proposed_tags".into(), Value::Array(tags));
            let item = Item {
                id: uuid::Uuid::new_v4(),
                schema: "review-request@1.0.0".into(),
                payload,
                created: Utc::now(),
                modified: Utc::now(),
                author: "impel/keyword-tag".into(),
                author_kind: ActorKind::Agent,
                logical_clock: 0,
                origin: None,
                canonical_id: None,
                tags: vec![],
                flag: None,
                is_read: false,
                is_starred: false,
                priority: Priority::Normal,
                visibility: Visibility::Private,
                message_type: None,
                produced_by: None,
                version: None,
                batch_id: None,
                references: vec![],
                parent: None,
            };
            let id = store.insert(item).expect("insert review");
            println!("seeded review-request {id}: {question}");
        }
        other => eprintln!("unknown command '{other}' (list | resolve | seed)"),
    }
}
