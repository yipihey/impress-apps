//! The ADR-0005 §9 validation gate: the enrichment pipeline end-to-end
//! through spawn rule → DAG → scheduler → executors → provenance →
//! human-review checkpoint, against a real (in-memory) SQLite item store
//! and a deterministic fake source. "If it works, the architecture is
//! validated at scale" — this is the smallest complete instance.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use chrono::Utc;
use imbib_core::enrichment::priority::SourcePriority;
use impel_core::{create_task_dag, Scheduler, SchedulerConfig, SpawnRule, TaskStoreApi};
use impel_enrichment::metadata_resolve::ConfiguredSource;
use impel_enrichment::{
    classify::HeuristicClassifier, EnrichmentSpawnRule, KeywordTagExecutor,
    MetadataResolveExecutor, BIBLIOGRAPHY_ENTRY_SCHEMA,
};
use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
use impress_core::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use impress_core::query::ItemQuery;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_core::task::TaskState;
use impress_sources::types::{author_from_names, PaperMetadata, SearchQuery, SearchResult};
use impress_sources::{SourceError, SourcePlugin};
use uuid::Uuid;

// ── fixtures ───────────────────────────────────────────────────────────

/// Deterministic source: knows one paper by DOI.
struct FakeAds;

#[async_trait]
impl SourcePlugin for FakeAds {
    fn id(&self) -> &str {
        "ads"
    }
    fn display_name(&self) -> &str {
        "Fake ADS"
    }
    fn requires_credentials(&self) -> bool {
        false
    }
    async fn search(
        &self,
        _query: &SearchQuery,
        _credentials: Option<&str>,
    ) -> Result<SearchResult, SourceError> {
        Err(SourceError::Parse("search not used in this test".into()))
    }
    async fn fetch_by_id(
        &self,
        id: &str,
        _credentials: Option<&str>,
    ) -> Result<PaperMetadata, SourceError> {
        if id != "10.1000/xyz" {
            return Err(SourceError::Parse(format!("unknown id {id}")));
        }
        let mut m = PaperMetadata::with_source_id("2026Fake.....1A");
        m.doi = Some("10.1000/xyz".into());
        m.title = "Hydrodynamic simulation of galaxy formation".into();
        m.authors = vec![
            author_from_names("Abel", Some("T.".into())),
            author_from_names("Curie", Some("M.".into())),
        ];
        m.abstract_text = Some(
            "We present a hydrodynamic simulation of galaxy formation with dark energy.".into(),
        );
        m.year = Some(2026);
        m.venue = Some("ApJ".into());
        Ok(m)
    }
}

fn bibliography_entry(doi: &str, title: &str) -> Item {
    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String(title.into()));
    payload.insert("doi".into(), Value::String(doi.into()));
    Item {
        id: Uuid::new_v4(),
        schema: BIBLIOGRAPHY_ENTRY_SCHEMA.into(),
        payload,
        created: Utc::now(),
        modified: Utc::now(),
        author: "tom".into(),
        author_kind: ActorKind::Human,
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
    }
}

fn pipeline_scheduler(store: Arc<SqliteItemStore>, threshold: f64) -> Scheduler {
    let mut sched = Scheduler::new(
        store,
        SchedulerConfig {
            actor: "impel".into(),
            batch: 8,
            start_delay: Duration::ZERO,
            poll_interval: Duration::ZERO,
            retry_base_ms: 0, // tight-loop tests: no retry delay
        },
    );
    sched.register(Arc::new(MetadataResolveExecutor::new(
        vec![ConfiguredSource {
            plugin: Arc::new(FakeAds),
            credentials: None,
        }],
        SourcePriority::default(),
    )));
    sched.register(Arc::new(KeywordTagExecutor::new(
        Arc::new(HeuristicClassifier::default_vocabulary()),
        threshold,
    )));
    sched
}

fn state_of(store: &SqliteItemStore, id: impress_core::item::ItemId) -> TaskState {
    let item = TaskStoreApi::get_item(store, id).unwrap().unwrap();
    match item.payload.get("state") {
        Some(Value::String(s)) => TaskState::parse(s).unwrap(),
        other => panic!("no state: {other:?}"),
    }
}

// ── the gate ───────────────────────────────────────────────────────────

#[tokio::test]
async fn pipeline_enriches_and_autotags_when_confident() {
    let store = Arc::new(SqliteItemStore::open_in_memory().unwrap());
    let entry = bibliography_entry("10.1000/xyz", "old title");
    let entry_id = TaskStoreApi::create_item(store.as_ref(), entry.clone()).unwrap();

    // Spawn the DAG the way impel will: rule → specs → task items.
    let trigger = TaskStoreApi::get_item(store.as_ref(), entry_id)
        .unwrap()
        .unwrap();
    let specs = EnrichmentSpawnRule
        .spawn(&trigger, store.as_ref())
        .await
        .unwrap();
    let task_ids = create_task_dag(store.as_ref(), &specs, "impel").unwrap();

    // Threshold 0.3: the fake abstract hits ≥1 keyword in each matched
    // tag's list, comfortably confident.
    let sched = pipeline_scheduler(store.clone(), 0.3);

    // Pass 1: metadata-resolve runs (keyword-tag is DAG-blocked).
    let r1 = sched.run_once().await.unwrap();
    assert_eq!(r1.completed, 1, "{r1:?}");
    assert_eq!(state_of(&store, task_ids[0]), TaskState::Done);
    assert_eq!(state_of(&store, task_ids[1]), TaskState::Pending);

    // The publication was enriched FILL-ONLY: empty fields (abstract,
    // venue) take the source's values, but the record's own non-empty
    // title is PRESERVED — the record outranks the sources. The previous
    // behavior (source title replacing "old title") silently reverted
    // user corrections on every resolve, and this test enshrined it.
    let publication = TaskStoreApi::get_item(store.as_ref(), entry_id)
        .unwrap()
        .unwrap();
    assert!(matches!(publication.payload.get("abstract_text"),
                     Some(Value::String(a)) if a.contains("hydrodynamic")));
    assert!(matches!(publication.payload.get("title"),
                     Some(Value::String(t)) if t == "old title"));
    assert!(matches!(publication.payload.get("venue"),
                     Some(Value::String(v)) if v == "ApJ"));
    // Authors land where imbib reads them (author_text/authors_json), not
    // under the reader-less bare `authors` key.
    assert!(matches!(publication.payload.get("author_text"),
                     Some(Value::String(a)) if a.contains("Abel, T.")));
    assert!(matches!(publication.payload.get("authors_json"),
                     Some(Value::String(j)) if j.contains("\"family_name\":\"Abel\"")));
    assert!(!publication.payload.contains_key("authors"));

    // Pass 2: keyword-tag unblocked, classifies confidently, tags apply.
    let r2 = sched.run_once().await.unwrap();
    assert_eq!(r2.completed, 1, "{r2:?}");
    assert_eq!(state_of(&store, task_ids[1]), TaskState::Done);

    let publication = TaskStoreApi::get_item(store.as_ref(), entry_id)
        .unwrap()
        .unwrap();
    assert!(
        publication.tags.iter().any(|t| t.starts_with("ai/")),
        "expected ai/* tags, got {:?}",
        publication.tags
    );

    // Provenance: both tasks carry ProducedBy edges to agent-run items.
    for id in &task_ids {
        let task = TaskStoreApi::get_item(store.as_ref(), *id)
            .unwrap()
            .unwrap();
        assert!(
            task.references
                .iter()
                .any(|r| r.edge_type == impress_core::reference::EdgeType::ProducedBy),
            "task {id} missing agent-run provenance"
        );
    }
}

#[tokio::test]
async fn low_confidence_suspends_until_human_approves() {
    let store = Arc::new(SqliteItemStore::open_in_memory().unwrap());
    let entry = bibliography_entry("10.1000/xyz", "old title");
    let entry_id = TaskStoreApi::create_item(store.as_ref(), entry).unwrap();
    let trigger = TaskStoreApi::get_item(store.as_ref(), entry_id)
        .unwrap()
        .unwrap();
    let specs = EnrichmentSpawnRule
        .spawn(&trigger, store.as_ref())
        .await
        .unwrap();
    let task_ids = create_task_dag(store.as_ref(), &specs, "impel").unwrap();

    // Threshold 0.9 (review floor 0.63): the heuristic's 2-of-3-keyword
    // hits (0.67) land in the borderline band → a review opens. Anything
    // below the floor is DROPPED, not reviewed — with the old all-or-
    // nothing gate an impossible threshold reviewed every paper, which is
    // how 1,018 reviews piled up unanswered in production.
    let sched = pipeline_scheduler(store.clone(), 0.9);

    // Pass 1 completes metadata-resolve; pass 2 suspends keyword-tag.
    sched.run_once().await.unwrap();
    let r2 = sched.run_once().await.unwrap();
    assert_eq!(r2.suspended, 1, "{r2:?}");
    assert_eq!(state_of(&store, task_ids[1]), TaskState::Running);

    // The review is queryable, carries the proposals, and blocks passes.
    let (unresolved, _) = TaskStoreApi::reviews_for(store.as_ref(), task_ids[1]).unwrap();
    assert_eq!(unresolved.len(), 1);
    let proposed = match unresolved[0].payload.get("context_proposed_tags") {
        Some(Value::Array(a)) => a.len(),
        other => panic!("no proposals in review: {other:?}"),
    };
    assert!(proposed >= 1);
    let r3 = sched.run_once().await.unwrap();
    assert_eq!(r3.suspended, 1, "still waiting: {r3:?}");

    // Tom approves.
    store
        .apply_operation(OperationSpec {
            target_id: unresolved[0].id,
            op_type: OperationType::SetPayload(
                "resolution".into(),
                Value::String("approved".into()),
            ),
            intent: OperationIntent::Editorial,
            reason: None,
            batch_id: None,
            author: "tom".into(),
            author_kind: ActorKind::Human,
            retention: RetentionTier::Durable,
        })
        .unwrap();

    // Resume pass applies the reviewed tags and completes.
    let r4 = sched.run_once().await.unwrap();
    assert_eq!(r4.resumed, 1, "{r4:?}");
    assert_eq!(state_of(&store, task_ids[1]), TaskState::Done);
    let publication = TaskStoreApi::get_item(store.as_ref(), entry_id)
        .unwrap()
        .unwrap();
    assert!(
        publication.tags.iter().any(|t| t.starts_with("ai/")),
        "approved tags applied: {:?}",
        publication.tags
    );
}

// ── the trigger-spelling contract ──────────────────────────────────────

/// The spawn trigger must match the ref imbib ACTUALLY WRITES.
///
/// Until 2026-07-29 `BIBLIOGRAPHY_ENTRY_SCHEMA` was `bibliography-entry@1.0.0`
/// — a spelling no writer in this repo has ever emitted. imbib writes
/// `imbib/bibliography-entry` (imbib-core `unified::conversion`), and the store
/// matches `items.schema_ref` by EXACT EQUALITY, so the enrichment trigger
/// selected zero rows and the pipeline never spawned a single task. There was
/// no error, no log line, and no failing test: `pipeline_enriches_and_...`
/// above seeds its OWN fixture through the same constant, so writer and reader
/// agreed with each other while both disagreed with production. That is the
/// whole bug class — a test can only catch it by seeding through the REAL
/// writer, which is what this one does.
///
/// Precedent: `sections_are_written_under_the_bare_ref_the_swift_readers_query`
/// in crates/imprint-service/tests/sections_roundtrip.rs.
#[test]
fn enrichment_trigger_matches_the_ref_imbib_actually_writes() {
    let store = SqliteItemStore::open_in_memory().unwrap();

    // Seed through imbib's REAL writer — not a literal, not our own constant.
    // If imbib ever changes the ref it emits, this line changes with it and
    // the assertions below fail loudly instead of the pipeline going quiet.
    let publication = imbib_core::domain::Publication::new(
        "abel2026".into(),
        "article".into(),
        "Hydrodynamic simulation of galaxy formation".into(),
    );
    let row = imbib_core::unified::conversion::publication_to_item(&publication, None);
    let seeded_ref = row.schema.clone();
    let entry_id = TaskStoreApi::create_item(&store, row).unwrap();

    // What the trigger asks for. Must find the row imbib just wrote.
    let trigger_ref = EnrichmentSpawnRule.trigger_schema().to_string();
    assert_eq!(
        trigger_ref, seeded_ref,
        "the enrichment trigger must name the ref imbib's writer emits; \
         schema-refs.json records the canonical spelling"
    );
    let matched = ItemStore::query(
        &store,
        &ItemQuery {
            schema: Some(trigger_ref.clone()),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(
        matched.len(),
        1,
        "trigger_schema() {trigger_ref:?} matched NOTHING against a row written \
         by imbib's own publication_to_item ({seeded_ref:?}). This is the \
         silent-zero-rows bug: taskd would scan forever and spawn no tasks."
    );
    assert_eq!(matched[0].id, entry_id);

    // The dead spelling must match nothing. If this ever returns rows, some
    // writer started emitting it and schema-refs.json is now wrong.
    let dead = ItemStore::query(
        &store,
        &ItemQuery {
            // schema-ref-lint:allow — naming the dead spelling is the point.
            schema: Some("bibliography-entry@1.0.0".into()),
            ..Default::default()
        },
    )
    .unwrap();
    assert!(
        dead.is_empty(),
        "`bibliography-entry@1.0.0` is written by nothing; it must match no rows"
    );
}

/// …and the rule actually yields the DAG for such a row, so the fix is proven
/// end-to-end at the seam and not just at the string level.
#[tokio::test]
async fn spawn_rule_yields_the_dag_for_a_real_imbib_row() {
    let store = Arc::new(SqliteItemStore::open_in_memory().unwrap());
    let publication = imbib_core::domain::Publication::new(
        "curie2026".into(),
        "article".into(),
        "Dark energy constraints".into(),
    );
    let row = imbib_core::unified::conversion::publication_to_item(&publication, None);
    let id = TaskStoreApi::create_item(store.as_ref(), row).unwrap();

    let trigger = TaskStoreApi::get_item(store.as_ref(), id).unwrap().unwrap();
    assert_eq!(trigger.schema, EnrichmentSpawnRule.trigger_schema());

    let specs = EnrichmentSpawnRule
        .spawn(&trigger, store.as_ref())
        .await
        .unwrap();
    assert_eq!(specs.len(), 2, "metadata-resolve ← keyword-tag");
    assert!(specs.iter().all(|s| s.operates_on == Some(id)));
}

// ── the 2026-09 per-proposal review policy ─────────────────────────────

/// Fixed-confidence classifier: one proposal per (tag, confidence) pair.
struct FixedClassifier(Vec<(&'static str, f64)>);

#[async_trait]
impl impel_enrichment::Classifier for FixedClassifier {
    fn model_id(&self) -> &str {
        "fixed-test"
    }
    async fn classify(
        &self,
        _title: &str,
        _abstract_text: &str,
    ) -> Vec<impel_enrichment::classify::Classification> {
        self.0
            .iter()
            .map(
                |(tag, confidence)| impel_enrichment::classify::Classification {
                    tag: (*tag).into(),
                    confidence: *confidence,
                },
            )
            .collect()
    }
}

fn band_scheduler(store: Arc<SqliteItemStore>, threshold: f64) -> Scheduler {
    let mut sched = Scheduler::new(
        store,
        SchedulerConfig {
            actor: "impel".into(),
            batch: 8,
            start_delay: Duration::ZERO,
            poll_interval: Duration::ZERO,
            retry_base_ms: 0,
        },
    );
    sched.register(Arc::new(MetadataResolveExecutor::new(
        vec![ConfiguredSource {
            plugin: Arc::new(FakeAds),
            credentials: None,
        }],
        SourcePriority::default(),
    )));
    sched.register(Arc::new(KeywordTagExecutor::new(
        Arc::new(FixedClassifier(vec![
            ("ai/topic/confident", 0.9),
            ("ai/topic/borderline", 0.45),
            ("ai/topic/weak", 0.2),
        ])),
        threshold,
    )));
    sched
}

/// Per-proposal policy: ≥ threshold applies immediately, the borderline
/// band (≥ 0.7·threshold) goes to review ALONE, below the floor is
/// dropped. The old all() gate held the 0.9 tag hostage to the 0.2 one
/// and reviewed the whole set — one review per paper, library-wide.
#[tokio::test]
async fn confident_tags_apply_while_only_the_band_is_reviewed() {
    let s = Arc::new(SqliteItemStore::open_in_memory().unwrap());
    let entry = bibliography_entry("10.1000/xyz", "old title");
    let entry_id = TaskStoreApi::create_item(s.as_ref(), entry).unwrap();
    let trigger = TaskStoreApi::get_item(s.as_ref(), entry_id)
        .unwrap()
        .unwrap();
    let specs = EnrichmentSpawnRule
        .spawn(&trigger, s.as_ref())
        .await
        .unwrap();
    let task_ids = create_task_dag(s.as_ref(), &specs, "impel").unwrap();

    let sched = band_scheduler(s.clone(), 0.5); // floor = 0.35
    sched.run_once().await.unwrap(); // metadata-resolve
    let r2 = sched.run_once().await.unwrap(); // keyword-tag
    assert_eq!(r2.suspended, 1, "{r2:?}");

    // The confident tag applied IMMEDIATELY, before any human decision.
    let publication = TaskStoreApi::get_item(s.as_ref(), entry_id)
        .unwrap()
        .unwrap();
    assert!(publication.tags.iter().any(|t| t == "ai/topic/confident"));
    assert!(!publication.tags.iter().any(|t| t == "ai/topic/borderline"));
    assert!(!publication.tags.iter().any(|t| t == "ai/topic/weak"));

    // The review lists ONLY the band (with its confidence), never the
    // applied or dropped proposals as pending decisions.
    let (unresolved, _) = TaskStoreApi::reviews_for(s.as_ref(), task_ids[1]).unwrap();
    assert_eq!(unresolved.len(), 1);
    match unresolved[0].payload.get("context_proposed_tags") {
        Some(Value::Array(tags)) => {
            assert_eq!(tags.len(), 1, "band only: {tags:?}");
            assert!(matches!(&tags[0], Value::String(t) if t == "ai/topic/borderline"));
        }
        other => panic!("no proposals: {other:?}"),
    }
    match unresolved[0].payload.get("context_applied_tags") {
        Some(Value::Array(tags)) => assert_eq!(tags.len(), 1),
        other => panic!("applied tags not recorded for the reviewer: {other:?}"),
    }

    // Approving applies the band tag on resume.
    s.apply_operation(OperationSpec {
        target_id: unresolved[0].id,
        op_type: OperationType::SetPayload("resolution".into(), Value::String("approved".into())),
        intent: OperationIntent::Editorial,
        reason: None,
        batch_id: None,
        author: "tom".into(),
        author_kind: ActorKind::Human,
        retention: RetentionTier::Durable,
    })
    .unwrap();
    let r4 = sched.run_once().await.unwrap();
    assert_eq!(r4.resumed, 1, "{r4:?}");
    let publication = TaskStoreApi::get_item(s.as_ref(), entry_id)
        .unwrap()
        .unwrap();
    assert!(publication.tags.iter().any(|t| t == "ai/topic/borderline"));
}

/// An `"expired"` resolution (impel-taskd's hourly sweep over unanswered
/// reviews) completes the task WITHOUT applying the band — the queue is
/// capacity-bounded, and silence is a decision.
#[tokio::test]
async fn expired_resolution_completes_without_applying_the_band() {
    let s = Arc::new(SqliteItemStore::open_in_memory().unwrap());
    let entry = bibliography_entry("10.1000/xyz", "old title");
    let entry_id = TaskStoreApi::create_item(s.as_ref(), entry).unwrap();
    let trigger = TaskStoreApi::get_item(s.as_ref(), entry_id)
        .unwrap()
        .unwrap();
    let specs = EnrichmentSpawnRule
        .spawn(&trigger, s.as_ref())
        .await
        .unwrap();
    let task_ids = create_task_dag(s.as_ref(), &specs, "impel").unwrap();

    let sched = band_scheduler(s.clone(), 0.5);
    sched.run_once().await.unwrap();
    let r2 = sched.run_once().await.unwrap();
    assert_eq!(r2.suspended, 1, "{r2:?}");

    let (unresolved, _) = TaskStoreApi::reviews_for(s.as_ref(), task_ids[1]).unwrap();
    s.apply_operation(OperationSpec {
        target_id: unresolved[0].id,
        op_type: OperationType::SetPayload("resolution".into(), Value::String("expired".into())),
        intent: OperationIntent::Routine,
        reason: Some("review expired unanswered".into()),
        batch_id: None,
        author: "impel-taskd/expiry".into(),
        author_kind: ActorKind::Agent,
        retention: RetentionTier::Durable,
    })
    .unwrap();

    let r3 = sched.run_once().await.unwrap();
    assert_eq!(r3.resumed, 1, "{r3:?}");
    assert_eq!(state_of(&s, task_ids[1]), TaskState::Done);
    let publication = TaskStoreApi::get_item(s.as_ref(), entry_id)
        .unwrap()
        .unwrap();
    assert!(publication.tags.iter().any(|t| t == "ai/topic/confident"));
    assert!(
        !publication.tags.iter().any(|t| t == "ai/topic/borderline"),
        "expired ⇒ band NOT applied: {:?}",
        publication.tags
    );
}

/// The run record names the OUTCOME, not a count, and says whether a
/// model was involved. "3 tag proposal(s)" left the actual result — which
/// tags, at what confidence — discoverable only by diffing the paper.
#[tokio::test]
async fn the_run_record_names_the_tags_and_the_executor_kind() {
    let s = Arc::new(SqliteItemStore::open_in_memory().unwrap());
    let entry = bibliography_entry("10.1000/xyz", "old title");
    let entry_id = TaskStoreApi::create_item(s.as_ref(), entry).unwrap();
    let trigger = TaskStoreApi::get_item(s.as_ref(), entry_id)
        .unwrap()
        .unwrap();
    let specs = EnrichmentSpawnRule
        .spawn(&trigger, s.as_ref())
        .await
        .unwrap();
    let task_ids = create_task_dag(s.as_ref(), &specs, "impel").unwrap();

    let sched = band_scheduler(s.clone(), 0.5); // applies 0.9, reviews 0.45, drops 0.2
    sched.run_once().await.unwrap();
    sched.run_once().await.unwrap();

    let runs = ItemStore::query(
        s.as_ref(),
        &ItemQuery {
            schema: Some("agent-run@1.0.0".into()),
            ..Default::default()
        },
    )
    .unwrap();
    let tagging_run = runs
        .iter()
        .find(|r| {
            matches!(r.payload.get("agent_id"),
                           Some(Value::String(a)) if a == "impel/keyword-tag")
        })
        .expect("keyword-tag recorded a run");

    let summary = match tagging_run.payload.get("result_summary") {
        Some(Value::String(s)) => s.clone(),
        other => panic!("no result_summary: {other:?}"),
    };
    assert!(
        summary.contains("ai/topic/confident"),
        "the applied tag is named: {summary:?}"
    );
    assert!(
        summary.contains("ai/topic/borderline"),
        "the reviewed tag is named: {summary:?}"
    );
    assert!(
        summary.contains("below the review floor"),
        "the dropped proposal is accounted for: {summary:?}"
    );
    assert!(
        matches!(tagging_run.payload.get("executor_kind"),
                 Some(Value::String(k)) if k == "deterministic"),
        "a keyword table is not a model: {:?}",
        tagging_run.payload.get("executor_kind")
    );

    // The DAG's first stage says the same about itself.
    let resolve_run = runs
        .iter()
        .find(|r| {
            matches!(r.payload.get("agent_id"),
                           Some(Value::String(a)) if a == "impel/metadata-resolve")
        })
        .expect("metadata-resolve recorded a run");
    assert!(matches!(resolve_run.payload.get("executor_kind"),
                     Some(Value::String(k)) if k == "deterministic"));
    let _ = task_ids;
}
