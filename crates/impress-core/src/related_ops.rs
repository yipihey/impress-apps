//! Cross-kind relations (ADR-0022 D8).
//!
//! The store has carried a typed edge table since the beginning — `Cites`,
//! `Contains`, `InResponseTo`, `ProducedBy` and the rest of
//! [`crate::reference::EdgeType`] — but every app read it in one direction, for
//! one edge type, for one record kind. The manuscript knew which figures it
//! contained; the figure did not know which manuscript embedded it.
//!
//! [`related_items`] walks the edges of an item in **both** directions across
//! **all** edge types and joins through to the target's kind and title, which
//! is what a single generic "Related" info-pane section needs to render for
//! every kind: papers a manuscript cites, messages that produced a task,
//! figures embedded in a draft, and each of those seen from the other end.

// The walk is koine's (`koine_store_query::ops`, docs/plan-koine-kit-moves.md
// KM9), over the store port; SQLite answers its incoming half from
// `item_references`. The tests below keep proving it over SQLite.
pub use koine_store_query::ops::{
    related_items, RelatedItem, DEFAULT_RELATED_LIMIT as DEFAULT_LIMIT, DIRECTION_INCOMING,
    DIRECTION_OUTGOING, MAX_RELATED_LIMIT as MAX_LIMIT,
};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::{Item, Priority, Value, Visibility};
    use crate::reference::EdgeType;
    use crate::reference::TypedReference;
    use crate::sqlite_store::SqliteItemStore;
    use crate::store::FieldMutation;
    use crate::store::{ItemStore, StoreError};
    use chrono::Utc;
    use std::collections::BTreeMap;
    use uuid::Uuid;

    fn open() -> SqliteItemStore {
        SqliteItemStore::open_in_memory().expect("open in-memory store")
    }

    fn make(store: &SqliteItemStore, schema: &str, title: &str) -> String {
        let now = Utc::now();
        let mut payload: BTreeMap<String, Value> = BTreeMap::new();
        payload.insert("title".into(), Value::String(title.into()));
        let item = Item {
            id: Uuid::new_v4(),
            schema: crate::SchemaRef::from_stored(schema.to_owned()),
            payload,
            created: now,
            modified: now,
            author: store.default_author.clone(),
            author_kind: store.default_author_kind,
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
        };
        store.insert(item).expect("insert").to_string()
    }

    fn link(store: &SqliteItemStore, source: &str, target: &str, edge: EdgeType) {
        store
            .update(
                Uuid::parse_str(source).unwrap(),
                vec![FieldMutation::AddReference(TypedReference {
                    target: Uuid::parse_str(target).unwrap(),
                    edge_type: edge,
                    metadata: None,
                })],
            )
            .expect("add reference");
    }

    fn titles(rows: &[RelatedItem]) -> Vec<&str> {
        rows.iter().map(|r| r.title.as_str()).collect()
    }

    #[test]
    fn outgoing_edges_are_reported() {
        let store = open();
        let manuscript = make(&store, "manuscript", "Draft II");
        let paper_b = make(&store, "imbib/bibliography-entry", "Bahcall 1980");
        let paper_a = make(&store, "imbib/bibliography-entry", "Aaronson 1979");
        link(&store, &manuscript, &paper_b, EdgeType::Cites);
        link(&store, &manuscript, &paper_a, EdgeType::Cites);

        let rows = related_items(&store, &manuscript, 10).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(
            titles(&rows),
            vec!["Aaronson 1979", "Bahcall 1980"],
            "ordered by edge type then title"
        );
        for r in &rows {
            assert_eq!(r.edge_type, "Cites");
            assert_eq!(r.direction, DIRECTION_OUTGOING);
            assert_eq!(r.schema_ref, "imbib/bibliography-entry");
        }
    }

    /// The half that did not exist before: the cited paper learning who cites
    /// it, the figure learning which manuscript embeds it.
    #[test]
    fn incoming_edges_are_reported() {
        let store = open();
        let manuscript = make(&store, "manuscript", "Draft II");
        let figure = make(&store, "figure", "Rotation curve");
        link(&store, &manuscript, &figure, EdgeType::Contains);

        let rows = related_items(&store, &figure, 10).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, manuscript);
        assert_eq!(rows[0].schema_ref, "manuscript");
        assert_eq!(rows[0].title, "Draft II");
        assert_eq!(rows[0].edge_type, "Contains");
        assert_eq!(rows[0].direction, DIRECTION_INCOMING);
    }

    #[test]
    fn both_directions_come_back_from_one_call() {
        let store = open();
        let manuscript = make(&store, "manuscript", "Draft II");
        let figure = make(&store, "figure", "Rotation curve");
        let review = make(&store, "email-message", "Re: Draft II");
        link(&store, &manuscript, &figure, EdgeType::Contains);
        link(&store, &review, &manuscript, EdgeType::Discusses);

        let rows = related_items(&store, &manuscript, 10).unwrap();
        assert_eq!(rows.len(), 2);
        let contains = rows.iter().find(|r| r.edge_type == "Contains").unwrap();
        assert_eq!(contains.direction, DIRECTION_OUTGOING);
        assert_eq!(contains.id, figure);
        let discusses = rows.iter().find(|r| r.edge_type == "Discusses").unwrap();
        assert_eq!(discusses.direction, DIRECTION_INCOMING);
        assert_eq!(discusses.id, review);
    }

    /// The D8 headline: one item, several kinds, several edge types, one list.
    #[test]
    fn mixed_kinds_and_edge_types_in_one_list() {
        let store = open();
        let manuscript = make(&store, "manuscript", "Grant renewal");
        let figure = make(&store, "figure", "Panel A");
        let paper = make(&store, "imbib/bibliography-entry", "Zwicky 1933");
        let task = make(&store, "task", "Redo the calibration");
        let message = make(&store, "email-message", "Re: calibration");
        let custom_target = make(&store, "agent-run", "Enrichment run");

        link(&store, &manuscript, &figure, EdgeType::Contains);
        link(&store, &manuscript, &paper, EdgeType::Cites);
        link(&store, &task, &manuscript, EdgeType::RelatesTo);
        link(&store, &message, &manuscript, EdgeType::InResponseTo);
        link(
            &store,
            &manuscript,
            &custom_target,
            EdgeType::Custom("reviewed-by".into()),
        );

        let rows = related_items(&store, &manuscript, 20).unwrap();
        assert_eq!(rows.len(), 5, "{rows:?}");

        let mut kinds: Vec<&str> = rows.iter().map(|r| r.schema_ref.as_str()).collect();
        kinds.sort_unstable();
        assert_eq!(
            kinds,
            vec![
                "agent-run",
                "email-message",
                "figure",
                "imbib/bibliography-entry",
                "task"
            ]
        );

        let edges: Vec<&str> = rows.iter().map(|r| r.edge_type.as_str()).collect();
        for expected in ["Contains", "Cites", "RelatesTo", "InResponseTo"] {
            assert!(edges.contains(&expected), "missing {expected} in {edges:?}");
        }
        assert!(
            edges.contains(&"reviewed-by"),
            "a Custom edge reports its own name, not the JSON wrapper: {edges:?}"
        );

        // Edge-type grouping is contiguous, so a Related section can render one
        // heading per type by walking the list once.
        let mut seen: Vec<&str> = vec![];
        for edge in &edges {
            if seen.last() != Some(edge) {
                assert!(!seen.contains(edge), "edge group {edge} is not contiguous");
                seen.push(edge);
            }
        }
    }

    /// A message that produced a task, seen from the task — the D8 example.
    #[test]
    fn a_task_finds_the_message_that_produced_it() {
        let store = open();
        let message = make(&store, "email-message", "Please rerun the fit");
        let task = make(&store, "task", "Rerun the fit");
        link(&store, &task, &message, EdgeType::ProducedBy);

        let from_task = related_items(&store, &task, 10).unwrap();
        assert_eq!(from_task.len(), 1);
        assert_eq!(from_task[0].id, message);
        assert_eq!(from_task[0].edge_type, "ProducedBy");
        assert_eq!(from_task[0].direction, DIRECTION_OUTGOING);

        let from_message = related_items(&store, &message, 10).unwrap();
        assert_eq!(from_message.len(), 1);
        assert_eq!(from_message[0].id, task);
        assert_eq!(from_message[0].direction, DIRECTION_INCOMING);
    }

    // ─── Robustness ──────────────────────────────────────────────────────

    /// Deleting the other end must shorten the list, not produce a blank row.
    #[test]
    fn deleted_targets_drop_out_of_the_list() {
        let store = open();
        let manuscript = make(&store, "manuscript", "Draft II");
        let kept = make(&store, "figure", "Panel A");
        let doomed = make(&store, "figure", "Panel B");
        link(&store, &manuscript, &kept, EdgeType::Contains);
        link(&store, &manuscript, &doomed, EdgeType::Contains);
        assert_eq!(related_items(&store, &manuscript, 10).unwrap().len(), 2);

        store.delete(Uuid::parse_str(&doomed).unwrap()).unwrap();
        let rows = related_items(&store, &manuscript, 10).unwrap();
        assert_eq!(rows.len(), 1, "{rows:?}");
        assert_eq!(rows[0].id, kept);
    }

    /// The same, for an edge row that outlived its target — which the FK
    /// cascade prevents from inside, but a sync merge, a restored backup or a
    /// hand-edited database can still produce. The join must skip it silently.
    #[test]
    fn hard_dangling_edges_are_skipped() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = dir.path().join("dangling.sqlite");
        let store = SqliteItemStore::open(&path).expect("open store");

        let manuscript = make(&store, "manuscript", "Draft II");
        let kept = make(&store, "figure", "Panel A");
        link(&store, &manuscript, &kept, EdgeType::Contains);

        // Write an edge to an item that was never inserted, with the FK check
        // off — the state a foreign store or a partial restore can leave.
        let ghost = Uuid::new_v4().to_string();
        {
            let raw = rusqlite::Connection::open(&path).expect("raw connection");
            raw.pragma_update(None, "foreign_keys", "OFF").unwrap();
            raw.execute(
                "INSERT INTO item_references (source_id, target_id, edge_type, metadata)
                 VALUES (?1, ?2, '\"Cites\"', NULL)",
                rusqlite::params![manuscript, ghost],
            )
            .expect("insert dangling edge");
            raw.execute(
                "INSERT INTO item_references (source_id, target_id, edge_type, metadata)
                 VALUES (?1, ?2, '\"Cites\"', NULL)",
                rusqlite::params![ghost, manuscript],
            )
            .expect("insert dangling incoming edge");
        }

        let rows = related_items(&store, &manuscript, 10).unwrap();
        assert_eq!(rows.len(), 1, "dangling edges must be skipped: {rows:?}");
        assert_eq!(rows[0].id, kept);
    }

    #[test]
    fn an_item_with_no_edges_returns_an_empty_list() {
        let store = open();
        let lonely = make(&store, "manuscript", "Untouched");
        assert!(related_items(&store, &lonely, 10).unwrap().is_empty());
    }

    #[test]
    fn missing_and_malformed_ids_error() {
        let store = open();
        assert!(matches!(
            related_items(&store, "not-a-uuid", 10),
            Err(StoreError::Validation(_))
        ));
        assert!(matches!(
            related_items(&store, &Uuid::new_v4().to_string(), 10),
            Err(StoreError::NotFound(_))
        ));
    }

    #[test]
    fn ids_are_accepted_uppercase_and_returned_lowercase() {
        let store = open();
        let manuscript = make(&store, "manuscript", "Draft II");
        let figure = make(&store, "figure", "Panel A");
        link(&store, &manuscript, &figure, EdgeType::Contains);

        let rows = related_items(&store, &manuscript.to_uppercase(), 10).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, figure, "ids come back lowercase");
    }

    #[test]
    fn limits_are_clamped_and_zero_means_the_default() {
        let store = open();
        let hub = make(&store, "manuscript", "Hub");
        for n in 0..(DEFAULT_LIMIT + 5) {
            let other = make(&store, "figure", &format!("Panel {n:03}"));
            link(&store, &hub, &other, EdgeType::Contains);
        }
        assert_eq!(related_items(&store, &hub, 3).unwrap().len(), 3);
        assert_eq!(
            related_items(&store, &hub, 0).unwrap().len(),
            DEFAULT_LIMIT as usize,
            "0 means the default cap"
        );
        assert_eq!(
            related_items(&store, &hub, u32::MAX).unwrap().len(),
            (DEFAULT_LIMIT + 5) as usize,
            "an absurd cap is clamped, not rejected"
        );
    }

    /// The cap applies to the merged list, so an item with many outgoing edges
    /// cannot starve its incoming ones out of existence.
    #[test]
    fn the_cap_applies_across_both_directions() {
        let store = open();
        let hub = make(&store, "manuscript", "Hub");
        // "Annotates" sorts before "Contains", so incoming rows lead.
        for n in 0..10 {
            let note = make(&store, "note", &format!("Note {n:03}"));
            link(&store, &note, &hub, EdgeType::Annotates);
            let panel = make(&store, "figure", &format!("Panel {n:03}"));
            link(&store, &hub, &panel, EdgeType::Contains);
        }
        let rows = related_items(&store, &hub, 12).unwrap();
        assert_eq!(rows.len(), 12);
        assert_eq!(
            rows.iter()
                .filter(|r| r.direction == DIRECTION_INCOMING)
                .count(),
            10,
            "the merged ordering, not the direction, decides what fits"
        );
    }
}
