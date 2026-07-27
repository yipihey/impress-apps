//! Grouped global search (ADR-0022 D6).
//!
//! `items_fts` already indexes every record kind the suite writes — five
//! columns (`title`, `author_text`, `abstract_text`, `note`, `body`) with
//! COALESCE mappings that fold mail's `subject`/`from`/`body` into the same
//! shape. That means one FTS query already spans publications, manuscripts,
//! figures, messages, tasks and runs; what was missing was a kernel that
//! returns the *kind* alongside the hit so a caller can bucket results instead
//! of showing one undifferentiated list.
//!
//! [`search_all`] is that kernel. It returns a flat, deterministically ordered
//! `Vec<SearchHit>` grouped by `schema_ref`, with a per-kind cap applied in SQL
//! so one noisy schema (a mailbox with 40 000 messages) cannot crowd every
//! other kind off the surface.
//!
//! ## The query string is data, not syntax
//!
//! FTS5's MATCH grammar has operators (`AND`, `OR`, `NOT`, `NEAR`),
//! parentheses, phrase quotes and column filters. A search field is typed by a
//! human mid-thought, so it will regularly contain a lone `(`, an unbalanced
//! `"`, or a `-` — each of which is a *syntax error* that fails the whole
//! statement. Rather than reject those, [`fts_match_expression`] reduces the
//! input to alphanumeric tokens and rebuilds a quoted prefix query, so every
//! keystroke is a valid query that searches for what the user literally typed.
//! See `hostile_queries_do_not_crash_the_search`.
//!
//! ## Status
//!
//! Only [`crate::triage_ops::STATUS_DISMISSED`] items are withheld. Dismissed
//! things are deliberately swept out of the working set and are reachable
//! through their own section; everything else — archived included — stays
//! findable, because "I know I wrote it somewhere" is exactly when a user
//! reaches for global search.

use crate::sqlite_store::SqliteItemStore;
use crate::store::StoreError;
use crate::triage_ops::STATUS_DISMISSED;

/// Per-kind cap used when the caller passes `0`.
pub const DEFAULT_LIMIT_PER_SCHEMA: u32 = 20;

/// Hard ceiling on the per-kind cap. A search surface renders tens of rows per
/// bucket, not thousands, and an unbounded cap turns a typo into a full scan.
pub const MAX_LIMIT_PER_SCHEMA: u32 = 200;

/// Number of tokens of context in a generated snippet.
const SNIPPET_TOKENS: i64 = 12;

/// Display title for an item, mirroring the COALESCE chain `items_fts` uses
/// for its `title` column, plus `name` so collections and folders read right.
/// Expects the `items` table to be aliased `i`.
const TITLE_EXPR: &str = "COALESCE(
        NULLIF(json_extract(i.payload, '$.title'), ''),
        NULLIF(json_extract(i.payload, '$.subject'), ''),
        NULLIF(json_extract(i.payload, '$.name'), ''),
        '')";

/// One search result, kind-tagged so the caller can bucket by record kind.
#[derive(Debug, Clone, PartialEq)]
pub struct SearchHit {
    /// Lowercase UUID string.
    pub id: String,
    /// The item's `schema_ref` — the bucket key ("manuscript", "figure",
    /// "email-message", …).
    pub schema_ref: String,
    /// Display title (title / subject / name, in that order).
    pub title: String,
    /// FTS5 snippet from the best-matching column, unmarked. Falls back to the
    /// title when the match was in a column with nothing quotable.
    pub snippet: String,
    /// BM25 relevance. **Lower is better** (bm25 returns negative scores);
    /// hits arrive already sorted, so callers rarely need to look at this.
    pub rank: f64,
}

/// Full-text search across every record kind, capped per kind.
///
/// Results are ordered by `schema_ref`, then relevance, then id — so buckets
/// are contiguous and the order is stable across runs. `limit_per_schema` is
/// clamped to `1..=`[`MAX_LIMIT_PER_SCHEMA`]; `0` means
/// [`DEFAULT_LIMIT_PER_SCHEMA`].
///
/// A query with no searchable characters (empty, whitespace, `"((("`) returns
/// an empty result rather than an error: there is nothing to search for, and a
/// half-typed query is not a mistake worth an error dialog.
pub fn search_all(
    store: &SqliteItemStore,
    query: &str,
    limit_per_schema: u32,
) -> Result<Vec<SearchHit>, StoreError> {
    let Some(match_expr) = fts_match_expression(query) else {
        return Ok(vec![]);
    };
    let limit = match limit_per_schema {
        0 => DEFAULT_LIMIT_PER_SCHEMA,
        n => n.min(MAX_LIMIT_PER_SCHEMA),
    };

    // The per-kind cap is a window function over the joined rows, not a
    // `LIMIT`: a plain limit would let the noisiest schema fill the whole
    // budget, which is the failure this surface exists to avoid.
    let sql = format!(
        "WITH hits AS (
             SELECT item_id AS hit_id,
                    bm25(items_fts) AS rank,
                    snippet(items_fts, -1, '', '', '…', {SNIPPET_TOKENS}) AS snip
             FROM items_fts
             WHERE items_fts MATCH ?1
         ),
         ranked AS (
             SELECT i.id AS id,
                    i.schema_ref AS schema_ref,
                    {TITLE_EXPR} AS title,
                    h.snip AS snip,
                    h.rank AS rank,
                    ROW_NUMBER() OVER (
                        PARTITION BY i.schema_ref ORDER BY h.rank ASC, i.id ASC
                    ) AS kind_rank
             FROM hits h
             JOIN items i ON i.id = h.hit_id
             WHERE json_extract(i.payload, '$.status') IS NOT ?2
         )
         SELECT id, schema_ref, title, snip, rank
         FROM ranked
         WHERE kind_rank <= ?3
         ORDER BY schema_ref ASC, rank ASC, id ASC"
    );

    store.query_raw(
        &sql,
        &[&match_expr, &STATUS_DISMISSED, &limit],
        |row| -> Result<SearchHit, rusqlite::Error> {
            let title: String = row.get(2)?;
            let snippet: String = row.get(3)?;
            let snippet = if snippet.trim().is_empty() {
                title.clone()
            } else {
                snippet
            };
            Ok(SearchHit {
                id: row.get(0)?,
                schema_ref: row.get(1)?,
                title,
                snippet,
                rank: row.get(4)?,
            })
        },
    )
}

/// Turn arbitrary user input into an FTS5 MATCH expression, or `None` when
/// there is nothing to search for.
///
/// Every character that is not alphanumeric becomes a separator, and each
/// surviving token is emitted as a quoted prefix term (`"dark"*`). Two
/// consequences worth knowing:
///
/// * **No syntax can leak.** `foo AND (` becomes `"foo"* "AND"*` — a search
///   for two literal words, not a parse error. FTS5 operators are only
///   operators when unquoted, so a user searching for the word "and" gets what
///   they asked for.
/// * **Terms are ANDed and prefix-matched**, matching the `Contains` predicate
///   convention in `sql_query::fts_escape`: typing "scal" finds "Scaling"
///   while the user is still typing.
pub fn fts_match_expression(query: &str) -> Option<String> {
    let cleaned: String = query
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { ' ' })
        .collect();
    let terms: Vec<String> = cleaned
        .split_whitespace()
        .map(|t| format!("\"{t}\"*"))
        .collect();
    if terms.is_empty() {
        None
    } else {
        Some(terms.join(" "))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::{Item, Priority, Value, Visibility};
    use crate::store::ItemStore;
    use crate::triage_ops;
    use chrono::Utc;
    use std::collections::BTreeMap;

    fn open() -> SqliteItemStore {
        SqliteItemStore::open_in_memory().expect("open in-memory store")
    }

    /// Insert an item with the given payload fields, returning its id string.
    fn make(store: &SqliteItemStore, schema: &str, fields: &[(&str, &str)]) -> String {
        let now = Utc::now();
        let mut payload: BTreeMap<String, Value> = BTreeMap::new();
        for (k, v) in fields {
            payload.insert((*k).into(), Value::String((*v).into()));
        }
        let item = Item {
            id: uuid::Uuid::new_v4(),
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

    fn titled(store: &SqliteItemStore, schema: &str, title: &str) -> String {
        make(store, schema, &[("title", title)])
    }

    fn schemas(hits: &[SearchHit]) -> Vec<&str> {
        hits.iter().map(|h| h.schema_ref.as_str()).collect()
    }

    fn ids(hits: &[SearchHit]) -> Vec<&str> {
        hits.iter().map(|h| h.id.as_str()).collect()
    }

    // ─── Sanitization ────────────────────────────────────────────────────

    #[test]
    fn match_expression_quotes_every_term() {
        assert_eq!(
            fts_match_expression("dark matter").as_deref(),
            Some("\"dark\"* \"matter\"*")
        );
        // FTS5 operators are neutralised into literal terms.
        assert_eq!(
            fts_match_expression("foo AND (").as_deref(),
            Some("\"foo\"* \"AND\"*")
        );
        // Nothing searchable at all.
        for empty in ["", "   ", "((", "\"\"\"", "-- ; --"] {
            assert_eq!(fts_match_expression(empty), None, "{empty:?}");
        }
    }

    /// The point of the sanitizer: a half-typed query is common, and every one
    /// of these is an FTS5 syntax error if passed through raw.
    #[test]
    fn hostile_queries_do_not_crash_the_search() {
        let store = open();
        let id = titled(&store, "manuscript", "Rotation curves and dark matter");

        for hostile in [
            "foo AND (",
            "\"unbalanced",
            "NEAR(",
            "a OR OR b",
            "col:*",
            "*",
            ")))",
            "dark^matter",
            "'; DROP TABLE items; --",
            "NOT",
            "matter*\"",
        ] {
            let hits = search_all(&store, hostile, 10)
                .unwrap_or_else(|e| panic!("query {hostile:?} must not error: {e}"));
            // Whatever it returns, it must be a coherent result set.
            for h in &hits {
                assert!(!h.id.is_empty());
            }
        }

        // And a plain query still works afterwards.
        let hits = search_all(&store, "dark", 10).unwrap();
        assert_eq!(ids(&hits), vec![id.as_str()]);
    }

    #[test]
    fn empty_query_returns_nothing_rather_than_everything() {
        let store = open();
        titled(&store, "manuscript", "Anything");
        assert!(search_all(&store, "", 10).unwrap().is_empty());
        assert!(search_all(&store, "   ", 10).unwrap().is_empty());
        assert!(search_all(&store, "()[]", 10).unwrap().is_empty());
    }

    // ─── Mixed kinds ─────────────────────────────────────────────────────

    #[test]
    fn one_query_spans_every_record_kind() {
        let store = open();
        titled(&store, "manuscript", "Nucleosynthesis in dwarf galaxies");
        titled(&store, "figure", "Nucleosynthesis yields");
        make(
            &store,
            "email-message",
            // Mail maps subject→title / from→author_text / body→body.
            &[
                ("subject", "Re: nucleosynthesis draft"),
                ("from", "collaborator@example.edu"),
                ("body", "the nucleosynthesis section needs a figure"),
            ],
        );
        make(
            &store,
            "imbib/bibliography-entry",
            &[
                ("title", "Explosive nucleosynthesis"),
                ("abstract_text", "A review of nucleosynthesis channels."),
            ],
        );
        titled(&store, "manuscript", "Unrelated methods paper");

        let hits = search_all(&store, "nucleosynthesis", 10).unwrap();
        let mut kinds = schemas(&hits);
        kinds.sort_unstable();
        kinds.dedup();
        assert_eq!(
            kinds,
            vec![
                "email-message",
                "figure",
                "imbib/bibliography-entry",
                "manuscript"
            ],
            "one FTS query must reach every kind: {hits:?}"
        );
        assert_eq!(hits.len(), 4, "the unrelated manuscript must not match");

        // Buckets are contiguous, so a caller can group by walking once.
        let ordered = schemas(&hits);
        let mut seen: Vec<&str> = vec![];
        for kind in ordered {
            if seen.last() != Some(&kind) {
                assert!(!seen.contains(&kind), "bucket {kind} is not contiguous");
                seen.push(kind);
            }
        }
    }

    #[test]
    fn mail_body_and_abstract_columns_are_searchable() {
        let store = open();
        let mail = make(
            &store,
            "email-message",
            &[("subject", "Logistics"), ("body", "the telescope proposal")],
        );
        let paper = make(
            &store,
            "imbib/bibliography-entry",
            &[("title", "A paper"), ("abstract_text", "telescope optics")],
        );
        let hits = search_all(&store, "telescope", 10).unwrap();
        let found = ids(&hits);
        assert!(found.contains(&mail.as_str()), "mail body: {hits:?}");
        assert!(found.contains(&paper.as_str()), "abstract: {hits:?}");
    }

    #[test]
    fn prefix_matching_finds_partial_words() {
        let store = open();
        let id = titled(&store, "manuscript", "Scaling relations");
        assert_eq!(ids(&search_all(&store, "scal", 10).unwrap()), vec![id]);
    }

    // ─── Fairness ────────────────────────────────────────────────────────

    /// The reason the cap is per kind and applied in SQL: a mailbox must not
    /// be able to push every manuscript off the surface.
    #[test]
    fn one_noisy_schema_cannot_crowd_out_the_others() {
        let store = open();
        for n in 0..50 {
            make(
                &store,
                "email-message",
                &[
                    ("subject", &format!("meeting notes {n}")),
                    ("body", "notes"),
                ],
            );
        }
        let manuscript = titled(&store, "manuscript", "Meeting notes writeup");
        let figure = titled(&store, "figure", "Meeting notes sketch");

        let hits = search_all(&store, "meeting notes", 3).unwrap();
        let mail = hits
            .iter()
            .filter(|h| h.schema_ref == "email-message")
            .count();
        assert_eq!(mail, 3, "the per-kind cap must bind: {mail}");
        assert!(
            ids(&hits).contains(&manuscript.as_str()),
            "the manuscript must survive 50 messages"
        );
        assert!(ids(&hits).contains(&figure.as_str()));
        assert_eq!(hits.len(), 5, "3 messages + 1 manuscript + 1 figure");
    }

    #[test]
    fn limit_zero_uses_the_default_and_absurd_limits_are_clamped() {
        let store = open();
        for n in 0..(DEFAULT_LIMIT_PER_SCHEMA + 5) {
            titled(&store, "manuscript", &format!("draft {n} widget"));
        }
        assert_eq!(
            search_all(&store, "widget", 0).unwrap().len(),
            DEFAULT_LIMIT_PER_SCHEMA as usize,
            "0 means the default cap, not 'no results'"
        );
        assert_eq!(
            search_all(&store, "widget", u32::MAX).unwrap().len(),
            (DEFAULT_LIMIT_PER_SCHEMA + 5) as usize,
            "an absurd cap is clamped, not rejected"
        );
    }

    #[test]
    fn results_are_ordered_deterministically() {
        let store = open();
        for n in 0..8 {
            titled(&store, "manuscript", &format!("orbit paper {n}"));
            titled(&store, "figure", &format!("orbit panel {n}"));
        }
        let first = search_all(&store, "orbit", 20).unwrap();
        let second = search_all(&store, "orbit", 20).unwrap();
        assert_eq!(first, second, "the same query must give the same order");
        // Ordered by schema_ref, so "figure" precedes "manuscript".
        assert_eq!(first.first().map(|h| h.schema_ref.as_str()), Some("figure"));
        assert_eq!(
            first.last().map(|h| h.schema_ref.as_str()),
            Some("manuscript")
        );
    }

    // ─── Status ──────────────────────────────────────────────────────────

    #[test]
    fn dismissed_items_are_withheld_but_archived_ones_are_not() {
        let store = open();
        let live = titled(&store, "task", "Refit the pipeline");
        let archived = titled(&store, "task", "Refit the calibration");
        let dismissed = titled(&store, "task", "Refit everything, someday");

        triage_ops::set_status(&store, &archived, Some(triage_ops::STATUS_ARCHIVED)).unwrap();
        triage_ops::set_status(&store, &dismissed, Some(STATUS_DISMISSED)).unwrap();

        let found = ids(&search_all(&store, "refit", 10).unwrap())
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>();
        assert!(found.contains(&live), "live task missing");
        assert!(
            found.contains(&archived),
            "archived items stay findable — only dismissal hides a thing"
        );
        assert!(
            !found.contains(&dismissed),
            "dismissed items are reachable through their own section, not global search"
        );

        // Un-dismissing puts it back.
        triage_ops::set_status(&store, &dismissed, None).unwrap();
        assert!(ids(&search_all(&store, "refit", 10).unwrap()).contains(&dismissed.as_str()));
    }

    // ─── Shape ───────────────────────────────────────────────────────────

    #[test]
    fn hits_carry_a_title_and_a_snippet() {
        let store = open();
        make(
            &store,
            "manuscript",
            &[
                ("title", "Turbulent convection"),
                ("body_content", "A long section about turbulent convection in stellar envelopes that keeps going for a while."),
            ],
        );
        let hits = search_all(&store, "convection", 10).unwrap();
        assert_eq!(hits.len(), 1);
        let hit = &hits[0];
        assert_eq!(hit.title, "Turbulent convection");
        assert!(!hit.snippet.is_empty(), "snippet must never be blank");
        assert!(
            hit.snippet.to_lowercase().contains("convection"),
            "snippet should show the match: {:?}",
            hit.snippet
        );
        assert!(hit.rank < 0.0, "bm25 scores are negative; lower is better");
    }

    /// Collections carry `name`, not `title` — the display title must still
    /// resolve, or a mixed-kind surface shows blank rows.
    #[test]
    fn name_only_items_still_get_a_title() {
        let store = open();
        make(&store, "collection", &[("name", "Grant renewal")]);
        // `name` is not an FTS column, so it is found through its note.
        make(
            &store,
            "collection",
            &[("name", "Reading queue"), ("note", "queue of grant papers")],
        );
        let hits = search_all(&store, "grant", 10).unwrap();
        assert_eq!(hits.len(), 1, "{hits:?}");
        assert_eq!(hits[0].title, "Reading queue");
    }
}
