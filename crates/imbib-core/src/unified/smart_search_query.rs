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
/// through (`{"native": …}`), anything else is `any any`.
pub fn query_of(text: &str) -> Query {
    let text = text.trim();
    if looks_native(text) {
        Query::Native {
            native: text.to_string(),
        }
    } else {
        Query::clause("any", "any", text)
    }
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
}
