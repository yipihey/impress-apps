//! A manuscript's reading list: the papers it cites and the papers the author
//! has collected to consider citing, ordered by recent attention.
//!
//! imprint's paper panel and the `imprint-papers-service` verbs both read it
//! from here, so the author and an agent see the same list in the same order.
//!
//! ## Storage
//!
//! * **Collected** papers live in an ordinary imbib collection, so the list is
//!   visible and editable in imbib's sidebar under its library. The collection
//!   carries `manuscript_ref = <manuscript id>` in its payload. Nothing is
//!   written on the manuscript: its payload has several writers (Automerge
//!   materialisation, CAS saves), and a back-reference on the collection keeps
//!   this feature out of all of them.
//! * **Cited** papers are computed, never stored. The caller passes the cite
//!   keys it scanned — the editor from its live buffer, the service from the
//!   stored text — because a stored copy would lag the buffer being typed into.
//! * **Recency** is imbib's `last_activity_at` stamp
//!   ([`SqliteItemStore::record_recent`]): written only from user-initiated call
//!   sites, and synced across the researcher's devices with the item.
//!
//! ## The migration trap
//!
//! imbib collections are stored as `imbib/collection` on an unmigrated store and
//! as the generic `collection` schema once WP G7 has run. The store matches
//! `schema_ref` by exact equality, so a literal here would find nothing on half
//! the stores in the field — silently, looking exactly like "no reading list
//! yet". Every lookup goes through [`collection_ops::resolve`] instead.

use std::collections::{BTreeMap, HashMap};

use uuid::Uuid;

use crate::collection_ops::{self, IMBIB_COLLECTION};
use crate::item::{Item, ItemId, Value};
use crate::query::{ItemQuery, Predicate};
use crate::sqlite_store::SqliteItemStore;
use crate::store::{ItemStore, StoreError};

/// imbib's publication record. Spelling copied from `schema-refs.json`.
pub const ENTRY_SCHEMA: &str = "imbib/bibliography-entry";
/// imbib's attachment record; its payload `is_pdf` marks a PDF.
pub const LINKED_FILE_SCHEMA: &str = "imbib/linked-file";
/// Payload field on a reading-list collection naming its manuscript.
pub const MANUSCRIPT_REF_FIELD: &str = "manuscript_ref";
/// imbib's library record — the fallback home for a reading list whose
/// manuscript cites nothing yet, so the collection can always be made.
pub const LIBRARY_SCHEMA: &str = "imbib/library";

/// One row of a manuscript's reading list.
#[derive(Debug, Clone, PartialEq)]
pub struct ReadingListEntry {
    /// The imbib publication, or `None` for a cite key imbib does not hold.
    pub publication_id: Option<String>,
    pub cite_key: String,
    pub title: Option<String>,
    pub authors: Option<String>,
    pub year: Option<i64>,
    /// The manuscript cites it.
    pub cited: bool,
    /// It is in the manuscript's reading-list collection.
    pub collected: bool,
    /// imbib holds a PDF for it. The file lives in imbib's own container, so
    /// other apps fetch its bytes through imbib rather than opening the path.
    pub has_pdf: bool,
    /// Last time the user viewed or hand-added it, ms since the epoch.
    pub last_activity_at: Option<i64>,
    /// Position of its first citation in the manuscript, if cited.
    pub citation_index: Option<u32>,
}

/// What [`collect`] did.
#[derive(Debug, Clone, PartialEq)]
pub struct CollectOutcome {
    pub collection_id: String,
    /// The collection did not exist and this call made it.
    pub created: bool,
    /// Publications that actually became members; re-adding reports nothing,
    /// so a caller can register an undo that removes only what this added.
    pub added: Vec<String>,
}

/// What [`sync_reading_collection`] did.
///
/// The collection is what imbib's papers window shows, so the manuscript's
/// cited papers have to BE in it — the window has one scope, not two.
#[derive(Debug, Clone, PartialEq)]
pub struct SyncOutcome {
    pub collection_id: String,
    pub collection_name: String,
    /// The collection did not exist and this call made it.
    pub created: bool,
    /// Cited papers this call added; a second run adds nothing.
    pub added: Vec<String>,
    /// Cite keys the manuscript cites that imbib does not hold, in citation
    /// order. They cannot be collected and the window cannot show them, so
    /// the caller reports them instead of losing them.
    pub missing_cite_keys: Vec<String>,
    /// Members after the sync — cited plus hand-collected.
    pub member_count: u32,
}

fn parse_id(id: &str) -> Result<ItemId, StoreError> {
    Uuid::parse_str(id.trim()).map_err(|_| StoreError::Validation(format!("invalid UUID: {id}")))
}

fn str_field(item: &Item, key: &str) -> Option<String> {
    match item.payload.get(key) {
        Some(Value::String(s)) if !s.trim().is_empty() => Some(s.clone()),
        _ => None,
    }
}

fn int_field(item: &Item, key: &str) -> Option<i64> {
    match item.payload.get(key)? {
        Value::Int(i) => Some(*i),
        Value::Float(f) => Some(*f as i64),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

/// The manuscript's reading-list collection, if it has one.
///
/// When more than one claims the manuscript (two devices each made one before
/// they synced), the oldest wins, so every device converges on the same answer.
pub fn reading_collection(
    store: &SqliteItemStore,
    manuscript_id: &str,
) -> Result<Option<String>, StoreError> {
    let manuscript = parse_id(manuscript_id)?;
    let binding = collection_ops::resolve(store, &IMBIB_COLLECTION)?;
    let q = ItemQuery {
        schema: Some(binding.schema_ref.into()),
        predicates: vec![Predicate::Eq(
            MANUSCRIPT_REF_FIELD.into(),
            Value::String(manuscript.to_string()),
        )],
        limit: None,
        include_tags: false,
        include_references: false,
        ..ItemQuery::default()
    };
    let mut rows = store.query(&q)?;
    rows.sort_by(|a, b| a.created.cmp(&b.created).then(a.id.cmp(&b.id)));
    Ok(rows.first().map(|c| c.id.to_string()))
}

/// Make the manuscript's reading-list collection if it has none, filed under
/// `library_id` so it shows in imbib's sidebar beside that library's other
/// collections. Returns the collection id and whether this call made it.
pub fn ensure_reading_collection(
    store: &SqliteItemStore,
    manuscript_id: &str,
    name: &str,
    library_id: &str,
) -> Result<(String, bool), StoreError> {
    let manuscript = parse_id(manuscript_id)?;
    if let Some(existing) = reading_collection(store, manuscript_id)? {
        return Ok((existing, false));
    }
    let library = parse_id(library_id)?;
    let name = if name.trim().is_empty() {
        "Papers"
    } else {
        name.trim()
    };
    let row = collection_ops::create_in_with_payload(
        store,
        &IMBIB_COLLECTION,
        name,
        None,
        Some("publication"),
        None,
        Some(&library.to_string()),
        &[(MANUSCRIPT_REF_FIELD, Value::String(manuscript.to_string()))],
    )?;
    Ok((row.id, true))
}

/// Cite keys in first-appearance order, blanks and duplicates dropped.
fn distinct_keys(cite_keys: &[String]) -> Vec<String> {
    let mut keys: Vec<String> = Vec::new();
    for k in cite_keys {
        let k = k.trim();
        if !k.is_empty() && !keys.iter().any(|x| x == k) {
            keys.push(k.to_string());
        }
    }
    keys
}

/// The imbib entry for each key, in one query. Two entries sharing a key (a
/// duplicate import) resolve to the oldest, the resolver's "first wins".
fn entries_for_keys(
    store: &SqliteItemStore,
    keys: &[String],
) -> Result<HashMap<String, Item>, StoreError> {
    if keys.is_empty() {
        return Ok(HashMap::new());
    }
    let q = ItemQuery {
        schema: Some(ENTRY_SCHEMA.into()),
        predicates: vec![Predicate::In(
            "cite_key".into(),
            keys.iter().map(|k| Value::String(k.clone())).collect(),
        )],
        limit: None,
        include_tags: false,
        include_references: false,
        ..ItemQuery::default()
    };
    let mut by_key: HashMap<String, Item> = HashMap::new();
    for item in store.query(&q)? {
        let Some(key) = str_field(&item, "cite_key") else {
            continue;
        };
        let keep_existing = by_key
            .get(&key)
            .is_some_and(|prev| (prev.created, prev.id) <= (item.created, item.id));
        if !keep_existing {
            by_key.insert(key, item);
        }
    }
    Ok(by_key)
}

fn has_pdf(store: &SqliteItemStore, entry: ItemId) -> Result<bool, StoreError> {
    let q = ItemQuery {
        schema: Some(LINKED_FILE_SCHEMA.into()),
        predicates: vec![
            Predicate::HasParent(entry),
            Predicate::Eq("is_pdf".into(), Value::Bool(true)),
        ],
        limit: Some(1),
        include_tags: false,
        include_references: false,
        ..ItemQuery::default()
    };
    Ok(!store.query(&q)?.is_empty())
}

fn entry_of(
    store: &SqliteItemStore,
    item: &Item,
    cited: bool,
    collected: bool,
    citation_index: Option<u32>,
) -> Result<ReadingListEntry, StoreError> {
    Ok(ReadingListEntry {
        publication_id: Some(item.id.to_string()),
        cite_key: str_field(item, "cite_key").unwrap_or_default(),
        title: str_field(item, "title"),
        authors: str_field(item, "author_text"),
        year: int_field(item, "year"),
        cited,
        collected,
        has_pdf: has_pdf(store, item.id)?,
        last_activity_at: int_field(item, "last_activity_at"),
        citation_index,
    })
}

/// The reading list for `manuscript_id`, given the cite keys the caller
/// scanned from its text.
///
/// Order, most useful first:
/// 1. papers the user has viewed (or hand-added), most recent first — the ones
///    they are actually reading while they write;
/// 2. never-viewed cited papers, in citation order; then never-viewed collected
///    papers, most recently collected first;
/// 3. cite keys imbib does not hold, in citation order, so a missing reference
///    is visible rather than silently absent.
pub fn reading_list(
    store: &SqliteItemStore,
    manuscript_id: &str,
    cite_keys: &[String],
) -> Result<Vec<ReadingListEntry>, StoreError> {
    let keys = distinct_keys(cite_keys);
    let by_key = entries_for_keys(store, &keys)?;
    let collected: Vec<Item> = match reading_collection(store, manuscript_id)? {
        Some(collection) => collection_ops::list_members(store, &IMBIB_COLLECTION, &collection)?
            .into_iter()
            .filter(|item| item.schema == ENTRY_SCHEMA)
            .collect(),
        None => Vec::new(),
    };

    // (entry, rank among collected-only rows; `list_members` is newest first)
    let mut rows: Vec<(ReadingListEntry, Option<usize>)> = Vec::new();
    let mut row_of: HashMap<ItemId, usize> = HashMap::new();
    for (i, key) in keys.iter().enumerate() {
        let index = Some(i as u32);
        match by_key.get(key) {
            Some(item) => {
                row_of.insert(item.id, rows.len());
                rows.push((entry_of(store, item, true, false, index)?, None));
            }
            None => rows.push((
                ReadingListEntry {
                    publication_id: None,
                    cite_key: key.clone(),
                    title: None,
                    authors: None,
                    year: None,
                    cited: true,
                    collected: false,
                    has_pdf: false,
                    last_activity_at: None,
                    citation_index: index,
                },
                None,
            )),
        }
    }
    for (rank, item) in collected.iter().enumerate() {
        match row_of.get(&item.id) {
            Some(&at) => rows[at].0.collected = true,
            None => {
                row_of.insert(item.id, rows.len());
                rows.push((entry_of(store, item, false, true, None)?, Some(rank)));
            }
        }
    }

    rows.sort_by(|(a, a_rank), (b, b_rank)| {
        let group = |e: &ReadingListEntry| match (&e.publication_id, e.last_activity_at) {
            (Some(_), Some(_)) => 0,
            (Some(_), None) => 1,
            (None, _) => 2,
        };
        group(a).cmp(&group(b)).then_with(|| match group(a) {
            0 => b.last_activity_at.cmp(&a.last_activity_at),
            1 => (a.citation_index.is_none(), a.citation_index, a_rank).cmp(&(
                b.citation_index.is_none(),
                b.citation_index,
                b_rank,
            )),
            _ => a.citation_index.cmp(&b.citation_index),
        })
    });
    Ok(rows.into_iter().map(|(entry, _)| entry).collect())
}

/// The library a new reading list should be filed under: the one holding most
/// of the manuscript's cited papers, else the first collected paper's own
/// library. Ties break on the lower id so every device picks the same one.
fn home_library_for(
    store: &SqliteItemStore,
    cite_keys: &[String],
    publications: &[ItemId],
) -> Result<Option<ItemId>, StoreError> {
    let mut counts: BTreeMap<ItemId, usize> = BTreeMap::new();
    for item in entries_for_keys(store, &distinct_keys(cite_keys))?.values() {
        if let Some(library) = item.parent {
            *counts.entry(library).or_default() += 1;
        }
    }
    let mut ranked: Vec<(ItemId, usize)> = counts.into_iter().collect();
    ranked.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    if let Some((library, _)) = ranked.first() {
        return Ok(Some(*library));
    }
    for id in publications {
        if let Some(library) = store.get(*id)?.and_then(|item| item.parent) {
            return Ok(Some(library));
        }
    }
    Ok(None)
}

/// "<manuscript title> — papers", or "Papers" for an untitled one.
///
/// The word matches what every surface calls it — imprint's "Papers…" command,
/// imbib's papers window — so the collection in imbib's sidebar is recognisably
/// the same thing. Only used at creation; an existing collection keeps its name.
fn default_collection_name(
    store: &SqliteItemStore,
    manuscript_id: &str,
) -> Result<String, StoreError> {
    let title = store
        .get(parse_id(manuscript_id)?)?
        .and_then(|m| match m.payload.get("title") {
            Some(Value::String(t)) if !t.trim().is_empty() => Some(t.trim().to_string()),
            _ => None,
        });
    Ok(match title {
        Some(title) => format!("{title} — papers"),
        None => "Papers".to_string(),
    })
}

/// The oldest imbib library, for a reading list with no cited paper to
/// suggest a home. A collection must live under some library to appear in
/// imbib's sidebar at all.
fn oldest_library(store: &SqliteItemStore) -> Result<Option<ItemId>, StoreError> {
    let q = ItemQuery {
        schema: Some(LIBRARY_SCHEMA.into()),
        limit: None,
        include_tags: false,
        include_references: false,
        ..ItemQuery::default()
    };
    let mut rows = store.query(&q)?;
    rows.sort_by(|a, b| a.created.cmp(&b.created).then(a.id.cmp(&b.id)));
    Ok(rows.first().map(|l| l.id))
}

/// Make the manuscript's reading-list collection hold every paper it cites,
/// creating the collection on first use. Idempotent: a second call with the
/// same text adds nothing.
///
/// This is what makes one scope enough. imbib's papers window lists a
/// COLLECTION; a manuscript's papers are "what it cites" plus "what the author
/// collected to consider", and the first of those is computed from the text.
/// Folding the cited ones into the collection means the author curates in
/// exactly one place, in imbib, with imbib's own list — and `uncollect` still
/// removes a paper the author no longer wants in view.
pub fn sync_reading_collection(
    store: &SqliteItemStore,
    manuscript_id: &str,
    cite_keys: &[String],
    collection_name: Option<&str>,
) -> Result<SyncOutcome, StoreError> {
    let keys = distinct_keys(cite_keys);
    let by_key = entries_for_keys(store, &keys)?;
    let mut cited_ids: Vec<String> = Vec::new();
    let mut missing_cite_keys: Vec<String> = Vec::new();
    for key in &keys {
        match by_key.get(key) {
            Some(item) => cited_ids.push(item.id.to_string()),
            None => missing_cite_keys.push(key.clone()),
        }
    }

    let (collection_id, created) = match reading_collection(store, manuscript_id)? {
        Some(existing) => (existing, false),
        None => {
            let ids: Vec<ItemId> = cited_ids
                .iter()
                .map(|id| parse_id(id))
                .collect::<Result<_, _>>()?;
            let library = home_library_for(store, cite_keys, &ids)?
                .or(oldest_library(store)?)
                .ok_or_else(|| {
                    StoreError::Validation(
                        "imbib has no library to hold this manuscript's papers".into(),
                    )
                })?;
            let name = match collection_name.map(str::trim) {
                Some(name) if !name.is_empty() => name.to_string(),
                _ => default_collection_name(store, manuscript_id)?,
            };
            ensure_reading_collection(store, manuscript_id, &name, &library.to_string())?
        }
    };

    let added = if cited_ids.is_empty() {
        Vec::new()
    } else {
        collection_ops::add_members(store, &IMBIB_COLLECTION, &collection_id, &cited_ids)?
    };
    let members = collection_ops::list_members(store, &IMBIB_COLLECTION, &collection_id)?;
    let collection_name = store
        .get(parse_id(&collection_id)?)?
        .and_then(|c| str_field(&c, "name"))
        .unwrap_or_default();

    Ok(SyncOutcome {
        collection_id,
        collection_name,
        created,
        added,
        missing_cite_keys,
        member_count: members.len() as u32,
    })
}

/// Add publications to the manuscript's reading list, making the collection on
/// first use — named `collection_name`, else "<manuscript title> — reading
/// list" — and filed per [`home_library_for`].
pub fn collect(
    store: &SqliteItemStore,
    manuscript_id: &str,
    publication_ids: &[String],
    collection_name: Option<&str>,
    cite_keys: &[String],
) -> Result<CollectOutcome, StoreError> {
    let ids = publication_ids
        .iter()
        .map(|id| parse_id(id))
        .collect::<Result<Vec<ItemId>, StoreError>>()?;
    if ids.is_empty() {
        return Err(StoreError::Validation("no publications to collect".into()));
    }
    let (collection_id, created) = match reading_collection(store, manuscript_id)? {
        Some(existing) => (existing, false),
        None => {
            let library = home_library_for(store, cite_keys, &ids)?.ok_or_else(|| {
                StoreError::Validation(
                    "none of these papers is filed in an imbib library, so there is no \
                     library to hold the reading list"
                        .into(),
                )
            })?;
            let name = match collection_name.map(str::trim) {
                Some(name) if !name.is_empty() => name.to_string(),
                _ => default_collection_name(store, manuscript_id)?,
            };
            ensure_reading_collection(store, manuscript_id, &name, &library.to_string())?
        }
    };
    let members: Vec<String> = ids.iter().map(ItemId::to_string).collect();
    let added = collection_ops::add_members(store, &IMBIB_COLLECTION, &collection_id, &members)?;
    Ok(CollectOutcome {
        collection_id,
        created,
        added,
    })
}

/// Remove publications from the manuscript's reading list. The papers stay in
/// imbib; only the membership goes. Returns the ids actually removed.
pub fn uncollect(
    store: &SqliteItemStore,
    manuscript_id: &str,
    publication_ids: &[String],
) -> Result<Vec<String>, StoreError> {
    let Some(collection) = reading_collection(store, manuscript_id)? else {
        return Ok(Vec::new());
    };
    let ids = publication_ids
        .iter()
        .map(|id| parse_id(id).map(|i| i.to_string()))
        .collect::<Result<Vec<String>, StoreError>>()?;
    collection_ops::remove_members(store, &IMBIB_COLLECTION, &collection, &ids)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::collection_migration::migrate_collections;
    use crate::collection_ops::new_item;

    struct Fixture {
        store: SqliteItemStore,
        library: ItemId,
        manuscript: String,
    }

    fn insert(
        store: &SqliteItemStore,
        schema: &str,
        fields: &[(&str, Value)],
        parent: Option<ItemId>,
    ) -> ItemId {
        let payload: BTreeMap<String, Value> = fields
            .iter()
            .map(|(k, v)| ((*k).to_string(), v.clone()))
            .collect();
        let mut item = new_item(store, schema, payload);
        item.parent = parent;
        store.insert(item).expect("insert")
    }

    fn entry(f: &Fixture, key: &str, title: &str, year: i64) -> ItemId {
        insert(
            &f.store,
            ENTRY_SCHEMA,
            &[
                ("cite_key", Value::String(key.into())),
                ("title", Value::String(title.into())),
                ("author_text", Value::String("Doe, J.".into())),
                ("year", Value::Int(year)),
            ],
            Some(f.library),
        )
    }

    fn fixture() -> Fixture {
        let store = SqliteItemStore::open_in_memory().expect("in-memory store");
        let library = insert(
            &store,
            "imbib/library",
            &[("name", Value::String("ULDM".into()))],
            None,
        );
        let manuscript = insert(
            &store,
            "manuscript",
            &[("title", Value::String("Draft".into()))],
            None,
        );
        Fixture {
            store,
            library,
            manuscript: manuscript.to_string(),
        }
    }

    fn keys(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn viewed_first_then_citation_order_then_collected_then_missing() {
        let f = fixture();
        let a = entry(&f, "A2020", "Alpha", 2020);
        let _b = entry(&f, "B2021", "Beta", 2021);
        let c = entry(&f, "C2019", "Gamma", 2019);
        insert(
            &f.store,
            LINKED_FILE_SCHEMA,
            &[("is_pdf", Value::Bool(true))],
            Some(a),
        );
        collect(
            &f.store,
            &f.manuscript,
            &[c.to_string()],
            Some("Draft — reading list"),
            &[],
        )
        .unwrap();
        assert!(f.store.record_recent(&a.to_string(), "viewed").unwrap());

        // B cited first, A second (and again), X is not in imbib.
        let list = reading_list(
            &f.store,
            &f.manuscript,
            &keys(&["B2021", "A2020", "X1999", "A2020"]),
        )
        .unwrap();
        let order: Vec<&str> = list.iter().map(|e| e.cite_key.as_str()).collect();
        assert_eq!(order, ["A2020", "B2021", "C2019", "X1999"]);

        let by = |k: &str| list.iter().find(|e| e.cite_key == k).unwrap();
        assert!(by("A2020").cited && !by("A2020").collected && by("A2020").has_pdf);
        assert_eq!(by("A2020").citation_index, Some(1));
        assert!(by("A2020").last_activity_at.is_some());
        assert!(!by("C2019").cited && by("C2019").collected);
        assert_eq!(by("C2019").title.as_deref(), Some("Gamma"));
        assert_eq!(by("X1999").publication_id, None);
        assert_eq!(by("B2021").year, Some(2021));
    }

    #[test]
    fn a_cited_paper_that_is_also_collected_is_one_row() {
        let f = fixture();
        let a = entry(&f, "A2020", "Alpha", 2020);
        collect(&f.store, &f.manuscript, &[a.to_string()], None, &[]).unwrap();
        let list = reading_list(&f.store, &f.manuscript, &keys(&["A2020"])).unwrap();
        assert_eq!(list.len(), 1);
        assert!(list[0].cited && list[0].collected);
    }

    #[test]
    fn collect_makes_the_collection_once_and_reports_only_new_members() {
        let f = fixture();
        let a = entry(&f, "A2020", "Alpha", 2020);
        let b = entry(&f, "B2021", "Beta", 2021);
        let first = collect(
            &f.store,
            &f.manuscript,
            &[a.to_string()],
            Some("RL"),
            &keys(&["B2021"]),
        )
        .unwrap();
        assert!(first.created);
        assert_eq!(first.added, [a.to_string()]);
        let second = collect(
            &f.store,
            &f.manuscript,
            &[a.to_string(), b.to_string()],
            Some("RL"),
            &[],
        )
        .unwrap();
        assert!(!second.created);
        assert_eq!(second.collection_id, first.collection_id);
        assert_eq!(second.added, [b.to_string()]);
        // filed under the library that holds the cited papers
        let coll = f
            .store
            .get(parse_id(&first.collection_id).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(coll.parent, Some(f.library));
    }

    #[test]
    fn sync_folds_cited_papers_into_the_collection_and_is_idempotent() {
        let f = fixture();
        let a = entry(&f, "A2020", "Alpha", 2020);
        let b = entry(&f, "B2021", "Beta", 2021);

        let first = sync_reading_collection(
            &f.store,
            &f.manuscript,
            &keys(&["B2021", "A2020", "X1999"]),
            None,
        )
        .unwrap();
        assert!(first.created);
        assert_eq!(first.collection_name, "Draft — papers");
        assert_eq!(first.added, [b.to_string(), a.to_string()]);
        assert_eq!(first.missing_cite_keys, ["X1999"]);
        assert_eq!(first.member_count, 2);

        // The window's one scope now holds what the manuscript cites.
        let list = reading_list(&f.store, &f.manuscript, &keys(&["B2021", "A2020"])).unwrap();
        assert!(list.iter().all(|e| e.collected));

        let again =
            sync_reading_collection(&f.store, &f.manuscript, &keys(&["A2020", "B2021"]), None)
                .unwrap();
        assert!(!again.created);
        assert_eq!(again.collection_id, first.collection_id);
        assert!(again.added.is_empty(), "a second sync adds nothing");
        assert_eq!(again.member_count, 2);
        assert!(again.missing_cite_keys.is_empty());
    }

    #[test]
    fn sync_keeps_hand_collected_papers_and_an_uncollected_one_stays_out() {
        let f = fixture();
        let a = entry(&f, "A2020", "Alpha", 2020);
        let c = entry(&f, "C2019", "Gamma", 2019);
        collect(&f.store, &f.manuscript, &[c.to_string()], Some("RL"), &[]).unwrap();

        let out =
            sync_reading_collection(&f.store, &f.manuscript, &keys(&["A2020"]), None).unwrap();
        assert!(!out.created, "the hand-made collection is the one it syncs");
        assert_eq!(out.added, [a.to_string()]);
        assert_eq!(out.member_count, 2, "the collected paper is still a member");

        // Removing a paper the author does not want in view holds until it is
        // cited again — a sync only ADDS what the text actually cites.
        uncollect(&f.store, &f.manuscript, &[c.to_string()]).unwrap();
        let after =
            sync_reading_collection(&f.store, &f.manuscript, &keys(&["A2020"]), None).unwrap();
        assert_eq!(after.member_count, 1);
    }

    #[test]
    fn sync_makes_a_collection_for_a_manuscript_that_cites_nothing_yet() {
        let f = fixture();
        let out = sync_reading_collection(&f.store, &f.manuscript, &[], Some("Papers")).unwrap();
        assert!(out.created);
        assert_eq!(out.collection_name, "Papers");
        assert_eq!(out.member_count, 0);
        // Filed under the only library there is, so imbib's sidebar shows it.
        let coll = f
            .store
            .get(parse_id(&out.collection_id).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(coll.parent, Some(f.library));
    }

    #[test]
    fn uncollect_removes_the_membership_not_the_paper() {
        let f = fixture();
        let a = entry(&f, "A2020", "Alpha", 2020);
        collect(&f.store, &f.manuscript, &[a.to_string()], Some("RL"), &[]).unwrap();
        assert_eq!(
            uncollect(&f.store, &f.manuscript, &[a.to_string()]).unwrap(),
            [a.to_string()]
        );
        assert!(reading_list(&f.store, &f.manuscript, &[])
            .unwrap()
            .is_empty());
        assert!(f.store.get(a).unwrap().is_some());
        assert!(uncollect(&f.store, &f.manuscript, &[a.to_string()])
            .unwrap()
            .is_empty());
    }

    #[test]
    fn the_association_survives_the_collection_migration() {
        // A reading list made before WP G7 must still be found after it: the
        // migration rewrites schema_ref, and a literal lookup would go blind.
        let f = fixture();
        let a = entry(&f, "A2020", "Alpha", 2020);
        let made = collect(&f.store, &f.manuscript, &[a.to_string()], Some("RL"), &[]).unwrap();
        migrate_collections(&f.store, false).unwrap();
        assert_eq!(
            reading_collection(&f.store, &f.manuscript).unwrap(),
            Some(made.collection_id.clone())
        );
        let list = reading_list(&f.store, &f.manuscript, &[]).unwrap();
        assert_eq!(list.len(), 1);
        assert!(list[0].collected);
    }

    #[test]
    fn a_reading_list_made_after_the_migration_is_found() {
        let f = fixture();
        migrate_collections(&f.store, false).unwrap();
        let a = entry(&f, "A2020", "Alpha", 2020);
        let made = collect(&f.store, &f.manuscript, &[a.to_string()], Some("RL"), &[]).unwrap();
        assert!(made.created);
        assert_eq!(
            reading_collection(&f.store, &f.manuscript).unwrap(),
            Some(made.collection_id)
        );
    }

    #[test]
    fn collecting_a_paper_with_no_library_is_refused_not_guessed() {
        let f = fixture();
        let orphan = insert(
            &f.store,
            ENTRY_SCHEMA,
            &[("cite_key", Value::String("O2000".into()))],
            None,
        );
        let err = collect(
            &f.store,
            &f.manuscript,
            &[orphan.to_string()],
            Some("RL"),
            &[],
        )
        .unwrap_err();
        assert!(matches!(err, StoreError::Validation(_)));
    }

    #[test]
    fn manuscript_ids_are_normalised_so_swift_uppercase_matches() {
        let f = fixture();
        let a = entry(&f, "A2020", "Alpha", 2020);
        collect(
            &f.store,
            &f.manuscript.to_uppercase(),
            &[a.to_string()],
            Some("RL"),
            &[],
        )
        .unwrap();
        assert!(reading_collection(&f.store, &f.manuscript)
            .unwrap()
            .is_some());
    }

    #[test]
    fn an_unnamed_reading_list_is_named_after_the_manuscript() {
        let f = fixture();
        let a = entry(&f, "A2020", "Alpha", 2020);
        let made = collect(&f.store, &f.manuscript, &[a.to_string()], None, &[]).unwrap();
        let coll = f
            .store
            .get(parse_id(&made.collection_id).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(
            coll.payload.get("name"),
            Some(&Value::String("Draft — papers".into()))
        );
    }
}
