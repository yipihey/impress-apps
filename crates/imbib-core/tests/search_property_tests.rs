//! Property-based tests for the search stack:
//!   - `search::smart_query` — parser totality + print/parse round-trip
//!   - `search::local_filter` — boolean-algebra semantics on a synthetic corpus
//!   - `search::ads_normalizer` — totality + idempotence
//!
//! Style mirrors `tests/deduplication_tests.rs` (proptest blocks after
//! deterministic helpers).

use imbib_core::search::ads_normalizer::normalize;
use imbib_core::search::local_filter::{apply, Filterable, FilterFlag};
use imbib_core::search::smart_query::{
    parse, FieldTerm, FlagColor, FlagLength, FlagQuery, FlagStyle, ReadState, SearchField,
    SmartQuery, TagQuery, YearFilter,
};
use proptest::prelude::*;

// ===========================================================================
// SmartQuery printer (test-side only — the crate has no printer). Renders an
// AST back to smart-search syntax such that `parse(print(q)) == q` for ASTs
// built from the restricted generators below.
// ===========================================================================

fn flag_color_char(c: FlagColor) -> char {
    match c {
        FlagColor::Red => 'r',
        FlagColor::Amber => 'a',
        FlagColor::Blue => 'b',
        FlagColor::Green => 'g',
    }
}

fn flag_style_char(s: FlagStyle) -> char {
    match s {
        FlagStyle::Solid => 's',
        FlagStyle::Dashed => '-',
        FlagStyle::Dotted => '.',
    }
}

fn flag_length_char(l: FlagLength) -> char {
    match l {
        FlagLength::Full => 'f',
        FlagLength::Half => 'h',
        FlagLength::Quarter => 'q',
    }
}

fn print_query(q: &SmartQuery) -> String {
    let mut parts: Vec<String> = Vec::new();

    if let Some(fq) = &q.flag_query {
        match fq {
            FlagQuery::HasAny => parts.push("flag:*".to_string()),
            FlagQuery::HasNone => parts.push("-flag:*".to_string()),
            FlagQuery::Pattern { color, style, length } => {
                let c = color.map(flag_color_char).unwrap_or('*');
                let s = style.map(flag_style_char).unwrap_or('*');
                let l = length.map(flag_length_char).unwrap_or('*');
                parts.push(format!("flag:{}{}{}", c, s, l));
            }
        }
    }

    for tq in &q.tag_queries {
        match tq {
            TagQuery::Has(p) => parts.push(format!("tags:{}", p)),
            TagQuery::HasNot(p) => parts.push(format!("-tags:{}", p)),
            TagQuery::HasAll(ps) => parts.push(format!("tags:{}", ps.join("+"))),
            TagQuery::HasAny(ps) => parts.push(format!("tags:{}", ps.join("|"))),
        }
    }

    if let Some(yf) = &q.year_filter {
        match yf {
            YearFilter::Exact(y) => parts.push(format!("year:{}", y)),
            YearFilter::Range(lo, hi) => parts.push(format!("year:{}-{}", lo, hi)),
            YearFilter::After(y) => parts.push(format!("year:>{}", y)),
            YearFilter::Before(y) => parts.push(format!("year:<{}", y)),
        }
    }

    for ft in &q.field_terms {
        // SearchField's Display gives the long prefix form ("title", ...),
        // which parses unambiguously (unlike "t:" / "b:").
        parts.push(format!("{}:{}", ft.field, ft.term));
    }

    for t in &q.text_terms {
        parts.push(t.clone());
    }
    for t in &q.negated_text_terms {
        parts.push(format!("-{}", t));
    }

    if let Some(rs) = q.read_state {
        parts.push(match rs {
            ReadState::Read => "read".to_string(),
            ReadState::Unread => "unread".to_string(),
        });
    }

    parts.join(" ")
}

// ===========================================================================
// Generators
// ===========================================================================

/// A bare word that the parser can only interpret as a text term:
/// lowercase ASCII, no colon, not "read"/"unread".
fn safe_word() -> impl Strategy<Value = String> {
    "[a-z]{3,10}".prop_filter("read/unread are keywords", |w| w != "read" && w != "unread")
}

/// A tag path: 1–3 lowercase segments, no `+`, `|`, `:`, spaces.
fn safe_tag_path() -> impl Strategy<Value = String> {
    prop::collection::vec("[a-z]{1,6}", 1..=3).prop_map(|segs| segs.join("/"))
}

fn arb_search_field() -> impl Strategy<Value = SearchField> {
    prop_oneof![
        Just(SearchField::Title),
        Just(SearchField::Author),
        Just(SearchField::Abstract),
        Just(SearchField::Venue),
    ]
}

fn arb_year_filter() -> impl Strategy<Value = YearFilter> {
    prop_oneof![
        (1000i32..=9998).prop_map(YearFilter::Exact),
        (1000i32..=9998).prop_flat_map(|lo| (Just(lo), lo..=9998).prop_map(|(lo, hi)| YearFilter::Range(lo, hi))),
        (1000i32..=9998).prop_map(YearFilter::After),
        (1000i32..=9998).prop_map(YearFilter::Before),
    ]
}

fn arb_flag_query() -> impl Strategy<Value = FlagQuery> {
    let color = prop::option::of(prop_oneof![
        Just(FlagColor::Red),
        Just(FlagColor::Amber),
        Just(FlagColor::Blue),
        Just(FlagColor::Green),
    ]);
    let style = prop::option::of(prop_oneof![
        Just(FlagStyle::Solid),
        Just(FlagStyle::Dashed),
        Just(FlagStyle::Dotted),
    ]);
    let length = prop::option::of(prop_oneof![
        Just(FlagLength::Full),
        Just(FlagLength::Half),
        Just(FlagLength::Quarter),
    ]);
    prop_oneof![
        Just(FlagQuery::HasAny),
        Just(FlagQuery::HasNone),
        (color, style, length).prop_map(|(color, style, length)| FlagQuery::Pattern {
            color,
            style,
            length
        }),
    ]
}

fn arb_tag_query() -> impl Strategy<Value = TagQuery> {
    prop_oneof![
        safe_tag_path().prop_map(TagQuery::Has),
        safe_tag_path().prop_map(TagQuery::HasNot),
        prop::collection::vec(safe_tag_path(), 2..=3).prop_map(TagQuery::HasAll),
        prop::collection::vec(safe_tag_path(), 2..=3).prop_map(TagQuery::HasAny),
    ]
}

fn arb_smart_query() -> impl Strategy<Value = SmartQuery> {
    (
        prop::collection::vec(safe_word(), 0..3),
        prop::collection::vec(safe_word(), 0..3),
        prop::collection::vec(
            (arb_search_field(), safe_word()).prop_map(|(field, term)| FieldTerm { field, term }),
            0..3,
        ),
        prop::option::of(arb_year_filter()),
        prop::option::of(arb_flag_query()),
        prop::collection::vec(arb_tag_query(), 0..3),
        prop::option::of(prop_oneof![Just(ReadState::Read), Just(ReadState::Unread)]),
    )
        .prop_map(
            |(text_terms, negated_text_terms, field_terms, year_filter, flag_query, tag_queries, read_state)| SmartQuery {
                text_terms,
                negated_text_terms,
                field_terms,
                year_filter,
                flag_query,
                tag_queries,
                read_state,
            },
        )
}

// ===========================================================================
// Synthetic corpus for local_filter
// ===========================================================================

#[derive(Debug, Clone)]
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

/// Small closed vocabulary so random queries actually hit rows.
const VOCAB: &[&str] = &[
    "galaxy", "quantum", "dark", "energy", "matter", "hydro", "cosmology", "smith", "jones",
];

const TAG_VOCAB: &[&str] = &[
    "methods",
    "methods/hydro",
    "methods/obs",
    "topic",
    "topic/galaxies",
    "topic/quantum",
];

fn vocab_word() -> impl Strategy<Value = String> {
    prop::sample::select(VOCAB).prop_map(|s| s.to_string())
}

fn vocab_tag() -> impl Strategy<Value = String> {
    prop::sample::select(TAG_VOCAB).prop_map(|s| s.to_string())
}

fn arb_flag() -> impl Strategy<Value = FilterFlag> {
    (
        prop_oneof![
            Just(FlagColor::Red),
            Just(FlagColor::Amber),
            Just(FlagColor::Blue),
            Just(FlagColor::Green),
        ],
        prop_oneof![
            Just(FlagStyle::Solid),
            Just(FlagStyle::Dashed),
            Just(FlagStyle::Dotted),
        ],
        prop_oneof![
            Just(FlagLength::Full),
            Just(FlagLength::Half),
            Just(FlagLength::Quarter),
        ],
    )
        .prop_map(|(color, style, length)| FilterFlag { color, style, length })
}

fn arb_row() -> impl Strategy<Value = Row> {
    (
        prop::collection::vec(vocab_word(), 1..4),
        vocab_word(),
        prop::option::of(prop::collection::vec(vocab_word(), 1..3)),
        prop::option::of(vocab_word()),
        prop::option::of(1990i32..2030),
        prop::option::of(arb_flag()),
        prop::collection::vec(vocab_tag(), 0..3),
        any::<bool>(),
    )
        .prop_map(|(title_words, author, abs, venue, year, flag, tags, read)| Row {
            title: title_words.join(" "),
            author,
            abstract_: abs.map(|w| w.join(" ")),
            venue,
            year,
            flag,
            tags,
            read,
        })
}

fn arb_corpus() -> impl Strategy<Value = Vec<Row>> {
    prop::collection::vec(arb_row(), 0..12)
}

/// Titles are unique-ified so we can compare hit sets by title.
fn indexed(rows: Vec<Row>) -> Vec<Row> {
    rows.into_iter()
        .enumerate()
        .map(|(i, mut r)| {
            r.title = format!("{} id{}", r.title, i);
            r
        })
        .collect()
}

fn hit_titles(query: &SmartQuery, rows: &[Row]) -> Vec<String> {
    apply(query, rows).iter().map(|r| r.title.clone()).collect()
}

/// A query string composed only of conjunctive parts (text terms, negated
/// text, tag Has queries) — concatenation of two such strings is a pure AND.
fn conjunctive_query_string() -> impl Strategy<Value = String> {
    prop::collection::vec(
        prop_oneof![
            vocab_word(),
            vocab_word().prop_map(|w| format!("-{}", w)),
            vocab_tag().prop_map(|t| format!("tags:{}", t)),
            vocab_tag().prop_map(|t| format!("-tags:{}", t)),
        ],
        1..4,
    )
    .prop_map(|parts| parts.join(" "))
}

// ===========================================================================
// Properties: smart_query parser
// ===========================================================================

proptest! {
    /// Totality: the parser must never panic, whatever the input.
    ///
    /// BUG (found 2026-07-20): `strip_prefix_ci` slices `token[..prefix.len()]`
    /// at a byte offset, which panics on non-ASCII input whose first char is
    /// 3+ bytes wide. Minimal counterexample: `parse("€")` panics with
    /// "byte index 2 is not a char boundary".
    #[test]
    #[ignore = "BUG: smart_query::parse panics on multi-byte input, e.g. parse(\"€\") — strip_prefix_ci slices at a non-char boundary"]
    fn smart_query_parse_is_total(input in ".*") {
        let _ = parse(&input);
    }

    /// Totality restricted to ASCII (holds today; guards the non-Unicode part
    /// of the contract while the boundary bug above is open).
    #[test]
    fn smart_query_parse_is_total_ascii(input in "[ -~\t\r\n]*") {
        let _ = parse(&input);
    }

    /// Round-trip: printing an AST and re-parsing yields the same AST.
    #[test]
    fn smart_query_print_parse_round_trip(q in arb_smart_query()) {
        let printed = print_query(&q);
        let reparsed = parse(&printed);
        prop_assert_eq!(reparsed, q, "printed form: {:?}", printed);
    }

    /// Whitespace-only input is the empty query.
    #[test]
    fn smart_query_whitespace_is_empty(input in "[ \t\r\n]*") {
        prop_assert!(parse(&input).is_empty());
    }
}

// Minimized regression tripwire for the totality bug above.
#[test]
#[ignore = "BUG: smart_query::parse panics on parse(\"€\") — byte index 2 is not a char boundary in strip_prefix_ci"]
fn smart_query_parse_euro_sign_tripwire() {
    let _ = parse("€");
}

// ===========================================================================
// Properties: local_filter boolean semantics
// ===========================================================================

proptest! {
    /// The empty query returns every item.
    #[test]
    fn local_filter_empty_query_returns_all(rows in arb_corpus()) {
        let rows = indexed(rows);
        let q = parse("");
        prop_assert_eq!(apply(&q, &rows).len(), rows.len());
    }

    /// Concatenating two conjunctive query strings is set intersection.
    #[test]
    fn local_filter_concat_is_intersection(
        rows in arb_corpus(),
        qa in conjunctive_query_string(),
        qb in conjunctive_query_string(),
    ) {
        let rows = indexed(rows);
        let hits_ab = hit_titles(&parse(&format!("{} {}", qa, qb)), &rows);
        let hits_a = hit_titles(&parse(&qa), &rows);
        let hits_b = hit_titles(&parse(&qb), &rows);
        let expected: Vec<String> = hits_a
            .iter()
            .filter(|t| hits_b.contains(t))
            .cloned()
            .collect();
        prop_assert_eq!(hits_ab, expected, "qa={:?} qb={:?}", qa, qb);
    }

    /// `tags:a|b` is the union of `tags:a` and `tags:b`.
    #[test]
    fn local_filter_tag_or_is_union(
        rows in arb_corpus(),
        a in vocab_tag(),
        b in vocab_tag(),
    ) {
        prop_assume!(a != b); // "a|a" parses to HasAny(["a","a"]) — same semantics, but keep it clean
        let rows = indexed(rows);
        let hits_or = hit_titles(&parse(&format!("tags:{}|{}", a, b)), &rows);
        let hits_a = hit_titles(&parse(&format!("tags:{}", a)), &rows);
        let hits_b = hit_titles(&parse(&format!("tags:{}", b)), &rows);
        // Union, in corpus order.
        let expected: Vec<String> = rows
            .iter()
            .map(|r| r.title.clone())
            .filter(|t| hits_a.contains(t) || hits_b.contains(t))
            .collect();
        prop_assert_eq!(hits_or, expected);
    }

    /// `tags:a+b` is the intersection of `tags:a` and `tags:b`.
    #[test]
    fn local_filter_tag_and_is_intersection(
        rows in arb_corpus(),
        a in vocab_tag(),
        b in vocab_tag(),
    ) {
        prop_assume!(a != b);
        let rows = indexed(rows);
        let hits_and = hit_titles(&parse(&format!("tags:{}+{}", a, b)), &rows);
        let hits_a = hit_titles(&parse(&format!("tags:{}", a)), &rows);
        let hits_b = hit_titles(&parse(&format!("tags:{}", b)), &rows);
        let expected: Vec<String> = hits_a.iter().filter(|t| hits_b.contains(t)).cloned().collect();
        prop_assert_eq!(hits_and, expected);
    }

    /// `-tags:p` is the corpus complement of `tags:p`.
    #[test]
    fn local_filter_tag_not_is_complement(rows in arb_corpus(), p in vocab_tag()) {
        let rows = indexed(rows);
        let hits_not = hit_titles(&parse(&format!("-tags:{}", p)), &rows);
        let hits_has = hit_titles(&parse(&format!("tags:{}", p)), &rows);
        let expected: Vec<String> = rows
            .iter()
            .map(|r| r.title.clone())
            .filter(|t| !hits_has.contains(t))
            .collect();
        prop_assert_eq!(hits_not, expected);
    }

    /// `-word` is the corpus complement of `word` (for non-keyword words).
    #[test]
    fn local_filter_negated_text_is_complement(rows in arb_corpus(), w in vocab_word()) {
        let rows = indexed(rows);
        let hits_neg = hit_titles(&parse(&format!("-{}", w)), &rows);
        let hits_pos = hit_titles(&parse(&w), &rows);
        let expected: Vec<String> = rows
            .iter()
            .map(|r| r.title.clone())
            .filter(|t| !hits_pos.contains(t))
            .collect();
        prop_assert_eq!(hits_neg, expected);
    }

    /// `read` and `unread` partition the corpus.
    #[test]
    fn local_filter_read_unread_partition(rows in arb_corpus()) {
        let rows = indexed(rows);
        let read_hits = hit_titles(&parse("read"), &rows);
        let unread_hits = hit_titles(&parse("unread"), &rows);
        prop_assert_eq!(read_hits.len() + unread_hits.len(), rows.len());
        for t in &read_hits {
            prop_assert!(!unread_hits.contains(t));
        }
    }

    /// `flag:*` and `-flag:*` partition the corpus.
    #[test]
    fn local_filter_flag_any_none_partition(rows in arb_corpus()) {
        let rows = indexed(rows);
        let any_hits = hit_titles(&parse("flag:*"), &rows);
        let none_hits = hit_titles(&parse("-flag:*"), &rows);
        prop_assert_eq!(any_hits.len() + none_hits.len(), rows.len());
        for t in &any_hits {
            prop_assert!(!none_hits.contains(t));
        }
    }

    /// apply() preserves corpus order and returns a subsequence.
    #[test]
    fn local_filter_preserves_order(rows in arb_corpus(), q in conjunctive_query_string()) {
        let rows = indexed(rows);
        let hits = hit_titles(&parse(&q), &rows);
        let all_titles: Vec<String> = rows.iter().map(|r| r.title.clone()).collect();
        // hits must be a subsequence of all_titles.
        let mut it = all_titles.iter();
        for h in &hits {
            prop_assert!(it.any(|t| t == h), "hit {:?} out of order or missing", h);
        }
    }
}

// ===========================================================================
// Properties: ads_normalizer
// ===========================================================================

/// ADS-shaped query fragments: exercises the interesting rewrite paths
/// (field prefixes, spaces after colons, quotes, booleans, shorthands).
fn ads_like_query() -> impl Strategy<Value = String> {
    let field = prop::sample::select(&[
        "author", "first_author", "title", "abs", "bibcode", "year", "object", "a", "t", "b",
    ][..]);
    let word = "[A-Za-z]{1,8}";
    let fragment = prop_oneof![
        // field:value with optional space after the colon and optional quotes
        (field, "[ ]{0,2}", word).prop_map(|(f, sp, w)| format!("{}:{}{}", f, sp, w)),
        (prop::sample::select(&["author", "first_author"][..]), word, word)
            .prop_map(|(f, a, b)| format!("{}:\"{} {}\"", f, a, b)),
        (prop::sample::select(&["author", "first_author"][..]), word, word)
            .prop_map(|(f, a, b)| format!("{}:{}, {}", f, a, b)),
        prop::sample::select(&["and", "or", "not", "AND", "OR", "NOT"][..]).prop_map(str::to_string),
        word.prop_map(|w| w.to_string()),
        (word).prop_map(|w| format!("citations(bibcode:{})", w)),
        Just("(".to_string()),
        Just(")".to_string()),
    ];
    prop::collection::vec(fragment, 1..5).prop_map(|frags| frags.join(" "))
}

proptest! {
    /// Totality on arbitrary input: normalize must never panic.
    ///
    /// BUG (found 2026-07-20): `remove_spaces_after_colons` computes
    /// `last_end = full_match.end() - 1`, but the final regex char `[^\s]`
    /// may be multi-byte, so `last_end` can fall inside a UTF-8 sequence and
    /// the subsequent slice panics. Minimal counterexample:
    /// `normalize("title: é")` → "byte index 8 is not a char boundary".
    #[test]
    #[ignore = "BUG: ads_normalizer::normalize panics on normalize(\"title: é\") — remove_spaces_after_colons slices mid-UTF-8 (full_match.end() - 1)"]
    fn ads_normalize_is_total(
        input in prop_oneof![
            ".*",
            // Field prefix + space + arbitrary (often multi-byte) value —
            // the shape that reliably reaches the buggy slice.
            "(title|abs|author|year|object): \\PC{1,6}",
        ]
    ) {
        let _ = normalize(&input);
    }

    /// Totality restricted to ASCII (holds today; guards the non-Unicode part
    /// of the contract while the boundary bug above is open).
    #[test]
    fn ads_normalize_is_total_ascii(input in "[ -~\t\r\n]*") {
        let _ = normalize(&input);
    }

    /// Idempotence: normalizing an already-normalized query changes nothing.
    #[test]
    fn ads_normalize_is_idempotent(input in ads_like_query()) {
        let once = normalize(&input);
        let twice = normalize(&once.corrected_query);
        prop_assert_eq!(
            &twice.corrected_query, &once.corrected_query,
            "input={:?} once={:?} twice-corrections={:?}",
            input, once.corrected_query, twice.corrections
        );
    }

    /// A second pass reports no corrections (stronger form of idempotence:
    /// the fixpoint is reached in one pass).
    #[test]
    fn ads_normalize_second_pass_reports_clean(input in ads_like_query()) {
        let once = normalize(&input);
        let twice = normalize(&once.corrected_query);
        prop_assert!(
            !twice.was_modified(),
            "second pass still corrects: input={:?} once={:?} corrections={:?}",
            input, once.corrected_query, twice.corrections
        );
    }

    /// was_modified ⇔ the query text or correction list changed.
    #[test]
    fn ads_normalize_unmodified_means_unchanged(input in ads_like_query()) {
        let r = normalize(&input);
        if !r.was_modified() {
            prop_assert_eq!(r.corrected_query, input);
        }
    }
}

// Minimized regression tripwire for the totality bug above.
#[test]
#[ignore = "BUG: ads_normalizer::normalize panics on normalize(\"title: é\") — byte index not a char boundary in remove_spaces_after_colons"]
fn ads_normalize_multibyte_value_tripwire() {
    let _ = normalize("title: é");
}
