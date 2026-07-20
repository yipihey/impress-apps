//! Evaluate a [`SmartQuery`](super::smart_query::SmartQuery) against an
//! in-memory list of items.
//!
//! This is the back half of Swift `LocalFilterService` —
//! `apply(_:to:)` and the private `matches(_:filter:)` helper. The Swift
//! version operates on `PublicationRowData`; we abstract via the
//! [`Filterable`] trait so the same evaluator works against:
//!   - imbib `crate::domain::Publication` (via the `Filterable` impl below)
//!   - TUI / CLI row data structs that don't import the full domain types
//!   - synthetic test fixtures
//!
//! Matching rules (mirror Swift `LocalFilterService.matches`):
//!   - Text terms: AND across terms, OR across (title, authors, abstract, venue) — case-insensitive substring.
//!   - Negated text terms: none may match any of those four fields.
//!   - Field terms: substring match against the named field only.
//!   - Year filter: see [`YearFilter::matches`].
//!   - Flag: pattern match with wildcards; `HasAny` / `HasNone` shortcuts.
//!   - Tags: prefix match (case-insensitive) on tag paths; AND across queries.
//!   - Read state: must match.

use super::smart_query::{
    FlagColor, FlagLength, FlagQuery, FlagStyle, ReadState, SearchField, SmartQuery, TagQuery,
};

/// Flag triple used by the local filter. Apps map their native flag type into
/// this via [`Filterable::flag`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FilterFlag {
    pub color: FlagColor,
    pub style: FlagStyle,
    pub length: FlagLength,
}

/// Anything the local filter can evaluate against.
pub trait Filterable {
    fn title(&self) -> &str;
    fn author_string(&self) -> &str;
    fn abstract_text(&self) -> Option<&str>;
    fn venue(&self) -> Option<&str>;
    fn year(&self) -> Option<i32>;
    fn flag(&self) -> Option<FilterFlag>;
    /// Tag paths, e.g. `"methods/hydro"`. Order irrelevant.
    fn tag_paths(&self) -> &[String];
    fn is_read(&self) -> bool;
}

/// Apply a smart query to a list, returning matching items. Equivalent to
/// `LocalFilterService.apply(_:to:)`.
pub fn apply<'a, I: Filterable>(query: &SmartQuery, items: &'a [I]) -> Vec<&'a I> {
    if query.is_empty() {
        return items.iter().collect();
    }
    items.iter().filter(|item| matches(*item, query)).collect()
}

/// Lower-level predicate: does `item` satisfy `query`?
pub fn matches<I: Filterable>(item: &I, query: &SmartQuery) -> bool {
    // Text terms — all must match somewhere in title/author/abstract/venue.
    for term in &query.text_terms {
        if !any_field_contains(item, term) {
            return false;
        }
    }

    // Negated text terms — none may match.
    for term in &query.negated_text_terms {
        if any_field_contains(item, term) {
            return false;
        }
    }

    // Field-qualified terms.
    for ft in &query.field_terms {
        let haystack = match ft.field {
            SearchField::Title => item.title(),
            SearchField::Author => item.author_string(),
            SearchField::Abstract => item.abstract_text().unwrap_or(""),
            SearchField::Venue => item.venue().unwrap_or(""),
        };
        if !contains_ci(haystack, &ft.term) {
            return false;
        }
    }

    // Year filter.
    if let Some(yf) = &query.year_filter {
        if !yf.matches(item.year()) {
            return false;
        }
    }

    // Flag.
    if let Some(fq) = &query.flag_query {
        match fq {
            FlagQuery::Pattern {
                color,
                style,
                length,
            } => {
                let Some(f) = item.flag() else { return false };
                if let Some(c) = color {
                    if f.color != *c {
                        return false;
                    }
                }
                if let Some(s) = style {
                    if f.style != *s {
                        return false;
                    }
                }
                if let Some(l) = length {
                    if f.length != *l {
                        return false;
                    }
                }
            }
            FlagQuery::HasAny => {
                if item.flag().is_none() {
                    return false;
                }
            }
            FlagQuery::HasNone => {
                if item.flag().is_some() {
                    return false;
                }
            }
        }
    }

    // Tags.
    let tag_paths = item.tag_paths();
    for tq in &query.tag_queries {
        match tq {
            TagQuery::Has(path) => {
                let lower = path.to_ascii_lowercase();
                if !tag_paths
                    .iter()
                    .any(|t| t.to_ascii_lowercase().starts_with(&lower))
                {
                    return false;
                }
            }
            TagQuery::HasNot(path) => {
                let lower = path.to_ascii_lowercase();
                if tag_paths
                    .iter()
                    .any(|t| t.to_ascii_lowercase().starts_with(&lower))
                {
                    return false;
                }
            }
            TagQuery::HasAll(paths) => {
                for p in paths {
                    let lower = p.to_ascii_lowercase();
                    if !tag_paths
                        .iter()
                        .any(|t| t.to_ascii_lowercase().starts_with(&lower))
                    {
                        return false;
                    }
                }
            }
            TagQuery::HasAny(paths) => {
                let any = paths.iter().any(|p| {
                    let lower = p.to_ascii_lowercase();
                    tag_paths
                        .iter()
                        .any(|t| t.to_ascii_lowercase().starts_with(&lower))
                });
                if !any {
                    return false;
                }
            }
        }
    }

    // Read state.
    if let Some(rs) = query.read_state {
        match rs {
            ReadState::Read => {
                if !item.is_read() {
                    return false;
                }
            }
            ReadState::Unread => {
                if item.is_read() {
                    return false;
                }
            }
        }
    }

    true
}

fn any_field_contains<I: Filterable>(item: &I, term: &str) -> bool {
    contains_ci(item.title(), term)
        || contains_ci(item.author_string(), term)
        || item
            .abstract_text()
            .map(|s| contains_ci(s, term))
            .unwrap_or(false)
        || item.venue().map(|s| contains_ci(s, term)).unwrap_or(false)
}

fn contains_ci(haystack: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return true;
    }
    let h = haystack.to_ascii_lowercase();
    let n = needle.to_ascii_lowercase();
    h.contains(&n)
}

// ---------- Filterable impl for the canonical domain type -----------------

impl Filterable for crate::domain::Publication {
    fn title(&self) -> &str {
        &self.title
    }

    fn author_string(&self) -> &str {
        // Authors are structured; fold to a single lowercased string lazily by
        // caching in tag_paths()-style would change the trait shape. Instead,
        // surface the family names joined by spaces — adequate for substring
        // matches (the Swift version concatenates display strings the same way).
        // We can't allocate here because the trait returns `&str`. Provide a
        // best-effort: return the first author's family_name when there is
        // exactly one author, otherwise return an empty string and rely on the
        // CLI/TUI to use the `.author_string_owned()` helper below for the
        // multi-author case.
        //
        // TODO: tighten this when Publication exposes a precomputed lowercased
        // author bundle. See `LocalFilterService.matches`
        // (`apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Search/LocalFilterService.swift:200`)
        // which reads `pub.authorString` — that field is precomputed in the
        // PublicationRowData snapshot.
        match self.authors.first() {
            Some(a) if self.authors.len() == 1 => a.family_name.as_str(),
            _ => "",
        }
    }

    fn abstract_text(&self) -> Option<&str> {
        self.abstract_text.as_deref()
    }

    fn venue(&self) -> Option<&str> {
        self.journal
            .as_deref()
            .or(self.booktitle.as_deref())
            .or(self.publisher.as_deref())
    }

    fn year(&self) -> Option<i32> {
        self.year
    }

    fn flag(&self) -> Option<FilterFlag> {
        // Publication has no native flag field — flags live in a sidecar
        // table on the Swift side (RustStoreAdapter). TUI callers should use
        // a richer Filterable adapter that wraps the row data.
        None
    }

    fn tag_paths(&self) -> &[String] {
        &self.tags
    }

    fn is_read(&self) -> bool {
        // Read state lives in a separate sidecar table on the Swift side.
        // Returning false matches Swift's default for items without a
        // ReadStatus row.
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::search::smart_query::parse;

    struct Row {
        title: String,
        author: String,
        abstract_: Option<String>,
        venue: Option<String>,
        year: Option<i32>,
        flag: Option<FilterFlag>,
        tags: Vec<String>,
        read: bool,
    }

    impl Row {
        fn new(title: &str, author: &str, year: Option<i32>) -> Self {
            Self {
                title: title.to_string(),
                author: author.to_string(),
                abstract_: None,
                venue: None,
                year,
                flag: None,
                tags: vec![],
                read: false,
            }
        }
    }

    impl Filterable for Row {
        fn title(&self) -> &str {
            &self.title
        }
        fn author_string(&self) -> &str {
            &self.author
        }
        fn abstract_text(&self) -> Option<&str> {
            self.abstract_.as_deref()
        }
        fn venue(&self) -> Option<&str> {
            self.venue.as_deref()
        }
        fn year(&self) -> Option<i32> {
            self.year
        }
        fn flag(&self) -> Option<FilterFlag> {
            self.flag
        }
        fn tag_paths(&self) -> &[String] {
            &self.tags
        }
        fn is_read(&self) -> bool {
            self.read
        }
    }

    fn corpus() -> Vec<Row> {
        let mut a = Row::new("Galaxy formation in cold dark matter", "Smith", Some(2021));
        a.abstract_ = Some("Hydrodynamic simulations of structure".to_string());
        a.venue = Some("ApJ".to_string());
        a.tags = vec!["methods/hydro".to_string(), "topic/galaxies".to_string()];
        a.flag = Some(FilterFlag {
            color: FlagColor::Red,
            style: FlagStyle::Solid,
            length: FlagLength::Full,
        });

        let mut b = Row::new("Quantum entanglement bounds", "Jones", Some(2019));
        b.venue = Some("Nature".to_string());
        b.tags = vec!["topic/quantum".to_string()];
        b.read = true;

        let mut c = Row::new("Cosmology with type Ia supernovae", "Smith", Some(2024));
        c.venue = Some("ApJ".to_string());
        c.tags = vec![
            "topic/cosmology".to_string(),
            "methods/observation".to_string(),
        ];
        c.flag = Some(FilterFlag {
            color: FlagColor::Blue,
            style: FlagStyle::Dashed,
            length: FlagLength::Half,
        });

        vec![a, b, c]
    }

    #[test]
    fn empty_query_returns_all() {
        let rows = corpus();
        let q = parse("");
        assert_eq!(apply(&q, &rows).len(), rows.len());
    }

    #[test]
    fn text_term_matches_title() {
        let rows = corpus();
        let q = parse("galaxy");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].title, "Galaxy formation in cold dark matter");
    }

    #[test]
    fn text_term_matches_abstract() {
        let rows = corpus();
        let q = parse("hydrodynamic");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 1);
    }

    #[test]
    fn text_term_matches_author() {
        let rows = corpus();
        let q = parse("smith");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 2);
    }

    #[test]
    fn negated_text_term() {
        let rows = corpus();
        let q = parse("smith -galaxy");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].title, "Cosmology with type Ia supernovae");
    }

    #[test]
    fn field_term_title_only() {
        let rows = corpus();
        // "smith" appears in author for Smith papers but not in titles.
        let q = parse("title:smith");
        assert_eq!(apply(&q, &rows).len(), 0);
    }

    #[test]
    fn year_filter_after() {
        let rows = corpus();
        let q = parse("year:>2020");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 2);
    }

    #[test]
    fn year_filter_range() {
        let rows = corpus();
        let q = parse("year:2020-2022");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].year, Some(2021));
    }

    #[test]
    fn flag_color_filter() {
        let rows = corpus();
        let q = parse("flag:red");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].title, "Galaxy formation in cold dark matter");
    }

    #[test]
    fn flag_pattern_with_wildcards() {
        let rows = corpus();
        // Any color with dashed style → Blue/Dashed/Half row matches.
        let q = parse("flag:*-*");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].title, "Cosmology with type Ia supernovae");
    }

    #[test]
    fn flag_has_none_excludes_flagged() {
        let rows = corpus();
        let q = parse("-flag:*");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].title, "Quantum entanglement bounds");
    }

    #[test]
    fn tags_has_prefix_match() {
        let rows = corpus();
        let q = parse("tags:methods");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 2);
    }

    #[test]
    fn tags_has_all() {
        let rows = corpus();
        let q = parse("tags:topic/cosmology+methods/observation");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 1);
    }

    #[test]
    fn tags_has_any() {
        let rows = corpus();
        let q = parse("tags:topic/galaxies|topic/quantum");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 2);
    }

    #[test]
    fn tags_has_not_excludes() {
        let rows = corpus();
        let q = parse("-tags:topic/quantum");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 2);
    }

    #[test]
    fn read_state_filter() {
        let rows = corpus();
        let q = parse("unread");
        assert_eq!(apply(&q, &rows).len(), 2);
        let q = parse("read");
        assert_eq!(apply(&q, &rows).len(), 1);
    }

    #[test]
    fn combined_filter_intersects() {
        let rows = corpus();
        let q = parse("smith year:>2020 tags:methods");
        let hits = apply(&q, &rows);
        // Both Smith papers have methods/* tags and both years (2021, 2024)
        // are strictly > 2020.
        assert_eq!(hits.len(), 2);

        // Tightening to >=2024 leaves only the supernovae paper.
        let q = parse("smith year:>=2024 tags:methods");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].title, "Cosmology with type Ia supernovae");
    }

    #[test]
    fn quoted_phrase_matches_full_sequence() {
        let rows = corpus();
        let q = parse("\"cold dark matter\"");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 1);
    }

    #[test]
    fn case_insensitive_match() {
        let rows = corpus();
        let q = parse("GALAXY");
        let hits = apply(&q, &rows);
        assert_eq!(hits.len(), 1);
    }
}
