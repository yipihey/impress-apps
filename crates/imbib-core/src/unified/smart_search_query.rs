//! A smart search's saved query (source convention S-D10): one `query_json`
//! field holding the search call — koine's `Query` plus the sources it is
//! asked of — instead of the older pair `query` (text) + `source_ids_json`.
//!
//! Rows are read both ways: a row with the older pair answers it directly
//! (the GUI still edits those two fields in place), and a row with only
//! `query_json` answers the text and the sources derived from it. New rows
//! write `query_json` alone.

use koine_sources::Query;
use serde_json::{json, Value};

/// Whether free text is a source-native query (ADS Lucene fields and
/// operators) rather than words.
pub fn looks_native(text: &str) -> bool {
    const FIELDS: &[&str] = &[
        "author:",
        "first_author:",
        "year:",
        "title:",
        "abs:",
        "bibstem:",
        "doi:",
        "arxiv:",
        "property:",
        "collection:",
        "citations(",
        "references(",
        "similar(",
        "trending(",
        "useful(",
        "bibcode:",
        "identifier:",
        "aff:",
        "object:",
    ];
    let lower = text.to_ascii_lowercase();
    FIELDS.iter().any(|f| lower.contains(f))
}

/// The canonical query of one search string: a native ADS string is passed
/// through (`{"native": …}`), an arXiv API string (`cat:astro-ph.CO AND
/// au:Abel`) is translated clause by clause ([`arxiv_query_of`]; the arXiv
/// adapter declares no `native`), anything else is `any any`.
pub fn query_of(text: &str) -> Query {
    let text = text.trim();
    if looks_native(text) {
        Query::Native {
            native: text.to_string(),
        }
    } else if looks_arxiv(text) {
        arxiv_query_of(text).query
    } else {
        Query::clause("any", "any", text)
    }
}

/// The sort a search string asks for by its shape: an arXiv category
/// query (`cat:…`) is a feed and wants the newest submissions first
/// (`year`, which the arXiv adapter sends as `sortBy=submittedDate`), as the
/// Swift `ArXivSource` sorted it; anything else keeps the source's order.
pub fn sort_of(text: &str) -> Option<&'static str> {
    (looks_arxiv(text) && text.to_ascii_lowercase().contains("cat:")).then_some("year")
}

// ── arXiv API syntax ────────────────────────────────────────────────────────

/// The arXiv API field prefixes (`search_query`), plus the spellings imbib's
/// own forms wrote (`category:`, `author:`, …): the Swift `ArXivSource`
/// accepted both.
const ARXIV_FIELDS: &[&str] = &[
    "all:",
    "ti:",
    "au:",
    "abs:",
    "cat:",
    "id:",
    "co:",
    "jr:",
    "rn:",
    "submitteddate:",
    "lastupdateddate:",
    "category:",
    "arxiv:",
];

/// Whether free text is written in the arXiv API's query syntax.
pub fn looks_arxiv(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    ARXIV_FIELDS.iter().any(|f| {
        lower
            .match_indices(f)
            .any(|(i, _)| i == 0 || !lower.as_bytes()[i - 1].is_ascii_alphanumeric())
    }) || lower.contains(" andnot ")
}

/// An arXiv string translated: the query the adapter can run, and the
/// clauses it cannot (`co:`, `jr:`, `rn:`, a field it has no index for),
/// named so the caller can log what the feed no longer filters on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArxivTranslation {
    pub query: Query,
    pub dropped: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Tok {
    Open,
    Close,
    And,
    Or,
    AndNot,
    Term(String),
}

fn arxiv_tokens(text: &str) -> Vec<Tok> {
    let mut out = Vec::new();
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c.is_whitespace() {
            i += 1;
            continue;
        }
        if c == '(' {
            out.push(Tok::Open);
            i += 1;
            continue;
        }
        if c == ')' {
            out.push(Tok::Close);
            i += 1;
            continue;
        }
        // A term runs to the next whitespace or paren, except inside quotes
        // or a `[… TO …]` date range, which may contain spaces.
        let mut term = String::new();
        let mut quoted = false;
        let mut bracket = false;
        while i < chars.len() {
            let c = chars[i];
            if c == '"' {
                quoted = !quoted;
            } else if c == '[' {
                bracket = true;
            } else if c == ']' {
                bracket = false;
            }
            if !quoted && !bracket && (c.is_whitespace() || c == '(' || c == ')') {
                break;
            }
            term.push(c);
            i += 1;
        }
        match term.as_str() {
            "AND" => out.push(Tok::And),
            "OR" => out.push(Tok::Or),
            "ANDNOT" => out.push(Tok::AndNot),
            _ => out.push(Tok::Term(term)),
        }
    }
    out
}

/// One `field:value` (or bare) term as a clause; `None` with the reason
/// when the adapter has no index for it.
fn arxiv_clause(term: &str) -> Result<Query, String> {
    // The long spellings imbib's forms also wrote (the Swift source mapped
    // `author:` → `au:` and so on); they are not detection cues, since ADS
    // spells its own fields the same way.
    const ALIASES: &[(&str, &str)] = &[
        ("author", "au"),
        ("title", "ti"),
        ("abstract", "abs"),
        ("category", "cat"),
        ("arxiv", "id"),
        ("comment", "co"),
        ("journal", "jr"),
        ("report", "rn"),
    ];
    let (field, value) = match term.split_once(':') {
        Some((f, v)) => {
            let f = f.to_ascii_lowercase();
            let f = ALIASES
                .iter()
                .find(|(long, _)| *long == f)
                .map(|(_, short)| short.to_string())
                .unwrap_or(f);
            if ARXIV_FIELDS.contains(&format!("{f}:").as_str()) {
                (f, v)
            } else {
                ("all".to_string(), term)
            }
        }
        None => ("all".to_string(), term),
    };
    let phrase = value.starts_with('"') && value.ends_with('"') && value.len() >= 2;
    let value = value.trim_matches('"').trim();
    if value.is_empty() {
        return Err(format!("{term}: empty value"));
    }
    let text_relation = if phrase { "adj" } else { "any" };
    Ok(match field.as_str() {
        "all" => Query::clause("any", text_relation, value),
        "ti" => Query::clause("title", text_relation, value),
        "abs" => Query::clause("abstract", text_relation, value),
        "au" => Query::clause("author", text_relation, value),
        "cat" | "category" => Query::clause("subject", "=", value),
        "id" | "arxiv" => Query::clause("arxiv", "=", value),
        "submitteddate" | "lastupdateddate" => {
            // `[YYYYMMDDHHMM TO YYYYMMDDHHMM]` (the API wants `+TO+`, which
            // the Swift source wrote and the adapter re-spells) → the years.
            let inner = value.trim_matches(|c| c == '[' || c == ']');
            let years: Vec<&str> = inner
                .split(|c: char| c.is_whitespace() || c == '+')
                .filter(|s| !s.is_empty() && *s != "TO")
                .filter_map(|s| s.get(0..4))
                .collect();
            match years.as_slice() {
                [a, b]
                    if a.chars().all(|c| c.is_ascii_digit())
                        && b.chars().all(|c| c.is_ascii_digit()) =>
                {
                    Query::clause("year", "within", format!("{a} {b}"))
                }
                _ => return Err(format!("{term}: not a date range")),
            }
        }
        other => {
            return Err(format!(
                "{other}: arXiv's `{other}` has no index in the source convention"
            ))
        }
    })
}

/// Translate an arXiv API query string into koine's query tree: `AND`,
/// `OR` and `ANDNOT` (left-associative, parentheses honoured), `all:` →
/// `any`, `ti:` → `title`, `abs:` → `abstract`, `au:` → `author`, `cat:` →
/// `subject =`, `id:` → `arxiv =`, a `submittedDate:[… TO …]` range → `year
/// within`; a quoted value is a phrase (`adj`). Clauses the adapter has no
/// index for (`co:`, `jr:`, `rn:`) are dropped and named in `dropped`, never
/// silently sent as words.
pub fn arxiv_query_of(text: &str) -> ArxivTranslation {
    let tokens = arxiv_tokens(text);
    let mut dropped = Vec::new();
    let mut pos = 0;
    let query = arxiv_expr(&tokens, &mut pos, &mut dropped);
    ArxivTranslation {
        query: query.unwrap_or_else(|| Query::clause("any", "any", text.trim())),
        dropped,
    }
}

fn arxiv_operand(tokens: &[Tok], pos: &mut usize, dropped: &mut Vec<String>) -> Option<Query> {
    match tokens.get(*pos)? {
        Tok::Open => {
            *pos += 1;
            let inner = arxiv_expr(tokens, pos, dropped);
            if matches!(tokens.get(*pos), Some(Tok::Close)) {
                *pos += 1;
            }
            inner
        }
        Tok::Term(t) => {
            *pos += 1;
            match arxiv_clause(t) {
                Ok(q) => Some(q),
                Err(why) => {
                    dropped.push(why);
                    None
                }
            }
        }
        Tok::Close => None,
        Tok::And | Tok::Or | Tok::AndNot => {
            // A dangling operator: skip it.
            *pos += 1;
            arxiv_operand(tokens, pos, dropped)
        }
    }
}

fn arxiv_expr(tokens: &[Tok], pos: &mut usize, dropped: &mut Vec<String>) -> Option<Query> {
    let mut acc = arxiv_operand(tokens, pos, dropped);
    while let Some(tok) = tokens.get(*pos) {
        let op = match tok {
            Tok::And => Tok::And,
            Tok::Or => Tok::Or,
            Tok::AndNot => Tok::AndNot,
            Tok::Close => break,
            // Two operands with no operator between them: the API reads it
            // as AND.
            Tok::Open | Tok::Term(_) => Tok::And,
        };
        if op != Tok::And || matches!(tok, Tok::And) {
            *pos += 1;
        }
        let rhs = arxiv_operand(tokens, pos, dropped);
        acc = match (acc, rhs) {
            (Some(l), Some(r)) => Some(match op {
                Tok::Or => Query::Or { or: vec![l, r] },
                Tok::AndNot => Query::And {
                    and: vec![l, Query::Not { not: Box::new(r) }],
                },
                _ => Query::And { and: vec![l, r] },
            }),
            (Some(l), None) => Some(l),
            (None, Some(r)) if op != Tok::AndNot => Some(r),
            (None, _) => None,
        };
    }
    acc
}

/// The saved form: `{"query": <Query>, "sources": [...]}`.
pub fn saved(text: &str, sources: &[String]) -> Value {
    json!({ "query": query_of(text), "sources": sources })
}

/// The text a saved query stands for: a native string verbatim, a single
/// clause's term, or the JSON itself when the query is a tree the text form
/// cannot spell.
pub fn text_of(query: &Query) -> String {
    match query {
        Query::Native { native } => native.clone(),
        Query::Clause { term, .. } => term.clone(),
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

/// Read a saved query back: the text and the sources.
pub fn read(saved: &str) -> Option<(String, Vec<String>)> {
    let value: Value = serde_json::from_str(saved).ok()?;
    let query: Query = serde_json::from_value(value.get("query")?.clone()).ok()?;
    let sources = value
        .get("sources")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    Some((text_of(&query), sources))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_and_a_native_string_round_trip_with_their_sources() {
        let sources = vec!["ads".to_string(), "arxiv".to_string()];
        let saved_words = saved("dark matter halos", &sources).to_string();
        assert_eq!(
            read(&saved_words),
            Some(("dark matter halos".into(), sources.clone()))
        );
        assert!(saved_words.contains("\"index\":\"any\""));
        let saved_native = saved("author:\"Abel, T\" year:2020-2024", &[]).to_string();
        assert!(saved_native.contains("\"native\""));
        assert_eq!(
            read(&saved_native),
            Some(("author:\"Abel, T\" year:2020-2024".into(), vec![]))
        );
        assert_eq!(read("not json"), None);
    }

    #[test]
    fn an_arxiv_category_feed_becomes_subject_clauses_sorted_by_year() {
        let t = arxiv_query_of("cat:astro-ph.CO OR cat:astro-ph.GA");
        assert_eq!(
            t.query,
            Query::Or {
                or: vec![
                    Query::clause("subject", "=", "astro-ph.CO"),
                    Query::clause("subject", "=", "astro-ph.GA"),
                ]
            }
        );
        assert!(t.dropped.is_empty());
        assert_eq!(sort_of("cat:astro-ph.CO"), Some("year"));
        assert_eq!(sort_of("au:Abel"), None);
        assert_eq!(sort_of("dark matter"), None);
        assert_eq!(
            query_of("cat:astro-ph.CO"),
            Query::clause("subject", "=", "astro-ph.CO")
        );
    }

    #[test]
    fn an_author_category_query_with_a_date_window_and_a_phrase() {
        let t = arxiv_query_of(
            "(au:\"Abel, Tom\" AND (cat:astro-ph.CO OR cat:astro-ph.GA)) AND submittedDate:[202507010000+TO+202510010000]",
        );
        assert_eq!(
            t.query,
            Query::And {
                and: vec![
                    Query::And {
                        and: vec![
                            Query::clause("author", "adj", "Abel, Tom"),
                            Query::Or {
                                or: vec![
                                    Query::clause("subject", "=", "astro-ph.CO"),
                                    Query::clause("subject", "=", "astro-ph.GA"),
                                ]
                            },
                        ]
                    },
                    Query::clause("year", "within", "2025 2025"),
                ]
            }
        );
        assert!(t.dropped.is_empty());
    }

    #[test]
    fn andnot_is_a_not_beside_its_clause_and_unknown_fields_are_named_not_sent() {
        let t = arxiv_query_of("ti:\"first stars\" ANDNOT cat:hep-ph AND jr:ApJ");
        // `jr:` is dropped, so nothing joins the AND: the left side stands.
        assert_eq!(
            t.query,
            Query::And {
                and: vec![
                    Query::clause("title", "adj", "first stars"),
                    Query::Not {
                        not: Box::new(Query::clause("subject", "=", "hep-ph"))
                    },
                ]
            }
        );
        assert_eq!(t.dropped.len(), 1);
        assert!(t.dropped[0].starts_with("jr:"), "{:?}", t.dropped);
        // The Swift source's own prefixes still read.
        assert_eq!(
            arxiv_query_of("author:Abel").query,
            Query::clause("author", "any", "Abel")
        );
        assert_eq!(
            arxiv_query_of("id:2101.00001").query,
            Query::clause("arxiv", "=", "2101.00001")
        );
        assert!(looks_arxiv("all:dark AND cat:astro-ph.CO"));
        assert!(!looks_arxiv("overall:something"));
        assert!(!looks_arxiv("dark matter halos"));
        assert!(!looks_arxiv("author:\"Abel, T\" year:2020"));
    }
}
