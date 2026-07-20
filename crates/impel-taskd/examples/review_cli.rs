//! List / resolve review-request checkpoints in a workspace store.
//! Smoke-test companion for impel-taskd (and a minimal human-loop CLI
//! until the imbib review queue ships).
//!
//! Usage:
//!   cargo run -p impel-taskd --example review_cli -- <workspace-dir> list
//!   cargo run -p impel-taskd --example review_cli -- <workspace-dir> resolve <review-id> approved|rejected

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
        other => eprintln!("unknown command '{other}' (list | resolve)"),
    }
}
