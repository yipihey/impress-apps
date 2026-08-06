//! Restart-safe import of the retired standalone LocalModels conversation DB.
//!
//! Each source conversation becomes one atomic `insert_batch`: conversation,
//! messages, source artifacts, synthetic completed tasks/runs, and the import
//! receipt either all commit or none do. Deterministic UUIDv5 identifiers make
//! collision diagnostics stable; the receipt's content hash distinguishes an
//! unchanged row from a legacy conversation edited after migration.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;

use chrono::{DateTime, Duration, Utc};
use impress_core::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};
use impress_core::query::{ItemQuery, Predicate};
use impress_core::reference::{EdgeType, TypedReference};
use impress_core::schemas::{
    AGENT_RUN_SCHEMA, AI_IMPORT_LEDGER_SCHEMA, CONTENT_BLOB_SCHEMA, CONVERSATION_SCHEMA,
    TASK_SCHEMA,
};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{BlobStore, Error, Result};

const CHAT_MESSAGE_SCHEMA: &str = "chat-message";
const WEBPAGE_SCHEMA: &str = "impress/artifact/webpage";
const IMPORT_NAMESPACE: Uuid = Uuid::from_u128(0x674f_e0b3_399c_4b77_a114_4824_88c9_a5d1);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct LocalModelsMigrationReport {
    pub discovered: u32,
    pub imported: u32,
    pub skipped_unchanged: u32,
    pub changed_after_import: u32,
    pub failed: u32,
    pub failures: Vec<String>,
    pub dry_run: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyState {
    #[serde(default)]
    model: String,
    #[serde(default)]
    system: String,
    #[serde(default = "default_temperature")]
    temperature: f32,
    #[serde(default = "default_max_tokens", alias = "max_tokens")]
    max_tokens: u32,
    #[serde(default)]
    thinking: bool,
    #[serde(default, alias = "web_access")]
    web_access: bool,
    #[serde(default)]
    messages: Vec<LegacyMessage>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyMessage {
    role: LegacyRole,
    #[serde(default)]
    content: String,
    model: Option<String>,
    #[serde(default)]
    reasoning: String,
    #[serde(default)]
    sources: Vec<LegacySource>,
    meta: Option<String>,
    #[serde(default)]
    streaming: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
enum LegacyRole {
    System,
    User,
    Assistant,
}

#[derive(Debug, Deserialize)]
struct LegacySource {
    url: String,
    title: String,
    #[serde(default)]
    content: String,
}

struct LegacyConversation {
    id: String,
    title: String,
    state_json: String,
    state: LegacyState,
    revision: u64,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

/// Import every conversation from a LocalModels `chats.sqlite3` into the
/// shared Impress graph. The source database is opened read-only.
pub fn migrate_localmodels(
    store: Arc<SqliteItemStore>,
    blobs: &dyn BlobStore,
    source_database: &Path,
    dry_run: bool,
) -> Result<LocalModelsMigrationReport> {
    let canonical = source_database.canonicalize()?;
    let database_id = hex_hash(canonical.to_string_lossy().as_bytes());
    let connection = Connection::open_with_flags(
        &canonical,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let mut statement = connection.prepare(
        "SELECT id, title, state_json, revision, created_at, updated_at \
         FROM conversations ORDER BY created_at, id",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, u64>(3)?,
            row.get::<_, String>(4)?,
            row.get::<_, String>(5)?,
        ))
    })?;

    let mut report = LocalModelsMigrationReport {
        dry_run,
        ..Default::default()
    };
    for row in rows {
        report.discovered += 1;
        let outcome = (|| -> Result<ImportOutcome> {
            let (id, title, state_json, revision, created_at, updated_at) = row?;
            let legacy = LegacyConversation {
                id,
                title,
                state: serde_json::from_str(&state_json)?,
                state_json,
                revision,
                created_at: parse_timestamp(&created_at)?,
                updated_at: parse_timestamp(&updated_at)?,
            };
            import_one(&store, blobs, &database_id, legacy, dry_run)
        })();
        match outcome {
            Ok(ImportOutcome::Imported) => report.imported += 1,
            Ok(ImportOutcome::Unchanged) => report.skipped_unchanged += 1,
            Ok(ImportOutcome::Changed) => report.changed_after_import += 1,
            Err(error) => {
                report.failed += 1;
                report.failures.push(error.to_string());
            }
        }
    }
    Ok(report)
}

enum ImportOutcome {
    Imported,
    Unchanged,
    Changed,
}

fn import_one(
    store: &SqliteItemStore,
    blobs: &dyn BlobStore,
    database_id: &str,
    legacy: LegacyConversation,
    dry_run: bool,
) -> Result<ImportOutcome> {
    let content_hash = hex_hash(
        format!(
            "{}\0{}\0{}\0{}\0{}",
            legacy.id, legacy.title, legacy.revision, legacy.updated_at, legacy.state_json
        )
        .as_bytes(),
    );
    let existing = store.query(&ItemQuery {
        schema: Some(AI_IMPORT_LEDGER_SCHEMA.into()),
        predicates: vec![
            Predicate::Eq(
                "payload.source_database_id".into(),
                Value::String(database_id.into()),
            ),
            Predicate::Eq(
                "payload.source_conversation_id".into(),
                Value::String(legacy.id.clone()),
            ),
        ],
        limit: Some(1),
        ..Default::default()
    })?;
    if let Some(receipt) = existing.first() {
        let same_hash = payload_string(receipt, "source_content_hash").as_deref()
            == Some(content_hash.as_str());
        let same_revision =
            payload_i64(receipt, "source_revision") == i64::try_from(legacy.revision).ok();
        return Ok(if same_hash && same_revision {
            ImportOutcome::Unchanged
        } else {
            ImportOutcome::Changed
        });
    }
    if dry_run {
        return Ok(ImportOutcome::Imported);
    }

    let conversation_id = stable_id(database_id, &legacy.id, "conversation");
    let mut items = vec![conversation_item(conversation_id, &legacy)];
    let mut previous_message: Option<ItemId> = None;
    let mut sequence = 0_i64;

    for (index, message) in legacy.state.messages.iter().enumerate() {
        if matches!(message.role, LegacyRole::System)
            && message.content.trim() == legacy.state.system.trim()
        {
            continue;
        }
        let created = legacy
            .created_at
            .checked_add_signed(Duration::microseconds(sequence))
            .unwrap_or(legacy.created_at);
        let message_id = stable_id(database_id, &legacy.id, &format!("message:{index}"));
        let mut source_ids = Vec::new();
        for (source_index, source) in message.sources.iter().enumerate() {
            if let Some(blob) = source_blob_item(
                blobs,
                database_id,
                &legacy.id,
                index,
                source_index,
                source,
                created,
            )? {
                let blob_id = blob.id;
                items.push(blob);
                let artifact = source_artifact_item(
                    database_id,
                    &legacy.id,
                    index,
                    source_index,
                    source,
                    blob_id,
                    previous_message.unwrap_or(conversation_id),
                    conversation_id,
                    created,
                );
                source_ids.push(artifact.id);
                items.push(artifact);
            } else {
                let artifact = source_artifact_without_blob(
                    database_id,
                    &legacy.id,
                    index,
                    source_index,
                    source,
                    previous_message.unwrap_or(conversation_id),
                    conversation_id,
                    created,
                );
                source_ids.push(artifact.id);
                items.push(artifact);
            }
        }

        let produced_by = if matches!(message.role, LegacyRole::Assistant) {
            let trigger = previous_message.unwrap_or(conversation_id);
            let task_id = stable_id(database_id, &legacy.id, &format!("task:{index}"));
            items.push(task_item(task_id, conversation_id, trigger, created));
            let run_id = stable_id(database_id, &legacy.id, &format!("run:{index}"));
            items.push(run_item(
                run_id,
                task_id,
                conversation_id,
                trigger,
                &source_ids,
                message,
                &legacy.state.model,
                created,
            ));
            Some(run_id)
        } else {
            None
        };
        items.push(message_item(
            message_id,
            conversation_id,
            previous_message,
            produced_by,
            sequence,
            message,
            created,
        ));
        previous_message = Some(message_id);
        sequence += 1;
    }

    items.push(ledger_item(
        stable_id(database_id, &legacy.id, "ledger"),
        conversation_id,
        database_id,
        &legacy,
        content_hash,
    ));
    store.insert_batch(items)?;
    Ok(ImportOutcome::Imported)
}

fn conversation_item(id: ItemId, legacy: &LegacyConversation) -> Item {
    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String(legacy.title.clone()));
    payload.insert("state".into(), Value::String("active".into()));
    payload.insert(
        "system_prompt".into(),
        Value::String(legacy.state.system.clone()),
    );
    payload.insert("provider".into(), Value::String("omlx".into()));
    payload.insert("model".into(), Value::String(legacy.state.model.clone()));
    payload.insert(
        "temperature".into(),
        Value::Float(legacy.state.temperature as f64),
    );
    payload.insert(
        "max_tokens".into(),
        Value::Int(i64::from(legacy.state.max_tokens)),
    );
    payload.insert("thinking".into(), Value::Bool(legacy.state.thinking));
    payload.insert("web_access".into(), Value::Bool(legacy.state.web_access));
    payload.insert(
        "enabled_tools".into(),
        Value::Array(if legacy.state.web_access {
            vec![Value::String("web".into())]
        } else {
            vec![]
        }),
    );
    payload.insert(
        "last_activity_at".into(),
        Value::String(legacy.updated_at.to_rfc3339()),
    );
    item(
        id,
        CONVERSATION_SCHEMA,
        payload,
        None,
        vec![],
        legacy.created_at,
        ActorKind::Human,
    )
}

fn message_item(
    id: ItemId,
    conversation_id: ItemId,
    previous: Option<ItemId>,
    produced_by: Option<ItemId>,
    sequence: i64,
    message: &LegacyMessage,
    created: DateTime<Utc>,
) -> Item {
    let role = match message.role {
        LegacyRole::System => "system",
        LegacyRole::User => "user",
        LegacyRole::Assistant => "assistant",
    };
    let mut payload = BTreeMap::from([
        ("body".into(), Value::String(message.content.clone())),
        ("format".into(), Value::String("markdown".into())),
        ("role".into(), Value::String(role.into())),
        ("sequence".into(), Value::Int(sequence)),
        (
            "status".into(),
            Value::String(
                if message.streaming {
                    "partial"
                } else {
                    "complete"
                }
                .into(),
            ),
        ),
    ]);
    if let Some(model) = &message.model {
        payload.insert("model".into(), Value::String(model.clone()));
    }
    if !message.reasoning.is_empty() {
        payload.insert("reasoning".into(), Value::String(message.reasoning.clone()));
    }
    if let Some(meta) = &message.meta {
        payload.insert("legacy_meta".into(), Value::String(meta.clone()));
    }
    let references = previous
        .map(|target| TypedReference {
            target,
            edge_type: EdgeType::InResponseTo,
            metadata: None,
        })
        .into_iter()
        .collect();
    let mut result = item(
        id,
        CHAT_MESSAGE_SCHEMA,
        payload,
        Some(conversation_id),
        references,
        created,
        match message.role {
            LegacyRole::System => ActorKind::System,
            LegacyRole::User => ActorKind::Human,
            LegacyRole::Assistant => ActorKind::Agent,
        },
    );
    result.produced_by = produced_by;
    result
}

fn task_item(id: ItemId, parent: ItemId, trigger: ItemId, created: DateTime<Utc>) -> Item {
    let payload = BTreeMap::from([
        (
            "title".into(),
            Value::String("Imported model response".into()),
        ),
        ("state".into(), Value::String("done".into())),
        (
            "source_app".into(),
            Value::String("localmodels-import".into()),
        ),
        (
            "output_schema".into(),
            Value::String(CHAT_MESSAGE_SCHEMA.into()),
        ),
    ]);
    item(
        id,
        TASK_SCHEMA,
        payload,
        Some(parent),
        vec![TypedReference {
            target: trigger,
            edge_type: EdgeType::OperatesOn,
            metadata: None,
        }],
        created,
        ActorKind::System,
    )
}

#[allow(clippy::too_many_arguments)]
fn run_item(
    id: ItemId,
    task_id: ItemId,
    parent: ItemId,
    trigger: ItemId,
    source_ids: &[ItemId],
    message: &LegacyMessage,
    fallback_model: &str,
    created: DateTime<Utc>,
) -> Item {
    let model = message.model.as_deref().unwrap_or(fallback_model);
    let mut payload = BTreeMap::from([
        (
            "agent_id".into(),
            Value::String("legacy-localmodels".into()),
        ),
        ("model".into(), Value::String(model.into())),
        (
            "prompt_hash".into(),
            Value::String(hex_hash(b"legacy-prompt-unavailable")),
        ),
        (
            "provider".into(),
            Value::String("legacy-localmodels".into()),
        ),
        ("endpoint".into(), Value::String("import".into())),
        (
            "status".into(),
            Value::String(
                if message.streaming {
                    "incomplete"
                } else {
                    "completed"
                }
                .into(),
            ),
        ),
        ("started_at".into(), Value::String(created.to_rfc3339())),
        ("finished_at".into(), Value::String(created.to_rfc3339())),
    ]);
    if !message.content.is_empty() {
        payload.insert(
            "result_summary".into(),
            Value::String(message.content.chars().take(500).collect()),
        );
    }
    let mut references = vec![
        TypedReference {
            target: task_id,
            edge_type: EdgeType::OperatesOn,
            metadata: None,
        },
        TypedReference {
            target: trigger,
            edge_type: EdgeType::DerivedFrom,
            metadata: None,
        },
    ];
    references.extend(source_ids.iter().map(|target| TypedReference {
        target: *target,
        edge_type: EdgeType::DerivedFrom,
        metadata: None,
    }));
    item(
        id,
        AGENT_RUN_SCHEMA,
        payload,
        Some(parent),
        references,
        created,
        ActorKind::Agent,
    )
}

fn source_blob_item(
    blobs: &dyn BlobStore,
    database_id: &str,
    conversation_id: &str,
    message_index: usize,
    source_index: usize,
    source: &LegacySource,
    created: DateTime<Utc>,
) -> Result<Option<Item>> {
    if source.content.is_empty() {
        return Ok(None);
    }
    let descriptor = blobs.put(source.content.as_bytes())?;
    let id = stable_id(
        database_id,
        conversation_id,
        &format!("source-blob:{message_index}:{source_index}"),
    );
    let payload = BTreeMap::from([
        ("sha256".into(), Value::String(descriptor.sha256)),
        (
            "mime_type".into(),
            Value::String("text/plain; charset=utf-8".into()),
        ),
        (
            "byte_length".into(),
            Value::Int(i64::try_from(descriptor.byte_length).unwrap_or(i64::MAX)),
        ),
        (
            "storage_kind".into(),
            Value::String(descriptor.storage_kind),
        ),
        ("locator".into(), Value::String(descriptor.locator)),
    ]);
    Ok(Some(item(
        id,
        CONTENT_BLOB_SCHEMA,
        payload,
        None,
        vec![],
        created,
        ActorKind::System,
    )))
}

#[allow(clippy::too_many_arguments)]
fn source_artifact_item(
    database_id: &str,
    legacy_id: &str,
    message_index: usize,
    source_index: usize,
    source: &LegacySource,
    blob_id: ItemId,
    trigger: ItemId,
    parent: ItemId,
    created: DateTime<Utc>,
) -> Item {
    source_artifact(
        database_id,
        legacy_id,
        message_index,
        source_index,
        source,
        trigger,
        parent,
        created,
        Some(blob_id),
    )
}

#[allow(clippy::too_many_arguments)]
fn source_artifact_without_blob(
    database_id: &str,
    legacy_id: &str,
    message_index: usize,
    source_index: usize,
    source: &LegacySource,
    trigger: ItemId,
    parent: ItemId,
    created: DateTime<Utc>,
) -> Item {
    source_artifact(
        database_id,
        legacy_id,
        message_index,
        source_index,
        source,
        trigger,
        parent,
        created,
        None,
    )
}

#[allow(clippy::too_many_arguments)]
fn source_artifact(
    database_id: &str,
    legacy_id: &str,
    message_index: usize,
    source_index: usize,
    source: &LegacySource,
    trigger: ItemId,
    parent: ItemId,
    created: DateTime<Utc>,
    blob_id: Option<ItemId>,
) -> Item {
    let id = stable_id(
        database_id,
        legacy_id,
        &format!("source:{message_index}:{source_index}"),
    );
    let payload = BTreeMap::from([
        ("title".into(), Value::String(source.title.clone())),
        ("source_url".into(), Value::String(source.url.clone())),
        (
            "capture_context".into(),
            Value::String("imported from LocalModels conversation".into()),
        ),
    ]);
    let mut references = vec![TypedReference {
        target: trigger,
        edge_type: EdgeType::RelatesTo,
        metadata: None,
    }];
    if let Some(target) = blob_id {
        references.push(TypedReference {
            target,
            edge_type: EdgeType::Attaches,
            metadata: None,
        });
    }
    item(
        id,
        WEBPAGE_SCHEMA,
        payload,
        Some(parent),
        references,
        created,
        ActorKind::System,
    )
}

fn ledger_item(
    id: ItemId,
    conversation_id: ItemId,
    database_id: &str,
    legacy: &LegacyConversation,
    content_hash: String,
) -> Item {
    let payload = BTreeMap::from([
        ("source_kind".into(), Value::String("localmodels".into())),
        (
            "source_database_id".into(),
            Value::String(database_id.into()),
        ),
        (
            "source_conversation_id".into(),
            Value::String(legacy.id.clone()),
        ),
        (
            "source_revision".into(),
            Value::Int(i64::try_from(legacy.revision).unwrap_or(i64::MAX)),
        ),
        ("source_content_hash".into(), Value::String(content_hash)),
        (
            "imported_conversation_id".into(),
            Value::String(conversation_id.to_string()),
        ),
        ("state".into(), Value::String("completed".into())),
        ("imported_at".into(), Value::String(Utc::now().to_rfc3339())),
    ]);
    item(
        id,
        AI_IMPORT_LEDGER_SCHEMA,
        payload,
        Some(conversation_id),
        vec![TypedReference {
            target: conversation_id,
            edge_type: EdgeType::RelatesTo,
            metadata: None,
        }],
        Utc::now(),
        ActorKind::System,
    )
}

fn item(
    id: ItemId,
    schema: &str,
    payload: BTreeMap<String, Value>,
    parent: Option<ItemId>,
    references: Vec<TypedReference>,
    created: DateTime<Utc>,
    author_kind: ActorKind,
) -> Item {
    Item {
        id,
        schema: schema.into(),
        payload,
        created,
        modified: created,
        author: "system:localmodels-import".into(),
        author_kind,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec!["ai/imported/localmodels".into()],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: Some("discussion".into()),
        produced_by: None,
        version: Some("1.0.0".into()),
        batch_id: None,
        references,
        parent,
    }
}

fn stable_id(database_id: &str, conversation_id: &str, kind: &str) -> Uuid {
    Uuid::new_v5(
        &IMPORT_NAMESPACE,
        format!("{database_id}\0{conversation_id}\0{kind}").as_bytes(),
    )
}

fn hex_hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn parse_timestamp(value: &str) -> Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| Error::Invalid(format!("invalid legacy timestamp '{value}': {error}")))
}

fn payload_string(item: &Item, key: &str) -> Option<String> {
    match item.payload.get(key) {
        Some(Value::String(value)) => Some(value.clone()),
        _ => None,
    }
}

fn payload_i64(item: &Item, key: &str) -> Option<i64> {
    match item.payload.get(key) {
        Some(Value::Int(value)) => Some(*value),
        _ => None,
    }
}

fn default_temperature() -> f32 {
    0.2
}

fn default_max_tokens() -> u32 {
    2048
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::FileBlobStore;
    use impress_core::sqlite_store::StoreConfig;

    fn write_source(path: &Path) {
        let connection = Connection::open(path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE conversations (
                    id TEXT PRIMARY KEY, title TEXT NOT NULL, state_json TEXT NOT NULL,
                    revision INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
                 );",
            )
            .unwrap();
        let state = serde_json::json!({
            "model": "mlx-community/model",
            "system": "Be useful",
            "temperature": 0.2,
            "maxTokens": 2048,
            "thinking": true,
            "webAccess": true,
            "messages": [
                {"role": "user", "content": "Question"},
                {"role": "assistant", "content": "Answer", "reasoning": "Because", "sources": [
                    {"url": "https://example.test", "title": "Example", "content": "Evidence"}
                ]}
            ]
        });
        connection
            .execute(
                "INSERT INTO conversations VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                rusqlite::params![
                    "legacy-1",
                    "Imported chat",
                    state.to_string(),
                    3_u64,
                    "2026-01-02T03:04:05Z",
                    "2026-01-02T04:05:06Z"
                ],
            )
            .unwrap();
    }

    #[test]
    fn imports_atomically_and_skips_an_unchanged_restart() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("chats.sqlite3");
        write_source(&source);
        let store =
            Arc::new(SqliteItemStore::open_in_memory_with_config(StoreConfig::default()).unwrap());
        let blobs = FileBlobStore::open(temp.path().join("blobs")).unwrap();

        let first = migrate_localmodels(store.clone(), &blobs, &source, false).unwrap();
        assert_eq!(first.imported, 1);
        assert_eq!(
            store
                .count(&ItemQuery {
                    schema: Some(CONVERSATION_SCHEMA.into()),
                    ..Default::default()
                })
                .unwrap(),
            1
        );
        assert_eq!(
            store
                .count(&ItemQuery {
                    schema: Some(AGENT_RUN_SCHEMA.into()),
                    ..Default::default()
                })
                .unwrap(),
            1
        );
        assert_eq!(
            store
                .count(&ItemQuery {
                    schema: Some(AI_IMPORT_LEDGER_SCHEMA.into()),
                    ..Default::default()
                })
                .unwrap(),
            1
        );

        let second = migrate_localmodels(store.clone(), &blobs, &source, false).unwrap();
        assert_eq!(second.skipped_unchanged, 1);
        assert_eq!(
            store
                .count(&ItemQuery {
                    schema: Some(CONVERSATION_SCHEMA.into()),
                    ..Default::default()
                })
                .unwrap(),
            1
        );

        let source_connection = Connection::open(&source).unwrap();
        source_connection
            .execute(
                "UPDATE conversations SET revision = 4, title = 'Changed after import' WHERE id = 'legacy-1'",
                [],
            )
            .unwrap();
        drop(source_connection);

        let changed = migrate_localmodels(store.clone(), &blobs, &source, false).unwrap();
        assert_eq!(changed.changed_after_import, 1);
        assert_eq!(changed.imported, 0);
        assert_eq!(
            store
                .count(&ItemQuery {
                    schema: Some(CONVERSATION_SCHEMA.into()),
                    ..Default::default()
                })
                .unwrap(),
            1
        );
        assert_eq!(
            store
                .count(&ItemQuery {
                    schema: Some(AI_IMPORT_LEDGER_SCHEMA.into()),
                    ..Default::default()
                })
                .unwrap(),
            1
        );
    }

    #[test]
    fn dry_run_writes_neither_graph_nor_blob() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("chats.sqlite3");
        write_source(&source);
        let store = Arc::new(SqliteItemStore::open_in_memory().unwrap());
        let blob_root = temp.path().join("blobs");
        let blobs = FileBlobStore::open(&blob_root).unwrap();
        let report = migrate_localmodels(store.clone(), &blobs, &source, true).unwrap();
        assert_eq!(report.imported, 1);
        assert_eq!(store.count(&ItemQuery::default()).unwrap(), 0);
        assert_eq!(std::fs::read_dir(blob_root).unwrap().count(), 0);
    }
}
