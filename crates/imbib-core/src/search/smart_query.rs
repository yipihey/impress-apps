//! Smart-search syntax parser.
//!
//! Port of the parsing half of Swift `LocalFilterService.parse(_:)`
//! (`apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Search/LocalFilterService.swift`).
//! That file is named "LocalFilterService" but the *parser* portion lives here
//! because it produces an AST the rest of impress (TUI, CLI, MCP) can target
//! without dragging in the row-data type. Evaluation against publications
//! lives in [`crate::search::local_filter`].
//!
//! Grammar (mirrors `LocalFilterService.parse`):
//!
//! ```text
//! token := flagToken | tagToken | fieldToken | yearToken | readToken | negatedTextToken | textToken
//!
//! flagToken    := ("flag:" | "f:")  flagValue
//!               | ("-flag:" | "-f:") "*"
//!
//! tagToken     := ("tags:" | "t:")  tagPattern
//!               | ("-tags:" | "-t:") tagPath
//!
//! fieldToken   := fieldPrefix textValue
//!
//! yearToken    := ("year:" | "y:") yearValue
//!
//! readToken    := "read" | "unread"
//!
//! negatedTextToken := "-" textValue        # must not start "-flag:" "-tags:" "-f:" "-t:"
//!
//! textToken    := <anything else>          # bare phrase; quoted strings preserve internal spaces
//!
//! flagValue    := "*" | colorName | shorthand
//!   shorthand  := color [ style [ length ] ]   # each position can be '*'
//!
//! tagPattern   := tagPath ( "+" tagPath )+    # AND
//!               | tagPath ( "|" tagPath )+    # OR
//!               | tagPath                     # single
//!
//! yearValue    := digits                       # exact
//!               | digits "-" digits            # range
//!               | (">" | ">=") digits          # after / range-up
//!               | ("<" | "<=") digits          # before / range-down
//!
//! fieldPrefix  := "title:" | "ti:" | "t:"
//!               | "author:" | "au:" | "a:"
//!               | "abstract:" | "ab:"
//!               | "venue:" | "ve:" | "b:"
//! ```
//!
//! Quoting: `"..."` preserves internal whitespace (single token). The Swift
//! tokenizer doesn't honor escaped quotes — neither does this port.
//!
//! NB: the `t:` and `b:` prefixes are *ambiguous* with the tags/flag
//! shorthand. We mirror the Swift dispatch order in `LocalFilterService.parse`:
//! flag prefixes are tried first, then tag prefixes, then field prefixes.

use std::fmt;

/// Parsed smart search query — AST consumed by `crate::search::local_filter`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SmartQuery {
    pub text_terms: Vec<String>,
    pub negated_text_terms: Vec<String>,
    pub field_terms: Vec<FieldTerm>,
    pub year_filter: Option<YearFilter>,
    /// At most one flag query — multiple `flag:` tokens overwrite earlier
    /// ones, matching Swift's `filter.flagQuery = fq` assignment.
    pub flag_query: Option<FlagQuery>,
    pub tag_queries: Vec<TagQuery>,
    pub read_state: Option<ReadState>,
}

impl SmartQuery {
    pub fn is_empty(&self) -> bool {
        self.text_terms.is_empty()
            && self.negated_text_terms.is_empty()
            && self.field_terms.is_empty()
            && self.year_filter.is_none()
            && self.flag_query.is_none()
            && self.tag_queries.is_empty()
            && self.read_state.is_none()
    }
}

/// Searchable fields for field-qualified terms.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SearchField {
    Title,
    Author,
    Abstract,
    Venue,
}

impl fmt::Display for SearchField {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            SearchField::Title => "title",
            SearchField::Author => "author",
            SearchField::Abstract => "abstract",
            SearchField::Venue => "venue",
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FieldTerm {
    pub field: SearchField,
    pub term: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum YearFilter {
    Exact(i32),
    Range(i32, i32),
    /// `> y`  → strictly after `y`. (Swift: `.after`.)
    After(i32),
    /// `< y`  → strictly before `y`. (Swift: `.before`.)
    Before(i32),
}

impl YearFilter {
    /// Matches Swift `YearFilter.matches(_:)`.
    pub fn matches(&self, year: Option<i32>) -> bool {
        let Some(y) = year else { return false };
        match self {
            YearFilter::Exact(target) => y == *target,
            YearFilter::Range(lo, hi) => y >= *lo && y <= *hi,
            YearFilter::After(target) => y > *target,
            YearFilter::Before(target) => y < *target,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FlagColor {
    Red,
    Amber,
    Blue,
    Green,
}

impl FlagColor {
    fn from_name(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "red" => Some(FlagColor::Red),
            "amber" | "yellow" => Some(FlagColor::Amber),
            "blue" => Some(FlagColor::Blue),
            "green" => Some(FlagColor::Green),
            _ => None,
        }
    }

    fn from_shortcut(c: char) -> Option<Self> {
        match c.to_ascii_lowercase() {
            'r' => Some(FlagColor::Red),
            'a' => Some(FlagColor::Amber),
            'b' => Some(FlagColor::Blue),
            'g' => Some(FlagColor::Green),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FlagStyle {
    Solid,
    Dashed,
    Dotted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FlagLength {
    Full,
    Half,
    Quarter,
}

impl FlagLength {
    fn from_shortcut(c: char) -> Option<Self> {
        match c.to_ascii_lowercase() {
            'f' => Some(FlagLength::Full),
            'h' => Some(FlagLength::Half),
            'q' => Some(FlagLength::Quarter),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FlagQuery {
    /// `flag:r-h`, `flag:*-*`, `flag:red`: nil components = wildcards.
    Pattern {
        color: Option<FlagColor>,
        style: Option<FlagStyle>,
        length: Option<FlagLength>,
    },
    /// `flag:*` — any flag present.
    HasAny,
    /// `-flag:*` — no flag.
    HasNone,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TagQuery {
    /// `tags:methods/hydro` — match prefix (case-insensitive).
    Has(String),
    /// `-tags:methods`
    HasNot(String),
    /// `tags:a+b` — AND
    HasAll(Vec<String>),
    /// `tags:a|b` — OR
    HasAny(Vec<String>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadState {
    Read,
    Unread,
}

// --- parser ----------------------------------------------------------------

/// Parse a smart-search expression. Always returns a `SmartQuery` (invalid
/// pieces fall back to bare text terms, matching the Swift behavior).
pub fn parse(input: &str) -> SmartQuery {
    let mut q = SmartQuery::default();

    for token in tokenize(input) {
        if try_parse_token(&token, &mut q) {
            continue;
        }
        // Negated text: `-foo` (but only if it didn't match a `-flag:` or
        // `-tags:` token above).
        if token.starts_with('-') && token.len() > 1 {
            q.negated_text_terms.push(token[1..].to_string());
            continue;
        }
        // Fall through: text term.
        q.text_terms.push(token);
    }

    q
}

fn try_parse_token(token: &str, q: &mut SmartQuery) -> bool {
    // Flag shortcuts.
    if let Some(rest) = strip_prefix_ci(token, "f:") {
        if let Some(fq) = parse_flag_value(rest, /*negated=*/ false) {
            q.flag_query = Some(fq);
            return true;
        }
    }
    if let Some(rest) = strip_prefix_ci(token, "-f:") {
        if let Some(fq) = parse_flag_value(rest, /*negated=*/ true) {
            q.flag_query = Some(fq);
            return true;
        }
    }
    if let Some(rest) = strip_prefix_ci(token, "flag:") {
        if let Some(fq) = parse_flag_value(rest, false) {
            q.flag_query = Some(fq);
            return true;
        }
    }
    if let Some(rest) = strip_prefix_ci(token, "-flag:") {
        if let Some(fq) = parse_flag_value(rest, true) {
            q.flag_query = Some(fq);
            return true;
        }
    }

    // Tag shortcuts.
    if let Some(rest) = strip_prefix_ci(token, "t:") {
        if let Some(tq) = parse_tag_value(rest, false) {
            q.tag_queries.push(tq);
            return true;
        }
    }
    if let Some(rest) = strip_prefix_ci(token, "-t:") {
        if let Some(tq) = parse_tag_value(rest, true) {
            q.tag_queries.push(tq);
            return true;
        }
    }
    if let Some(rest) = strip_prefix_ci(token, "tags:") {
        if let Some(tq) = parse_tag_value(rest, false) {
            q.tag_queries.push(tq);
            return true;
        }
    }
    if let Some(rest) = strip_prefix_ci(token, "-tags:") {
        if let Some(tq) = parse_tag_value(rest, true) {
            q.tag_queries.push(tq);
            return true;
        }
    }

    // Field-qualified text terms.
    if let Some(ft) = parse_field_term(token) {
        q.field_terms.push(ft);
        return true;
    }

    // Year filter.
    if let Some(value) = strip_prefix_ci(token, "year:") {
        if let Some(yf) = parse_year_value(value) {
            q.year_filter = Some(yf);
            return true;
        }
    }
    if let Some(value) = strip_prefix_ci(token, "y:") {
        if let Some(yf) = parse_year_value(value) {
            q.year_filter = Some(yf);
            return true;
        }
    }

    // Read state.
    match token.to_ascii_lowercase().as_str() {
        "unread" => {
            q.read_state = Some(ReadState::Unread);
            return true;
        }
        "read" => {
            q.read_state = Some(ReadState::Read);
            return true;
        }
        _ => {}
    }

    false
}

/// Case-insensitive prefix strip. Returns `Some(rest)` if the prefix matched.
fn strip_prefix_ci<'a>(token: &'a str, prefix: &str) -> Option<&'a str> {
    let plen = prefix.len();
    // All prefixes used here are ASCII, so a match requires the first `plen`
    // bytes of `token` to be ASCII too — if `plen` isn't a char boundary the
    // prefix cannot match (and slicing there would panic on multi-byte input).
    if token.len() < plen || !token.is_char_boundary(plen) {
        return None;
    }
    if token[..plen].eq_ignore_ascii_case(prefix) {
        Some(&token[plen..])
    } else {
        None
    }
}

fn parse_field_term(token: &str) -> Option<FieldTerm> {
    // Order matters: longer prefixes first to avoid `t:` swallowing `title:`.
    // (Swift uses the same order: title:, author:, abstract:, venue:, then
    // ti:, au:, ab:, ve:, then a:, t:, b:.)
    let prefixes: &[(&str, SearchField)] = &[
        ("title:", SearchField::Title),
        ("author:", SearchField::Author),
        ("abstract:", SearchField::Abstract),
        ("venue:", SearchField::Venue),
        ("ti:", SearchField::Title),
        ("au:", SearchField::Author),
        ("ab:", SearchField::Abstract),
        ("ve:", SearchField::Venue),
        ("a:", SearchField::Author),
        ("t:", SearchField::Title),
        ("b:", SearchField::Venue),
    ];
    for (prefix, field) in prefixes {
        if let Some(rest) = strip_prefix_ci(token, prefix) {
            if !rest.is_empty() {
                return Some(FieldTerm {
                    field: *field,
                    term: rest.to_string(),
                });
            }
        }
    }
    None
}

fn parse_year_value(value: &str) -> Option<YearFilter> {
    // Range: 2020-2024 (note: only if both sides parse; matches Swift's behavior
    // that requires a non-leading dash).
    if let Some(dash_idx) = value.find('-') {
        if dash_idx > 0 {
            let (l, r) = (&value[..dash_idx], &value[dash_idx + 1..]);
            if let (Ok(s), Ok(e)) = (l.parse::<i32>(), r.parse::<i32>()) {
                if s <= e {
                    return Some(YearFilter::Range(s, e));
                }
            }
            return None;
        }
    }
    if let Some(rest) = value.strip_prefix(">=") {
        if let Ok(y) = rest.parse::<i32>() {
            return Some(YearFilter::Range(y, 9999));
        }
    }
    if let Some(rest) = value.strip_prefix('>') {
        if let Ok(y) = rest.parse::<i32>() {
            return Some(YearFilter::After(y));
        }
    }
    if let Some(rest) = value.strip_prefix("<=") {
        if let Ok(y) = rest.parse::<i32>() {
            return Some(YearFilter::Range(0, y));
        }
    }
    if let Some(rest) = value.strip_prefix('<') {
        if let Ok(y) = rest.parse::<i32>() {
            return Some(YearFilter::Before(y));
        }
    }
    if let Ok(y) = value.parse::<i32>() {
        return Some(YearFilter::Exact(y));
    }
    None
}

fn parse_flag_value(value: &str, negated: bool) -> Option<FlagQuery> {
    if negated {
        return if value == "*" {
            Some(FlagQuery::HasNone)
        } else {
            None
        };
    }

    if value.is_empty() {
        return None;
    }
    if value == "*" {
        return Some(FlagQuery::HasAny);
    }
    // Full color name?
    if let Some(color) = FlagColor::from_name(value) {
        return Some(FlagQuery::Pattern {
            color: Some(color),
            style: None,
            length: None,
        });
    }

    // Positional shorthand: color[style][length], '*' = wildcard.
    let chars: Vec<char> = value.to_ascii_lowercase().chars().collect();
    // Position 1: color.
    let color = if chars[0] == '*' {
        None
    } else {
        match FlagColor::from_shortcut(chars[0]) {
            Some(c) => Some(c),
            None => return None,
        }
    };

    if chars.len() == 1 {
        return Some(FlagQuery::Pattern {
            color,
            style: None,
            length: None,
        });
    }

    // Position 2: style or length.
    let style: Option<FlagStyle> = match chars[1] {
        '*' => None,
        '-' => Some(FlagStyle::Dashed),
        '.' => Some(FlagStyle::Dotted),
        's' => Some(FlagStyle::Solid),
        other => {
            // Maybe it's actually a length char (e.g. "rh" = red, any style, half).
            if let Some(l) = FlagLength::from_shortcut(other) {
                return Some(FlagQuery::Pattern {
                    color,
                    style: None,
                    length: Some(l),
                });
            }
            return None;
        }
    };

    if chars.len() == 2 {
        return Some(FlagQuery::Pattern {
            color,
            style,
            length: None,
        });
    }

    // Position 3: length.
    let length = if chars[2] == '*' {
        None
    } else {
        FlagLength::from_shortcut(chars[2])
    };

    Some(FlagQuery::Pattern {
        color,
        style,
        length,
    })
}

fn parse_tag_value(value: &str, negated: bool) -> Option<TagQuery> {
    if value.is_empty() {
        return None;
    }
    if negated {
        return Some(TagQuery::HasNot(value.to_string()));
    }
    // AND: tags:a+b — only if multiple components present.
    if value.contains('+') {
        let parts: Vec<String> = value
            .split('+')
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
            .collect();
        if parts.len() > 1 {
            return Some(TagQuery::HasAll(parts));
        }
    }
    // OR: tags:a|b
    if value.contains('|') {
        let parts: Vec<String> = value
            .split('|')
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
            .collect();
        if parts.len() > 1 {
            return Some(TagQuery::HasAny(parts));
        }
    }
    Some(TagQuery::Has(value.to_string()))
}

/// Whitespace-respecting tokenizer with `"..."` quoting (matches
/// `LocalFilterService.tokenize`).
fn tokenize(input: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;

    for c in input.chars() {
        match c {
            '"' => {
                in_quotes = !in_quotes;
                if !in_quotes && !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            ' ' | '\t' | '\n' | '\r' if !in_quotes => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            other => current.push(other),
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_yields_empty_query() {
        let q = parse("");
        assert!(q.is_empty());
        let q = parse("   \t  ");
        assert!(q.is_empty());
    }

    #[test]
    fn bare_text_term() {
        let q = parse("galaxy");
        assert_eq!(q.text_terms, vec!["galaxy"]);
        assert!(!q.is_empty());
    }

    #[test]
    fn quoted_phrase_preserves_spaces() {
        let q = parse("\"exact phrase\" galaxy");
        assert_eq!(q.text_terms, vec!["exact phrase", "galaxy"]);
    }

    #[test]
    fn negated_text_term() {
        let q = parse("-galaxy");
        assert_eq!(q.negated_text_terms, vec!["galaxy"]);
    }

    #[test]
    fn year_exact() {
        let q = parse("year:2020");
        assert_eq!(q.year_filter, Some(YearFilter::Exact(2020)));
    }

    #[test]
    fn year_range() {
        let q = parse("year:2020-2024");
        assert_eq!(q.year_filter, Some(YearFilter::Range(2020, 2024)));
    }

    #[test]
    fn year_after() {
        let q = parse("year:>2020");
        assert_eq!(q.year_filter, Some(YearFilter::After(2020)));
    }

    #[test]
    fn year_after_or_equal_becomes_range() {
        let q = parse("year:>=2020");
        assert_eq!(q.year_filter, Some(YearFilter::Range(2020, 9999)));
    }

    #[test]
    fn year_before() {
        let q = parse("year:<2020");
        assert_eq!(q.year_filter, Some(YearFilter::Before(2020)));
    }

    #[test]
    fn year_short_prefix() {
        let q = parse("y:2020");
        assert_eq!(q.year_filter, Some(YearFilter::Exact(2020)));
    }

    #[test]
    fn invalid_year_falls_back_to_text() {
        // Swift: invalid year value drops to text term.
        let q = parse("year:abc");
        assert_eq!(q.year_filter, None);
        assert_eq!(q.text_terms, vec!["year:abc"]);
    }

    #[test]
    fn title_field_term() {
        let q = parse("title:galaxy");
        assert_eq!(q.field_terms.len(), 1);
        assert_eq!(q.field_terms[0].field, SearchField::Title);
        assert_eq!(q.field_terms[0].term, "galaxy");
    }

    #[test]
    fn title_with_quoted_value() {
        // The tokenizer treats `title:"exact phrase"` as a single token
        // (`title:exact phrase`) because the quotes only enter/exit quoting
        // mode without splitting. The field-term parser then sees the field
        // prefix and takes the rest as the value, preserving spaces.
        // This is friendlier than Swift's behavior (which would have split
        // on whitespace inside the field value).
        let q = parse("title:\"exact phrase\"");
        assert_eq!(q.field_terms.len(), 1);
        assert_eq!(q.field_terms[0].field, SearchField::Title);
        assert_eq!(q.field_terms[0].term, "exact phrase");
    }

    #[test]
    fn author_short_prefix() {
        let q = parse("au:smith");
        assert_eq!(q.field_terms.len(), 1);
        assert_eq!(q.field_terms[0].field, SearchField::Author);
        assert_eq!(q.field_terms[0].term, "smith");
    }

    #[test]
    fn t_prefix_routes_to_title_field() {
        // `t:` is ambiguous with tag shortcut. Per Swift dispatch order, `t:`
        // alone matches the tag prefix code path FIRST, so it goes there with
        // value "galaxy" → Has("galaxy").
        let q = parse("t:galaxy");
        assert_eq!(q.tag_queries, vec![TagQuery::Has("galaxy".to_string())]);
        assert!(q.field_terms.is_empty());
    }

    #[test]
    fn flag_full_color_name() {
        let q = parse("flag:red");
        assert_eq!(
            q.flag_query,
            Some(FlagQuery::Pattern {
                color: Some(FlagColor::Red),
                style: None,
                length: None,
            })
        );
    }

    #[test]
    fn flag_shorthand_color_only() {
        let q = parse("flag:r");
        assert_eq!(
            q.flag_query,
            Some(FlagQuery::Pattern {
                color: Some(FlagColor::Red),
                style: None,
                length: None,
            })
        );
    }

    #[test]
    fn flag_full_shorthand() {
        let q = parse("flag:r-h");
        assert_eq!(
            q.flag_query,
            Some(FlagQuery::Pattern {
                color: Some(FlagColor::Red),
                style: Some(FlagStyle::Dashed),
                length: Some(FlagLength::Half),
            })
        );
    }

    #[test]
    fn flag_wildcards() {
        let q = parse("flag:*-*");
        assert_eq!(
            q.flag_query,
            Some(FlagQuery::Pattern {
                color: None,
                style: Some(FlagStyle::Dashed),
                length: None,
            })
        );
    }

    #[test]
    fn flag_any() {
        let q = parse("flag:*");
        assert_eq!(q.flag_query, Some(FlagQuery::HasAny));
    }

    #[test]
    fn flag_none() {
        let q = parse("-flag:*");
        assert_eq!(q.flag_query, Some(FlagQuery::HasNone));
    }

    #[test]
    fn flag_shorthand_two_chars_color_length() {
        // "rh" = red, any style, half.
        let q = parse("flag:rh");
        assert_eq!(
            q.flag_query,
            Some(FlagQuery::Pattern {
                color: Some(FlagColor::Red),
                style: None,
                length: Some(FlagLength::Half),
            })
        );
    }

    #[test]
    fn flag_invalid_color_falls_back_to_text() {
        let q = parse("flag:zzz");
        assert_eq!(q.flag_query, None);
        assert_eq!(q.text_terms, vec!["flag:zzz"]);
    }

    #[test]
    fn flag_short_prefix() {
        let q = parse("f:r");
        assert_eq!(
            q.flag_query,
            Some(FlagQuery::Pattern {
                color: Some(FlagColor::Red),
                style: None,
                length: None,
            })
        );
    }

    #[test]
    fn tag_has() {
        let q = parse("tags:methods/hydro");
        assert_eq!(
            q.tag_queries,
            vec![TagQuery::Has("methods/hydro".to_string())]
        );
    }

    #[test]
    fn tag_has_not() {
        let q = parse("-tags:methods");
        assert_eq!(q.tag_queries, vec![TagQuery::HasNot("methods".to_string())]);
    }

    #[test]
    fn tag_has_all() {
        let q = parse("tags:a+b+c");
        assert_eq!(
            q.tag_queries,
            vec![TagQuery::HasAll(vec![
                "a".to_string(),
                "b".to_string(),
                "c".to_string()
            ])]
        );
    }

    #[test]
    fn tag_has_any() {
        let q = parse("tags:a|b");
        assert_eq!(
            q.tag_queries,
            vec![TagQuery::HasAny(vec!["a".to_string(), "b".to_string()])]
        );
    }

    #[test]
    fn read_state_unread() {
        let q = parse("unread");
        assert_eq!(q.read_state, Some(ReadState::Unread));
    }

    #[test]
    fn read_state_read() {
        let q = parse("read");
        assert_eq!(q.read_state, Some(ReadState::Read));
    }

    #[test]
    fn combined_filter_example_from_doc() {
        let q = parse("flag:red tags:methods/hydro year:>2020 title:galaxy");
        assert_eq!(
            q.flag_query,
            Some(FlagQuery::Pattern {
                color: Some(FlagColor::Red),
                style: None,
                length: None,
            })
        );
        assert_eq!(
            q.tag_queries,
            vec![TagQuery::Has("methods/hydro".to_string())]
        );
        assert_eq!(q.year_filter, Some(YearFilter::After(2020)));
        assert_eq!(q.field_terms.len(), 1);
        assert_eq!(q.field_terms[0].field, SearchField::Title);
        assert_eq!(q.field_terms[0].term, "galaxy");
    }

    #[test]
    fn combined_with_quoted_phrase_and_negation() {
        let q = parse("flag:red \"exact phrase\" -excluded unread");
        assert!(q.flag_query.is_some());
        assert_eq!(q.text_terms, vec!["exact phrase"]);
        assert_eq!(q.negated_text_terms, vec!["excluded"]);
        assert_eq!(q.read_state, Some(ReadState::Unread));
    }

    #[test]
    fn last_flag_token_wins() {
        let q = parse("flag:red flag:blue");
        assert_eq!(
            q.flag_query,
            Some(FlagQuery::Pattern {
                color: Some(FlagColor::Blue),
                style: None,
                length: None,
            })
        );
    }

    #[test]
    fn year_match_helper() {
        let yf = YearFilter::After(2020);
        assert!(yf.matches(Some(2021)));
        assert!(!yf.matches(Some(2020)));
        assert!(!yf.matches(None));

        let yf = YearFilter::Range(2020, 2024);
        assert!(yf.matches(Some(2020)));
        assert!(yf.matches(Some(2024)));
        assert!(!yf.matches(Some(2025)));

        let yf = YearFilter::Before(2020);
        assert!(yf.matches(Some(2019)));
        assert!(!yf.matches(Some(2020)));

        let yf = YearFilter::Exact(2020);
        assert!(yf.matches(Some(2020)));
        assert!(!yf.matches(Some(2019)));
    }

    #[test]
    fn invalid_year_range_falls_back_to_text() {
        // 2024-2020 → invalid (start > end).
        let q = parse("year:2024-2020");
        assert_eq!(q.year_filter, None);
        assert_eq!(q.text_terms, vec!["year:2024-2020"]);
    }

    #[test]
    fn multiple_tag_queries_accumulate() {
        let q = parse("tags:methods tags:topic/galaxies");
        assert_eq!(q.tag_queries.len(), 2);
        assert_eq!(q.tag_queries[0], TagQuery::Has("methods".to_string()));
        assert_eq!(
            q.tag_queries[1],
            TagQuery::Has("topic/galaxies".to_string())
        );
    }
}
