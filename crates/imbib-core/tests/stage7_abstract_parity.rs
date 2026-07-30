//! Golden-corpus parity for the abstract parser (Stage 7 item 9).
//!
//! `test_fixtures/golden/abstract_parse.json` was captured from
//! `PublicationManagerCore/RichText/AbstractParser.swift` **before** the Rust
//! port existed. These tests assert the port reproduces that behaviour.
//!
//! Three surfaces are asserted per corpus case, because they fail
//! independently: `containsMath` (a substring sniff over the RAW input),
//! `mathmlConverted` (`MathMLToLaTeX.convert` over the RAW input, i.e. *not* in
//! pipeline order), and the segment list (the whole five-step pipeline).
//!
//! Deliberate divergences are listed with a prose reason and asserted
//! positively in a companion test. An unlisted mismatch fails the build. There
//! is no regeneration path.

mod common;

use common::fixtures::load_fixture;
use serde_json::Value;

use imbib_core::text::{abstract_contains_math, mathml_to_latex, parse_abstract};

// ── Plumbing ────────────────────────────────────────────────────────────────

fn golden(name: &str) -> Vec<Value> {
    let raw = load_fixture(&format!("golden/{name}"));
    let parsed: Value =
        serde_json::from_str(&raw).unwrap_or_else(|e| panic!("bad golden {name}: {e}"));
    parsed
        .as_array()
        .unwrap_or_else(|| panic!("{name} is not an array"))
        .clone()
}

#[derive(Default)]
struct Report {
    lines: Vec<String>,
    checked: usize,
}

impl Report {
    fn push(&mut self, scope: impl AsRef<str>, detail: String) {
        self.lines.push(format!("[{}] {detail}", scope.as_ref()));
    }

    fn eq<T: PartialEq + std::fmt::Debug>(&mut self, scope: impl AsRef<str>, want: T, got: T) {
        self.checked += 1;
        if want != got {
            self.push(scope, format!("want {want:?}, got {got:?}"));
        }
    }

    fn assert_empty(self, what: &str, min_checks: usize) {
        assert!(
            self.checked >= min_checks,
            "{what}: only {} assertions ran, expected at least {min_checks} — \
             the corpus shrank or a loop stopped early",
            self.checked
        );
        if !self.lines.is_empty() {
            let shown: Vec<_> = self.lines.iter().take(40).cloned().collect();
            panic!(
                "{} golden mismatches for {what} (of {} checks):\n{}",
                self.lines.len(),
                self.checked,
                shown.join("\n")
            );
        }
    }
}

fn s(v: &Value) -> &str {
    v.as_str().unwrap_or_default()
}

/// The corpus segment list as `(kind, value)` pairs.
fn want_segments(case: &Value) -> Vec<(String, String)> {
    case["segments"]
        .as_array()
        .unwrap_or_else(|| panic!("case {:?} has no segments array", s(&case["name"])))
        .iter()
        .map(|seg| (s(&seg["kind"]).to_string(), s(&seg["value"]).to_string()))
        .collect()
}

fn got_segments(input: &str) -> Vec<(String, String)> {
    parse_abstract(input)
        .into_iter()
        .map(|seg| (seg.kind().to_string(), seg.value().to_string()))
        .collect()
}

fn corpus_case(name: &str) -> Value {
    golden("abstract_parse.json")
        .into_iter()
        .find(|c| s(&c["name"]) == name)
        .unwrap_or_else(|| panic!("missing corpus case {name}"))
}

// ── Divergences ─────────────────────────────────────────────────────────────

/// Cases whose SEGMENTS legitimately differ from Swift, by corpus-case name.
///
/// Empty, and that is the finding rather than an omission: every one of the 56
/// cases reproduces exactly, including the five that encode outright bugs
/// (`escaped-underscore`'s unconditional `\_` → `_`, the three-text-segment
/// split from the premature flush, the `mfrac`/`msqrt` nesting gap, the
/// `${a2}^{}3$` nested-`msup` collapse, and `$5 and $10` read as inline math).
/// Those are preserved quirks with doc comments in
/// `src/text/abstract_parser.rs` saying why each was kept, not divergences —
/// fixing them changes rendered output, which is a product decision and wants
/// its own corpus cases showing the improvement.
///
/// The one place the port genuinely decides something Swift left to chance is
/// entity ordering, and it is unobservable as a mismatch because the choice
/// *agrees* with the captured run — see `entity_order_is_pinned_not_inherited`.
const ABSTRACT_DIVERGENCES: &[(&str, &str)] = &[];

// ── The corpus ──────────────────────────────────────────────────────────────

#[test]
fn abstract_parse_matches_swift() {
    let corpus = golden("abstract_parse.json");
    assert_eq!(
        corpus.len(),
        56,
        "the abstract corpus changed size; it is captured output, not an input to edit"
    );

    let mut report = Report::default();
    let mut names_seen: Vec<String> = Vec::new();

    for case in &corpus {
        let name = s(&case["name"]).to_string();
        let input = s(&case["input"]);
        names_seen.push(name.clone());

        // `containsMath` and `mathmlConverted` are both applied to the RAW
        // input, not to the pipeline's intermediate state.
        report.eq(
            format!("{name}/containsMath"),
            case["containsMath"].as_bool().unwrap_or_else(|| {
                panic!("case {name} has no containsMath bool");
            }),
            abstract_contains_math(input),
        );
        report.eq(
            format!("{name}/mathmlConverted"),
            s(&case["mathmlConverted"]).to_string(),
            mathml_to_latex(input),
        );

        if ABSTRACT_DIVERGENCES.iter().any(|(n, _)| *n == name) {
            continue;
        }
        report.eq(
            format!("{name}/segments"),
            want_segments(case),
            got_segments(input),
        );
    }

    for (name, _) in ABSTRACT_DIVERGENCES {
        assert!(
            names_seen.iter().any(|n| n == name),
            "listed abstract divergence {name:?} is no longer in the corpus"
        );
    }
    report.assert_empty("abstract parsing", 165);
}

/// A listed divergence must actually diverge, or the entry is stale. Vacuous
/// while the table is empty — kept so that adding an entry cannot skip the
/// check, which is how a "documented divergence" becomes a silent regression.
#[test]
fn listed_divergences_still_diverge() {
    for (name, reason) in ABSTRACT_DIVERGENCES {
        let case = corpus_case(name);
        assert!(!reason.is_empty(), "{name} has no reason");
        assert_ne!(
            want_segments(&case),
            got_segments(s(&case["input"])),
            "{name:?} is listed as a divergence but now agrees with Swift — \
             remove the entry"
        );
    }
}

// ── The pieces, asserted directly ───────────────────────────────────────────

/// The lookahead replacement, which is the part of this port most likely to be
/// "simplified" into a consuming character class later.
///
/// `regex` has no lookaround, so Swift's 186 passes of `\\\\<cmd>(?![a-zA-Z])`
/// became one pass of `\\\\([a-zA-Z]+)` plus a set membership test on the
/// captured run. `command-prefix-trap` is the case that proves it: `\\alphabet`
/// starts with the command `alpha`, and a rule that matched the prefix and
/// consumed one delimiter character would emit `\alphabet` *and* eat the closing
/// `$`, which is precisely the failure mode
/// `docs/smart-search-swift-rust-split.md` §7 records for the ADS
/// boolean-operator rule.
#[test]
fn command_prefix_trap_is_not_sprung() {
    let case = corpus_case("command-prefix-trap");
    let segments = parse_abstract(s(&case["input"]));

    // Still two segments — the `$` delimiters survived.
    assert_eq!(segments.len(), 2, "delimiter was consumed: {segments:?}");
    // The double backslash is intact: `\\alphabet` is NOT a command.
    assert_eq!(segments[0].kind(), "inlineMath");
    assert_eq!(segments[0].value(), r"\\alphabet");
    assert_eq!(segments[1].value(), r" should not become \alphabet");

    // The neighbouring positive case, so this test can't pass by refusing to
    // rewrite anything at all.
    let greek = parse_abstract(s(&corpus_case("arxiv-escaped-greek")["input"]));
    assert_eq!(greek[1].value(), r"\beta = 1.5");
    assert_eq!(greek[3].value(), r"\alpha_0");
}

/// `mathmlConverted` is the LaTeX rendering; `parse_mathml` is the Unicode one.
/// Both run over the same shared traversal, so assert they still disagree in the
/// documented way on the very same corpus inputs — a regression that collapsed
/// the two targets would otherwise show up only in the FTS index, silently.
#[test]
fn latex_and_unicode_renderings_stay_distinct() {
    use imbib_core::text::parse_mathml;

    for (name, want_latex, want_unicode) in [
        ("mathml-msup", "${H}^{2}$", "H²"),
        ("mathml-msub", "${x}_{1}$", "x₁"),
        // `mfrac`/`msqrt` exist only in the LaTeX path; the Unicode path lets
        // the tag stripper flatten them, which is what the FTS index wants.
        ("mathml-mfrac", "$\\frac{a}{b}$", "ab"),
        ("mathml-msqrt", "$\\sqrt{a}$", "a"),
    ] {
        let input = s(&corpus_case(name)["input"]).to_string();
        assert_eq!(mathml_to_latex(&input), want_latex, "{name} latex");
        assert_eq!(parse_mathml(input), want_unicode, "{name} unicode");
    }
}

/// Swift decoded entities by iterating a `Dictionary`, so its order — and hence
/// its answer for input where one expansion creates another — was unspecified.
/// The port pins `&amp;` last. `entity-cascading` shows the captured Swift run
/// agreed, and this test states the rule rather than leaving it to the corpus:
/// escaped text decodes exactly once.
#[test]
fn entity_order_is_pinned_not_inherited() {
    let case = corpus_case("entity-cascading");
    assert_eq!(
        got_segments(s(&case["input"])),
        vec![("text".to_string(), "&lt; decodes once".to_string())]
    );
    // `&amp;amp;` is the same rule one turn further out.
    assert_eq!(
        got_segments("&amp;amp; once")[0].1,
        "&amp; once".to_string()
    );
}

/// Foundation's `.whitespacesAndNewlines` contains U+200B and `str::trim()`
/// does not, so display-math trimming has to use the Foundation predicate. No
/// corpus case carries a zero-width space (they are invisible, which is how they
/// survive a capture), so this is the only thing holding that call site.
#[test]
fn display_math_trims_the_foundation_whitespace_set() {
    let segments = parse_abstract("a $$\u{200B} x = 1 \u{200B}$$ b");
    assert_eq!(
        segments
            .iter()
            .map(|s| (s.kind(), s.value()))
            .collect::<Vec<_>>(),
        vec![("text", "a "), ("displayMath", "x = 1"), ("text", " b")]
    );

    // A display region that is nothing but zero-width space is empty, and an
    // empty region emits no segment at all.
    assert_eq!(parse_abstract("$$\u{200B}$$"), vec![]);
}

/// Inline math is deliberately NOT trimmed, unlike both display forms. Pinned
/// because the asymmetry looks like an oversight and reads as one.
#[test]
fn inline_math_is_not_trimmed_but_display_is() {
    let inline = parse_abstract("$ x $");
    assert_eq!(inline[0].value(), " x ");

    let display = parse_abstract("$$ x $$");
    assert_eq!(display[0].value(), "x");

    let bracket = parse_abstract(r"\[ x \]");
    assert_eq!(bracket[0].value(), "x");
}
