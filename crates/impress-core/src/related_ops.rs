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

use uuid::Uuid;

use crate::item::ItemId;
use crate::reference::EdgeType;
use crate::sqlite_store::SqliteItemStore;
use crate::store::{ItemStore, StoreError};

/// Row cap used when the caller passes `0`.
pub const DEFAULT_LIMIT: u32 = 50;

/// Hard ceiling on the row cap. A Related section is a list a human reads.
pub const MAX_LIMIT: u32 = 500;

/// `direction` value for edges where the subject item is the edge SOURCE.
pub const DIRECTION_OUTGOING: &str = "outgoing";

/// `direction` value for edges where the subject item is the edge TARGET.
pub const DIRECTION_INCOMING: &str = "incoming";

/// Display title, mirroring [`crate::search_ops`]'s chain so a Related row and
/// a search row name the same item the same way. Expects `items` aliased `i`.
const TITLE_EXPR: &str = "COALESCE(
        NULLIF(json_extract(i.payload, '$.title'), ''),
        NULLIF(json_extract(i.payload, '$.subject'), ''),
        NULLIF(json_extract(i.payload, '$.name'), ''),
        '')";

/// One item related to the subject by a typed edge.
#[derive(Debug, Clone, PartialEq)]
pub struct RelatedItem {
    /// Lowercase UUID of the *other* item — never the subject.
    pub id: String,
    /// The other item's `schema_ref`, so a mixed-kind list can pick a row
    /// renderer per entry.
    pub schema_ref: String,
    /// Display title (title / subject / name, in that order).
    pub title: String,
    /// Edge type name (`"Cites"`, `"Contains"`, …). A
    /// [`EdgeType::Custom`] edge reports its bare custom name.
    pub edge_type: String,
    /// [`DIRECTION_OUTGOING`] when the subject is the edge source (this
    /// manuscript *contains* that figure), [`DIRECTION_INCOMING`] when it is
    /// the target (that manuscript contains this figure).
    pub direction: String,
}

/// Every item related to `id`, both directions, all edge types.
///
/// Ordered by edge type, then title, then direction and id — deterministic, and
/// grouped so a section can render one heading per edge type by walking once.
///
/// Edges whose other end no longer resolves to an item are skipped rather than
/// reported as blank rows: the join does the filtering, so a half-deleted graph
/// degrades to a shorter list instead of a broken one.
///
/// `limit` is clamped to `1..=`[`MAX_LIMIT`]; `0` means [`DEFAULT_LIMIT`].
/// Returns [`StoreError::NotFound`] when the subject item does not exist —
/// "this item has no relations" and "this item does not exist" are different
/// answers and a caller should be able to tell them apart.
pub fn related_items(
    store: &SqliteItemStore,
    id: &str,
    limit: u32,
) -> Result<Vec<RelatedItem>, StoreError> {
    let subject = parse_id(id)?;
    if store.get(subject)?.is_none() {
        return Err(StoreError::NotFound(subject));
    }
    let limit = match limit {
        0 => DEFAULT_LIMIT,
        n => n.min(MAX_LIMIT),
    };
    let subject = subject.to_string();

    // One UNION ALL rather than two round trips, so the cap applies to the
    // merged, ordered list — otherwise a heavily-cited item would spend its
    // whole budget on outgoing edges before any incoming edge was considered.
    // The JOIN is what drops dangling edges.
    let sql = format!(
        "SELECT other_id, schema_ref, title, edge_type, direction FROM (
             SELECT r.target_id AS other_id,
                    i.schema_ref AS schema_ref,
                    {TITLE_EXPR} AS title,
                    r.edge_type AS edge_type,
                    '{DIRECTION_OUTGOING}' AS direction
             FROM item_references r
             JOIN items i ON i.id = r.target_id
             WHERE r.source_id = ?1
             UNION ALL
             SELECT r.source_id AS other_id,
                    i.schema_ref AS schema_ref,
                    {TITLE_EXPR} AS title,
                    r.edge_type AS edge_type,
                    '{DIRECTION_INCOMING}' AS direction
             FROM item_references r
             JOIN items i ON i.id = r.source_id
             WHERE r.target_id = ?1
         )
         ORDER BY edge_type ASC, title ASC, direction ASC, other_id ASC
         LIMIT ?2"
    );

    store.query_raw(
        &sql,
        &[&subject, &limit],
        |row| -> Result<RelatedItem, rusqlite::Error> {
            let stored_edge: String = row.get(3)?;
            Ok(RelatedItem {
                id: row.get(0)?,
                schema_ref: row.get(1)?,
                title: row.get(2)?,
                edge_type: edge_label(&stored_edge),
                direction: row.get(4)?,
            })
        },
    )
}

fn parse_id(id: &str) -> Result<ItemId, StoreError> {
    Uuid::parse_str(id).map_err(|_| StoreError::Validation(format!("invalid UUID: {id}")))
}

/// Edge types are stored as serde JSON (`"Cites"`, `{"Custom":"reviewed-by"}`).
/// Unit variants become their bare name; a custom edge reports the name its
/// author chose, because that is the string a UI should show.
fn edge_label(stored: &str) -> String {
    match serde_json::from_str::<EdgeType>(stored) {
        Ok(EdgeType::Custom(name)) => name,
        _ => stored.trim_matches('"').to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::{Item, Priority, Value, Visibility};
    use crate::reference::TypedReference;
    use crate::store::FieldMutation;
    use chrono::Utc;
    use std::collections::BTreeMap;

    fn open() -> SqliteItemStore {
        SqliteItemStore::open_in_memory().expect("open in-memory store")
    }

    fn make(store: &SqliteItemStore, schema: &str, title: &str) -> String {
        let now = Utc::now();
        let mut payload: BTreeMap<String, Value> = BTreeMap::new();
        payload.insert("title".into(), Value::String(title.into()));
        let item = Item {
            id: Uuid::new_v4(),
            schema: schema.into(),
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
