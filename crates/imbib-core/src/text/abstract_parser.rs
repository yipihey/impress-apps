//! Abstracts → renderable segments (text vs. inline vs. display math).
//!
//! Port of `PublicationManagerCore/RichText/AbstractParser.swift` (687 L),
//! pinned by `test_fixtures/golden/abstract_parse.json` (56 cases captured from
//! Swift before this existed).
//!
//! The pipeline, in order — each step feeds the next, and the order is
//! load-bearing (decoding entities before splitting on `$` means `&#36;` never
//! becomes a math delimiter; converting MathML first means its `$…$` wrappers
//! are seen by the segmenter):
//!
//! 1. [`normalize_arxiv_escaping`] — arXiv/JSON double-escaping (`\\beta` → `\beta`)
//! 2. [`mathml_to_latex`] — `<inline-formula>` / `<mml:math>` → `$…$`
//! 3. [`decode_html_entities`] — 41 named entities + numeric
//! 4. [`convert_html_sub_sup`] — `<sub>`/`<sup>` → `_`/`^`
//! 5. [`parse_segments`] — split on `$$…$$`, `\[…\]`, `$…$`, `\(…\)`
//!
//! # The MathML traversal is shared, not copied
//!
//! Step 2 is [`super::mathml_parser`] driven with `MathTarget::Latex`. That
//! module already had the identical scanner and the identical regexes, emitting
//! **Unicode** super/subscripts (`H²`) for the FTS index while Swift emitted
//! **LaTeX** (`{H}^{2}`) for MathJax. Both targets are legitimate; two copies of
//! the scanner were not. See that module's docs for the table.
//!
//! # HTML entity decoding: four tables, and why this one is local
//!
//! There are now four entity decoders in the tree, and they are not redundant so
//! much as *differently incomplete*:
//!
//! | Decoder | Named | Numeric |
//! |---|---|---|
//! | `impress_smart_search::url_extract::decode_html_entities` | 11 | decimal + hex |
//! | **here** | **41** | decimal + hex |
//! | `super::scientific_parser::decode_html_entities` | 6 | none |
//! | `impress-sources/src/crossref.rs::clean_html_tags` | 5 | none |
//!
//! `url_extract`'s is the highest-fidelity *numeric* half and this port wanted
//! to call it. It cannot, for one concrete reason: that function applies its own
//! named table in the same call, `&amp;`-first, so `&amp;lt;` decodes twice and
//! comes out `<`. The golden case `entity-cascading` pins `&lt;` — the source
//! escaped a literal `&lt;` and one decode round is the whole point. Reaching
//! the numeric half alone means splitting a `decode_numeric_entities` out of
//! `url_extract`, which is another crate and outside this change's boundary.
//! **That split is the follow-up that makes this table go away**; until then the
//! numeric half here is a second implementation of the same 20 lines, and this
//! paragraph is the marker.
//!
//! `scientific_parser::decode_html_entities` is deliberately left alone: it is
//! `#[uniffi::export]`ed with a live Swift signature, and its 6-entity table is
//! what its callers were tuned against.

use std::collections::HashSet;

use lazy_static::lazy_static;
use regex::{Captures, Regex};
use unicode_segmentation::UnicodeSegmentation;

use impress_smart_search::foundation::trim_ws_nl;

use super::mathml_parser::{convert_mathml_content, replace_mathml_wrappers, MathTarget};

// ── Public API ──────────────────────────────────────────────────────────────

/// A segment of parsed abstract content.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AbstractSegment {
    /// Prose, to be rendered as text.
    Text(String),
    /// LaTeX for inline rendering.
    InlineMath(String),
    /// LaTeX for display/block rendering.
    DisplayMath(String),
}

impl AbstractSegment {
    /// The discriminator name used by the golden corpus and by any JSON bridge.
    pub fn kind(&self) -> &'static str {
        match self {
            AbstractSegment::Text(_) => "text",
            AbstractSegment::InlineMath(_) => "inlineMath",
            AbstractSegment::DisplayMath(_) => "displayMath",
        }
    }

    /// The segment's payload, regardless of kind.
    pub fn value(&self) -> &str {
        match self {
            AbstractSegment::Text(v)
            | AbstractSegment::InlineMath(v)
            | AbstractSegment::DisplayMath(v) => v,
        }
    }
}

/// Parse abstract text into segments for rendering.
pub fn parse_abstract(text: &str) -> Vec<AbstractSegment> {
    let normalized = normalize_arxiv_escaping(text);
    let with_latex = mathml_to_latex(&normalized);
    let decoded = decode_html_entities(&with_latex);
    let with_scripts = convert_html_sub_sup(&decoded);
    parse_segments(&with_scripts)
}

/// Does this text contain anything the math path needs to handle?
///
/// A substring sniff, not a parse: `$` alone is enough, so "It costs $5 and $10"
/// answers yes. Callers use it to decide whether to *try*, and the segmenter is
/// what decides what is actually math.
pub fn abstract_contains_math(text: &str) -> bool {
    text.contains('$')
        || text.contains("\\(")
        || text.contains("\\[")
        || text.contains("<mml:")
        || text.contains("<inline-formula")
}

/// Convert MathML in `text` to LaTeX, wrapping each formula in `$…$`.
///
/// Swift's `MathMLToLaTeX.convert`. Exposed separately from [`parse_abstract`]
/// because it is independently useful and independently pinned by the corpus.
pub fn mathml_to_latex(text: &str) -> String {
    replace_mathml_wrappers(text, |content| {
        format!("${}$", convert_mathml_content(content, MathTarget::Latex))
    })
}

// ── Step 1: arXiv / JSON escaping ───────────────────────────────────────────

/// LaTeX commands that arrive double-escaped from arXiv's API (and from any
/// JSON round trip that lost a level of quoting).
///
/// Transcribed from the Swift list in source order, one Rust line per Swift
/// line, so the two can be diffed by eye. 186 names — the campaign brief says
/// 182, which counts everything through `Downarrow` and misses the trailing
/// `cdots, ldots, vdots, ddots` line.
#[rustfmt::skip]
const LATEX_COMMANDS: &[&str] = &[
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
    "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma",
    "tau", "upsilon", "phi", "chi", "psi", "omega",
    "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta",
    "Iota", "Kappa", "Lambda", "Mu", "Nu", "Xi", "Pi", "Rho", "Sigma",
    "Tau", "Upsilon", "Phi", "Chi", "Psi", "Omega",
    "pm", "mp", "times", "div", "cdot", "ast", "star", "circ", "bullet",
    "oplus", "otimes", "odot", "oslash", "ominus",
    "le", "ge", "leq", "geq", "ll", "gg", "subset", "supset", "subseteq", "supseteq",
    "in", "notin", "ni", "forall", "exists", "neg", "land", "lor",
    "cap", "cup", "setminus", "emptyset", "varnothing",
    "equiv", "sim", "simeq", "approx", "cong", "neq", "ne", "propto", "doteq",
    "infty", "nabla", "partial", "prime",
    "sum", "prod", "int", "oint", "iint", "iiint",
    "lim", "sup", "inf", "max", "min", "arg", "det", "dim", "ker", "hom",
    "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan",
    "sinh", "cosh", "tanh", "coth", "log", "ln", "exp", "lg",
    "sqrt", "frac", "tfrac", "dfrac", "binom", "tbinom", "dbinom",
    "overline", "underline", "widehat", "widetilde", "hat", "tilde", "bar", "vec", "dot", "ddot",
    "left", "right", "big", "Big", "bigg", "Bigg",
    "text", "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathcal", "mathbb", "mathfrak",
    "hspace", "vspace", "quad", "qquad", "hfill", "vfill",
    "over", "atop", "above", "choose",
    "to", "rightarrow", "leftarrow", "Rightarrow", "Leftarrow", "leftrightarrow", "Leftrightarrow",
    "uparrow", "downarrow", "Uparrow", "Downarrow",
    "cdots", "ldots", "vdots", "ddots",
];

lazy_static! {
    static ref LATEX_COMMAND_SET: HashSet<&'static str> =
        LATEX_COMMANDS.iter().copied().collect();

    /// `\\` followed by a maximal run of ASCII letters.
    ///
    /// Swift used 186 separate passes of `\\\\<cmd>(?![a-zA-Z])`, and the
    /// `regex` crate has no lookahead. The equivalence that removes the need for
    /// one: because every command name is letters-only, `\\p` for a *proper*
    /// prefix `p` of the letter run is always followed by another letter, so
    /// Swift's negative lookahead rejects it. The only prefix that can ever
    /// match is the whole run. So "is the maximal letter run a known command?"
    /// is exactly Swift's predicate — and the run is entirely inside the match,
    /// so nothing beyond it is consumed.
    ///
    /// This is the trap from `docs/smart-search-swift-rust-split.md` §7, where
    /// folding a lookahead into a *consuming* character class ate the delimiter
    /// and silently skipped every second ADS boolean operator. Nothing here
    /// consumes a delimiter: `$\\alphabet$` matches with run `alphabet`, which
    /// is not a command, so the match is rewritten to itself and the `$`
    /// following it was never touched.
    static ref DOUBLE_ESCAPED_COMMAND_RE: Regex = Regex::new(r"\\\\([a-zA-Z]+)").unwrap();
}

/// Normalize arXiv/JSON-style double-escaping to proper LaTeX.
fn normalize_arxiv_escaping(text: &str) -> String {
    // `\[`/`\]` are display-math delimiters at the top level but literal
    // brackets inside `$…$`, so that pass has to run before anything else.
    let mut result = normalize_brackets_in_math_mode(text);

    result = DOUBLE_ESCAPED_COMMAND_RE
        .replace_all(&result, |caps: &Captures| {
            let name = &caps[1];
            if LATEX_COMMAND_SET.contains(name) {
                format!("\\{name}")
            } else {
                caps[0].to_string()
            }
        })
        .into_owned();

    // Spacing commands: `\\,` `\\;` `\\:` `\\!` `\\ `.
    for (from, to) in [
        (r"\\,", r"\,"),
        (r"\\;", r"\;"),
        (r"\\:", r"\:"),
        (r"\\!", r"\!"),
        (r"\\ ", r"\ "),
    ] {
        result = result.replace(from, to);
    }

    // PRESERVED QUIRK — `\_` → `_` is UNCONDITIONAL, prose included, so the
    // golden case `escaped-underscore` turns `name_with\_underscore` into
    // `name_with_underscore` outside any math region. In math mode this is
    // right (`_` is already the subscript operator). In prose it silently
    // removes an escape the author wrote on purpose. Kept because it is what
    // ships and because the fix (only inside `$…$`) needs its own corpus cases
    // to show it doesn't break the math side.
    result = result.replace(r"\_", "_");

    // Escaped braces: `\\{` → `\{`, `\\}` → `\}`.
    result = result.replace(r"\\{", r"\{");
    result = result.replace(r"\\}", r"\}");

    result
}

/// Convert `\[` and `\]` to literal brackets when inside a `$…$` math region.
///
/// A hand-rolled scanner rather than a regex because the `$` toggle is stateful
/// and `$$` has to pass through without flipping it.
fn normalize_brackets_in_math_mode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut result = String::with_capacity(text.len());
    let mut index = 0;
    let mut in_math_mode = false;

    while index < bytes.len() {
        // `$$` (display delimiter) passes through and does NOT toggle.
        if bytes[index..].starts_with(b"$$") {
            result.push_str("$$");
            index += 2;
            continue;
        }

        if bytes[index] == b'$' {
            in_math_mode = !in_math_mode;
            result.push('$');
            index += 1;
            continue;
        }

        if in_math_mode {
            if bytes[index..].starts_with(br"\[") {
                result.push('[');
                index += 2;
                continue;
            }
            if bytes[index..].starts_with(br"\]") {
                result.push(']');
                index += 2;
                continue;
            }
        }

        // Every fast path above consumed ASCII, so `index` is on a char
        // boundary and this cannot panic.
        let ch = text[index..].chars().next().expect("char boundary");
        result.push(ch);
        index += ch.len_utf8();
    }

    result
}

// ── Step 3: HTML entities ───────────────────────────────────────────────────

/// The 41 named entities Swift decoded, in a FIXED order.
///
/// Swift iterated a `[String: String]`, so its order was unspecified and this
/// step was nondeterministic. `&amp;` is last here deliberately: it is the only
/// entity whose expansion can *create* another entity, and the golden case
/// `entity-cascading` shows Swift's captured run left `&amp;lt;` as `&lt;`.
/// Decoding it to `<` would be a double decode of text that was escaped once.
///
/// Note `&micro;` is U+00B5 MICRO SIGN and `&mu;` is U+03BC GREEK SMALL LETTER
/// MU — visually identical, different scalars, both present in the original.
const NAMED_ENTITIES: &[(&str, &str)] = &[
    // Structural (minus `&amp;`, which is last).
    ("&lt;", "<"),
    ("&gt;", ">"),
    ("&nbsp;", " "),
    ("&quot;", "\""),
    ("&apos;", "'"),
    // Dashes.
    ("&ndash;", "\u{2013}"),
    ("&mdash;", "\u{2014}"),
    // Latin-1 symbols.
    ("&times;", "\u{00D7}"),
    ("&divide;", "\u{00F7}"),
    ("&plusmn;", "\u{00B1}"),
    ("&deg;", "\u{00B0}"),
    ("&micro;", "\u{00B5}"),
    // Greek — lowercase only, which is why the corpus case `entity-greek`
    // leaves `&Gamma;` and `&Omega;` untouched.
    ("&alpha;", "\u{03B1}"),
    ("&beta;", "\u{03B2}"),
    ("&gamma;", "\u{03B3}"),
    ("&delta;", "\u{03B4}"),
    ("&epsilon;", "\u{03B5}"),
    ("&theta;", "\u{03B8}"),
    ("&lambda;", "\u{03BB}"),
    ("&mu;", "\u{03BC}"),
    ("&pi;", "\u{03C0}"),
    ("&sigma;", "\u{03C3}"),
    ("&omega;", "\u{03C9}"),
    // Math.
    ("&infin;", "\u{221E}"),
    ("&sum;", "\u{2211}"),
    ("&prod;", "\u{220F}"),
    ("&radic;", "\u{221A}"),
    ("&prop;", "\u{221D}"),
    ("&asymp;", "\u{2248}"),
    ("&ne;", "\u{2260}"),
    ("&le;", "\u{2264}"),
    ("&ge;", "\u{2265}"),
    ("&sub;", "\u{2282}"),
    ("&sup;", "\u{2283}"),
    ("&isin;", "\u{2208}"),
    ("&notin;", "\u{2209}"),
    ("&empty;", "\u{2205}"),
    ("&nabla;", "\u{2207}"),
    ("&part;", "\u{2202}"),
    ("&int;", "\u{222B}"),
    // Last, so its expansion is not itself decoded. See the doc comment.
    ("&amp;", "&"),
];

lazy_static! {
    static ref DECIMAL_ENTITY_RE: Regex = Regex::new(r"&#(\d+);").unwrap();
    static ref HEX_ENTITY_RE: Regex = Regex::new(r"&#x([0-9A-Fa-f]+);").unwrap();
}

/// Decode named and numeric HTML entities.
///
/// Numeric entities are applied back-to-front, decimal pass then hex pass, and
/// an entity naming a surrogate or an out-of-range scalar is left as written —
/// `Unicode.Scalar(UInt32)` returns nil for those and Swift skipped them, which
/// the corpus cases `entity-numeric-surrogate` and `entity-numeric-out-of-range`
/// pin. See the module docs for why this is not `url_extract`'s decoder.
fn decode_html_entities(text: &str) -> String {
    let mut result = text.to_string();

    for (entity, replacement) in NAMED_ENTITIES {
        result = result.replace(entity, replacement);
    }

    result = replace_numeric_entities(&result, &DECIMAL_ENTITY_RE, 10);
    replace_numeric_entities(&result, &HEX_ENTITY_RE, 16)
}

fn replace_numeric_entities(text: &str, re: &Regex, radix: u32) -> String {
    let mut result = text.to_string();
    let hits: Vec<(std::ops::Range<usize>, String)> = re
        .captures_iter(&result)
        .filter_map(|caps| {
            let full = caps.get(0)?.range();
            let code_point = u32::from_str_radix(caps.get(1)?.as_str(), radix).ok()?;
            let scalar = char::from_u32(code_point)?;
            Some((full, scalar.to_string()))
        })
        .collect();
    for (range, replacement) in hits.into_iter().rev() {
        result.replace_range(range, &replacement);
    }
    result
}

// ── Step 4: HTML sub/sup ────────────────────────────────────────────────────

lazy_static! {
    // `[^<]+` rather than `.+?`, so a nested tag defeats the match entirely
    // rather than half-matching: `a<sub>b<i>c</i></sub>` is left alone.
    static ref SUB_TAG_RE: Regex = Regex::new(r"(?i)<sub>([^<]+)</sub>").unwrap();
    static ref SUP_TAG_RE: Regex = Regex::new(r"(?i)<sup>([^<]+)</sup>").unwrap();
}

/// `<sub>x</sub>` → `_x`, `<sub>xx</sub>` → `_{\text{xx}}`; same for `<sup>`.
///
/// The one-character case skips the braces (and the `\text`), so `H<sub>2</sub>O`
/// becomes `H_2O` while `M<sub>halo</sub>` becomes `M_{\text{halo}}`. Swift
/// counted `Character`s, i.e. extended grapheme clusters, so a combining
/// sequence counts as one — hence `graphemes(true)` here rather than `chars()`.
fn convert_html_sub_sup(text: &str) -> String {
    let subs = SUB_TAG_RE.replace_all(text, |caps: &Captures| script_replacement('_', &caps[1]));
    SUP_TAG_RE
        .replace_all(&subs, |caps: &Captures| script_replacement('^', &caps[1]))
        .into_owned()
}

fn script_replacement(operator: char, content: &str) -> String {
    if content.graphemes(true).count() == 1 {
        format!("{operator}{content}")
    } else {
        format!("{operator}{{\\text{{{content}}}}}")
    }
}

// ── Step 5: segmentation ────────────────────────────────────────────────────

/// Split processed text into text / inline-math / display-math segments.
///
/// PRESERVED QUIRK — the accumulated text is flushed as a segment *before* the
/// delimiter is known to be valid, and is not restored when it isn't. So
/// `"before $$ after"` (an unterminated `$$`) comes out as three text segments,
/// `["before ", "$", "$ after"]`, rather than one. Renderers concatenate text
/// segments, so this is invisible in output and is exactly why it survived;
/// `empty-inline-math`, `unclosed-inline`, `unclosed-display` and
/// `inline-with-blank-line` all pin it. Fixing it means buffering the flush
/// until the delimiter closes, which is a real change to segment boundaries and
/// therefore to any caller that indexes them.
fn parse_segments(text: &str) -> Vec<AbstractSegment> {
    let bytes = text.as_bytes();
    let mut segments: Vec<AbstractSegment> = Vec::new();
    let mut current_text = String::new();
    let mut index = 0;

    while index < bytes.len() {
        // Display math `$$…$$`, checked before the single-`$` form.
        if bytes[index..].starts_with(b"$$") {
            flush(&mut current_text, &mut segments);
            let math_start = index + 2;
            if let Some(offset) = text[math_start..].find("$$") {
                let math_end = math_start + offset;
                let latex = trim_ws_nl(&text[math_start..math_end]);
                if !latex.is_empty() {
                    segments.push(AbstractSegment::DisplayMath(latex.to_string()));
                }
                index = math_end + 2;
                continue;
            }
        }

        // Display math `\[…\]`.
        if bytes[index..].starts_with(br"\[") {
            flush(&mut current_text, &mut segments);
            let math_start = index + 2;
            if let Some(offset) = text[math_start..].find(r"\]") {
                let math_end = math_start + offset;
                let latex = trim_ws_nl(&text[math_start..math_end]);
                if !latex.is_empty() {
                    segments.push(AbstractSegment::DisplayMath(latex.to_string()));
                }
                index = math_end + 2;
                continue;
            }
        }

        // Inline math `$…$`. Not trimmed, and rejected when empty or when it
        // spans a blank line — a lone `$` in prose is far more likely currency
        // than an unterminated formula.
        if bytes[index] == b'$' {
            let next_index = index + 1;
            if next_index < bytes.len() && bytes[next_index] != b'$' {
                flush(&mut current_text, &mut segments);
                if let Some(offset) = text[next_index..].find('$') {
                    let math_end = next_index + offset;
                    let latex = &text[next_index..math_end];
                    if !latex.is_empty() && !latex.contains("\n\n") {
                        segments.push(AbstractSegment::InlineMath(latex.to_string()));
                        index = math_end + 1;
                        continue;
                    }
                }
            }
        }

        // Inline math `\(…\)`.
        if bytes[index..].starts_with(br"\(") {
            flush(&mut current_text, &mut segments);
            let math_start = index + 2;
            if let Some(offset) = text[math_start..].find(r"\)") {
                let math_end = math_start + offset;
                let latex = &text[math_start..math_end];
                if !latex.is_empty() {
                    segments.push(AbstractSegment::InlineMath(latex.to_string()));
                }
                index = math_end + 2;
                continue;
            }
        }

        let ch = text[index..].chars().next().expect("char boundary");
        current_text.push(ch);
        index += ch.len_utf8();
    }

    flush(&mut current_text, &mut segments);
    segments
}

fn flush(current_text: &mut String, segments: &mut Vec<AbstractSegment>) {
    if !current_text.is_empty() {
        segments.push(AbstractSegment::Text(std::mem::take(current_text)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(text: &str) -> Vec<(&'static str, String)> {
        parse_abstract(text)
            .into_iter()
            .map(|s| (s.kind(), s.value().to_string()))
            .collect()
    }

    #[test]
    fn command_table_has_no_duplicates() {
        assert_eq!(
            LATEX_COMMANDS.len(),
            LATEX_COMMAND_SET.len(),
            "a command name is listed twice"
        );
        assert_eq!(LATEX_COMMANDS.len(), 186);
    }

    #[test]
    fn entity_table_is_the_swift_41() {
        assert_eq!(NAMED_ENTITIES.len(), 41);
        let names: HashSet<&str> = NAMED_ENTITIES.iter().map(|(k, _)| *k).collect();
        assert_eq!(names.len(), 41, "an entity is listed twice");
        // `&amp;` must stay last or `&amp;lt;` double-decodes.
        assert_eq!(NAMED_ENTITIES.last().unwrap().0, "&amp;");
        // The two mus are distinct scalars.
        assert_ne!(
            decode_html_entities("&micro;"),
            decode_html_entities("&mu;")
        );
    }

    /// The lookahead replacement, stated as a test: a longer word that merely
    /// *starts* with a command name must not be rewritten.
    #[test]
    fn command_prefixes_are_not_commands() {
        assert_eq!(normalize_arxiv_escaping(r"$\\alphabet$"), r"$\\alphabet$");
        assert_eq!(normalize_arxiv_escaping(r"$\\alpha$"), r"$\alpha$");
        // The reverse direction: a name that is itself a longer command must
        // win over its own prefix (`sin` ⊂ `sinh`).
        assert_eq!(normalize_arxiv_escaping(r"$\\sinh x$"), r"$\sinh x$");
        assert_eq!(normalize_arxiv_escaping(r"$\\sin x$"), r"$\sin x$");
        // …and an unknown longer word is left whole, not partially rewritten.
        assert_eq!(normalize_arxiv_escaping(r"$\\sinhx$"), r"$\\sinhx$");
    }

    #[test]
    fn brackets_are_literal_only_inside_dollar_math() {
        assert_eq!(
            normalize_brackets_in_math_mode(r"$a \[ b \]$ and \[ c \]"),
            r"$a [ b ]$ and \[ c \]"
        );
        // `$$` passes through without toggling, so what follows is NOT math.
        assert_eq!(
            normalize_brackets_in_math_mode(r"$$a$$ \[b\]"),
            r"$$a$$ \[b\]"
        );
    }

    #[test]
    fn multibyte_text_survives_the_scanners() {
        assert_eq!(
            kinds("Ωmega ≤ $x$ — café"),
            vec![
                ("text", "Ωmega ≤ ".to_string()),
                ("inlineMath", "x".to_string()),
                ("text", " — café".to_string()),
            ]
        );
    }

    #[test]
    fn grapheme_clusters_count_as_one_character() {
        // "é" as e + U+0301 is two scalars but one Character in Swift, so it
        // takes the single-character branch.
        assert_eq!(convert_html_sub_sup("x<sub>e\u{0301}</sub>"), "x_e\u{0301}");
        assert_eq!(convert_html_sub_sup("x<sub>ab</sub>"), "x_{\\text{ab}}");
    }

    #[test]
    fn contains_math_is_a_sniff_not_a_parse() {
        assert!(abstract_contains_math("It costs $5"));
        assert!(abstract_contains_math("<inline-formula>x</inline-formula>"));
        assert!(!abstract_contains_math("plain prose"));
        assert!(!abstract_contains_math(r"an escape \_ only"));
    }
}
