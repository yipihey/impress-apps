//! Golden-corpus parity for the PDF/artifact half of the Stage 7 item 9 batch.
//!
//! `test_fixtures/golden/{pdf_*,artifact_*}.json` was captured from
//! `PDFMetadataExtractor` and `ArtifactMetadataExtractor` **before** their
//! pure-logic halves moved to Rust. These tests assert the ports reproduce that
//! behaviour.
//!
//! Deliberate divergences are listed per-section with the reason, and each has a
//! companion test asserting the corrected value positively. An unlisted mismatch
//! fails the build. There is no regeneration path.

mod common;

use common::fixtures::load_fixture;
use serde_json::Value;

// ── Plumbing (file-local copies, as in stage7_parser_parity.rs) ──────────────

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

fn opt(v: &Value) -> Option<String> {
    v.as_str().map(str::to_string)
}

fn opt_strings(v: &Value) -> Vec<String> {
    v.as_array()
        .map(|a| a.iter().map(|e| s(e).to_string()).collect())
        .unwrap_or_default()
}

// ── Item 9.x: isPlausibleTitle ──────────────────────────────────────────────

/// No divergences. The junk filter is a pure rejection predicate over strings
/// the PDF handed us; there is nothing in it to get wrong in a way that a fix
/// would improve, and every rejection it makes is one imbib wants.
#[test]
fn plausible_title_matches_swift() {
    use imbib_core::pdf::is_plausible_title;

    let mut report = Report::default();
    for case in golden("pdf_plausible_title.json") {
        let input = s(&case["input"]);
        report.eq(
            format!("{input:?}"),
            case["isPlausible"].as_bool().unwrap(),
            is_plausible_title(input),
        );
    }
    report.assert_empty("isPlausibleTitle", 23);
}

/// Swift applied both regexes with `range(of:options:.regularExpression)`, which
/// is a SEARCH, not a full match. Both patterns are anchored `^…$`, so the
/// search can only succeed on the whole string — asserted here rather than
/// merely commented, because Rust's `is_match` is also a search and a future
/// edit that drops an anchor would change both sides in the same direction.
#[test]
fn plausible_title_anchored_patterns_behave_as_full_matches() {
    use imbib_core::pdf::is_plausible_title;

    // Anchored PII shape: rejected bare, accepted with any prefix or suffix.
    assert!(!is_plausible_title("1234-5678(96)00123-4"));
    assert!(is_plausible_title("Erratum 1234-5678(96)00123-4"));
    assert!(is_plausible_title("1234-5678(96)00123-4 Erratum"));

    // Anchored bare-DOI shape: same story, and this pair is in the corpus.
    assert!(!is_plausible_title("10.1038/nature12373"));
    assert!(is_plausible_title("10.1038/nature12373 and more"));
}

/// Swift's `.letters` is Unicode category L*, not `[A-Za-z]`. A port that
/// reached for `is_ascii_alphabetic` would silently reject non-Latin titles as
/// "all punctuation" — the corpus carries `"Ångström …"` for exactly this.
#[test]
fn letter_check_is_unicode_not_ascii() {
    use imbib_core::pdf::is_plausible_title;

    assert!(is_plausible_title("Ångström Measurements of Müller Bands"));
    assert!(is_plausible_title("Электронная структура"));
    assert!(is_plausible_title("超伝導の理論について"));
    assert!(!is_plausible_title("!!!???"));
    assert!(!is_plausible_title("1234567890"));
}

// ── Item 9.x: bestTitle / bestAuthors / bestYear / hasIdentifier ─────────────

/// The one field whose value legitimately changed, named by corpus case.
const BEST_METADATA_DIVERGENCES: &[(&str, &str, &str)] = &[(
    "authors-whitespace-only-doc",
    "bestAuthors",
    "The document's `authorAttribute` is `\"   \"`. Swift gated on \
     `!author.isEmpty` — untrimmed — so three spaces counted as \"the PDF told \
     us the authors\"; the comma split then produced one empty component, the \
     non-empty filter dropped it, and `bestAuthors` returned `[]` while \
     `heuristicAuthors` held `[\"Kaiser, N.\"]` the whole time. Recovered author \
     data was discarded in favour of nothing, which is data integrity, not \
     taste: the gate now asks whether the attribute has any VISIBLE content. \
     Every other corpus row is unaffected, including the genuinely empty \
     `\"\"` one, which already fell through.",
)];

fn best_metadata_divergence(name: &str) -> Option<&'static str> {
    BEST_METADATA_DIVERGENCES
        .iter()
        .find(|(n, _, _)| *n == name)
        .map(|(_, field, _)| *field)
}

fn fields_from(case: &Value) -> imbib_core::pdf::PdfExtractedFields {
    imbib_core::pdf::PdfExtractedFields {
        title: opt(&case["title"]),
        author: opt(&case["author"]),
        heuristic_title: opt(&case["heuristicTitle"]),
        heuristic_authors: opt_strings(&case["heuristicAuthors"]),
        heuristic_year: case["heuristicYear"].as_i64().map(|y| y as i32),
        first_page_text: opt(&case["firstPageText"]),
        extracted_doi: opt(&case["extractedDOI"]),
        extracted_arxiv_id: opt(&case["extractedArXivID"]),
        extracted_bibcode: opt(&case["extractedBibcode"]),
    }
}

#[test]
fn best_metadata_matches_swift() {
    let mut report = Report::default();
    let mut names_seen: Vec<String> = Vec::new();

    for case in golden("pdf_best_metadata.json") {
        let name = s(&case["name"]).to_string();
        names_seen.push(name.clone());
        let fields = fields_from(&case);

        report.eq(
            format!("{name}/bestTitle"),
            opt(&case["bestTitle"]),
            fields.best_title(),
        );
        report.eq(
            format!("{name}/bestYear"),
            case["bestYear"].as_i64().map(|y| y as i32),
            fields.best_year(),
        );
        report.eq(
            format!("{name}/hasIdentifier"),
            case["hasIdentifier"].as_bool().unwrap(),
            fields.has_identifier(),
        );

        // The Swift projection must match everywhere, with no exemptions: it is
        // the proof that the port reproduces the original's decisions.
        report.eq(
            format!("{name}/bestAuthors(swift)"),
            opt_strings(&case["bestAuthors"]),
            fields.best_authors_swift(),
        );

        let got = fields.best_authors();
        if best_metadata_divergence(&name) == Some("bestAuthors") {
            assert_ne!(
                got,
                opt_strings(&case["bestAuthors"]),
                "{name} is listed as a bestAuthors divergence but now agrees \
                 with Swift — remove the entry"
            );
            continue;
        }
        report.eq(
            format!("{name}/bestAuthors"),
            opt_strings(&case["bestAuthors"]),
            got,
        );
    }

    for (name, _, _) in BEST_METADATA_DIVERGENCES {
        assert!(
            names_seen.iter().any(|n| n == name),
            "listed best-metadata divergence {name:?} is no longer in the corpus"
        );
    }
    report.assert_empty("PDFExtractedMetadata best* fields", 70);
}

/// The divergence, asserted positively: the heuristically recovered author now
/// survives a whitespace-only document `authorAttribute`.
#[test]
fn whitespace_only_document_author_no_longer_swallows_the_heuristic() {
    let case = golden("pdf_best_metadata.json")
        .into_iter()
        .find(|c| s(&c["name"]) == "authors-whitespace-only-doc")
        .expect("missing corpus case");
    let fields = fields_from(&case);

    assert_eq!(fields.best_authors_swift(), Vec::<String>::new());
    assert_eq!(fields.best_authors(), vec!["Kaiser, N.".to_string()]);
}

/// Two quirks of `bestTitle` that are preserved rather than fixed, pinned so
/// that "preserved" stays a decision and not an accident.
#[test]
fn best_title_trusts_the_heuristic_without_re_screening_it() {
    use imbib_core::pdf::PdfExtractedFields;

    // A junk DOCUMENT title is screened out …
    let doc_junk = PdfExtractedFields {
        title: Some("Untitled".into()),
        heuristic_title: Some("A Heuristic Title".into()),
        ..Default::default()
    };
    assert_eq!(doc_junk.best_title().as_deref(), Some("A Heuristic Title"));

    // … but a junk HEURISTIC title is not, and still beats the first-page text.
    let heuristic_junk = PdfExtractedFields {
        heuristic_title: Some("ab".into()),
        first_page_text: Some("First Page Guess".into()),
        ..Default::default()
    };
    assert_eq!(heuristic_junk.best_title().as_deref(), Some("ab"));
}

/// The comma-only author split, pinned. Semicolon-separated document authors are
/// mangled; see `split_document_author`'s doc comment for why the fix is a name
/// parser and not a wider separator set.
#[test]
fn document_author_splits_on_commas_only() {
    use imbib_core::pdf::PdfExtractedFields;

    let fields = PdfExtractedFields {
        author: Some("Smith, John; Doe, Jane".into()),
        ..Default::default()
    };
    assert_eq!(fields.best_authors(), ["Smith", "John; Doe", "Jane"]);
}

// ── Item 9.x: the retired extractTitleFromFirstPage ─────────────────────────

/// No divergences: the port is a faithful reproduction of a function that is
/// being RETIRED, so "fixing" it would defeat its only purpose. The fixes live
/// in `metadata_heuristics::extract_title`, which is the survivor; the test
/// below is the evidence for that choice.
#[test]
fn swift_first_page_title_matches_swift() {
    use imbib_core::pdf::swift_first_page_title;

    let mut report = Report::default();
    for case in golden("pdf_first_page_title.json") {
        let name = s(&case["name"]);
        report.eq(
            name,
            opt(&case["swiftTitle"]),
            swift_first_page_title(s(&case["text"])),
        );
    }
    report.assert_empty("extractTitleFromFirstPage (Swift projection)", 8);
}

/// Where the surviving Rust implementation and the retired Swift duplicate
/// disagree on the golden inputs, and which one is right.
///
/// Entries are `(corpus case, what changes and why it is better)`. A case that
/// is NOT listed must produce identical output on both — that is what makes the
/// retirement safe rather than merely convenient.
const EXTRACT_TITLE_IMPROVEMENTS: &[(&str, &str)] = &[
    (
        "simple",
        "Swift returned `\"The Statistics of Peaks of Gaussian Random Fields \
         J. M. Bardeen, J. R. Bond, N. Kaiser, A. S. Szalay\"` — the title with \
         the author line glued on. It has no author-line detector at all beyond \
         `\" and \"` plus four capitals, so a comma-separated byline sails \
         through and becomes candidate #2. The survivor runs \
         `looks_like_author_line`, which catches the comma form, and returns the \
         title alone. This is the single most common real-world PDF shape, so \
         the drifted duplicate was corrupting the majority of imports it \
         touched.",
    ),
    (
        "authors-first",
        "The only input where the retired version returns MORE than the \
         survivor: authors on line 1, title on line 2. Swift skipped the byline \
         and answered `\"Title After Authors\"`; the survivor stops collecting \
         once it has passed an author-like line and answers `None`. That is a \
         deliberate precision-over-recall trade — after the byline comes the \
         affiliation block and the abstract, and a scanner that keeps going \
         there returns an affiliation as the title far more often than it \
         rescues an inverted layout. `None` is also not a dead end: \
         `bestTitle` falls through to the first-page fragment.",
    ),
];

/// Prove, on the very inputs the Swift version was captured on, what the
/// surviving implementation does instead. `extract_title` is private, so it is
/// reached through `extract_metadata_heuristics_internal`, whose `title` field
/// IS its return value.
#[test]
fn surviving_rust_extract_title_differs_only_where_documented() {
    use imbib_core::pdf::{extract_metadata_heuristics_internal, swift_first_page_title};

    let mut report = Report::default();
    let mut improvements_hit = 0;

    for case in golden("pdf_first_page_title.json") {
        let name = s(&case["name"]).to_string();
        let text = s(&case["text"]);
        let swift = swift_first_page_title(text);
        let rust = extract_metadata_heuristics_internal(text, 2026).title;

        if EXTRACT_TITLE_IMPROVEMENTS.iter().any(|(n, _)| *n == name) {
            improvements_hit += 1;
            assert_ne!(
                swift, rust,
                "{name} is listed as an extract_title improvement but the two \
                 implementations now agree — remove the entry"
            );
            continue;
        }
        report.eq(format!("{name}/agree"), swift, rust);
    }

    assert_eq!(
        improvements_hit,
        EXTRACT_TITLE_IMPROVEMENTS.len(),
        "a listed extract_title improvement is no longer in the corpus"
    );
    report.assert_empty("extract_title vs the retired duplicate", 6);
}

/// The two documented differences, asserted positively.
#[test]
fn surviving_rust_extract_title_is_the_better_answer() {
    use imbib_core::pdf::{extract_metadata_heuristics_internal, swift_first_page_title};

    let corpus = golden("pdf_first_page_title.json");
    let text_of = |name: &str| {
        corpus
            .iter()
            .find(|c| s(&c["name"]) == name)
            .unwrap_or_else(|| panic!("missing corpus case {name}"))["text"]
            .as_str()
            .unwrap_or_default()
            .to_string()
    };

    // `simple`: the survivor drops the byline the duplicate absorbed.
    let simple = text_of("simple");
    assert_eq!(
        swift_first_page_title(&simple).as_deref(),
        Some(
            "The Statistics of Peaks of Gaussian Random Fields \
             J. M. Bardeen, J. R. Bond, N. Kaiser, A. S. Szalay"
        )
    );
    assert_eq!(
        extract_metadata_heuristics_internal(&simple, 2026)
            .title
            .as_deref(),
        Some("The Statistics of Peaks of Gaussian Random Fields")
    );

    // `authors-first`: the survivor declines rather than guessing past a byline.
    let inverted = text_of("authors-first");
    assert_eq!(
        swift_first_page_title(&inverted).as_deref(),
        Some("Title After Authors")
    );
    assert_eq!(
        extract_metadata_heuristics_internal(&inverted, 2026).title,
        None
    );
}

// ── Item 9.x: extractMetaContent ────────────────────────────────────────────

/// No divergences. Both overloads are reproduced exactly, including the
/// `content=""` / `content="   "` asymmetry and the missing reversed-order
/// pattern on the `name:` overload — see `artifact_meta.rs` for why each is a
/// product decision rather than a conformance bug.
#[test]
fn meta_content_matches_swift() {
    use imbib_core::pdf::{extract_meta_content_name, extract_meta_content_property};

    let mut report = Report::default();
    for case in golden("artifact_meta_content.json") {
        let name = s(&case["name"]);
        let html = s(&case["html"]);
        report.eq(
            format!("{name}/og:title"),
            opt(&case["ogTitle"]),
            extract_meta_content_property(html, "og:title"),
        );
        report.eq(
            format!("{name}/og:description"),
            opt(&case["ogDescription"]),
            extract_meta_content_property(html, "og:description"),
        );
        report.eq(
            format!("{name}/author"),
            opt(&case["author"]),
            extract_meta_content_name(html, "author"),
        );
    }
    report.assert_empty("extractMetaContent", 48);
}

/// `[^>]+` cannot cross a `>`, which is the only thing stopping one tag's
/// `property` from pairing with the next tag's `content`. Pinned because a
/// well-meaning switch to `(?s).+?` would break it silently: every corpus case
/// has its attributes in one tag, so nothing there would fail.
#[test]
fn meta_patterns_cannot_pair_attributes_across_tags() {
    use imbib_core::pdf::extract_meta_content_property;

    // `og:title` has no `content` of its own; the next tag's must NOT be used.
    let html = r#"<meta property="og:title"><meta content="Not Mine">"#;
    assert_eq!(extract_meta_content_property(html, "og:title"), None);

    // …while a tag broken across lines IS matched, because `[^>]` includes `\n`.
    let multiline = "<meta property=\"og:title\"\n      content=\"Across Lines\">";
    assert_eq!(
        extract_meta_content_property(multiline, "og:title").as_deref(),
        Some("Across Lines")
    );
}

// ── Item 9.x: inferArtifactType (pure half only) ─────────────────────────────

/// Corpus rows whose answer comes from Swift's `UTType.conforms(to:)` tail — the
/// PLATFORM half, deliberately not ported. `infer_artifact_type_from_filename`
/// returns `None` for these, meaning "undecided, ask `UTType`".
///
/// The list is exhaustive and its length is asserted, so a future edit cannot
/// widen the exemption to hide a real mismatch.
const UTTYPE_EXEMPT_ROWS: &[(&str, &str)] = &[
    (
        "paper.pdf",
        "`pdf` is absent from Swift's extension table; PDFs reach the UTType \
         block and fall out of its bottom as `.general`. Answering `General` in \
         the pure half would be right for this row and wrong for the next four.",
    ),
    (
        "figure.png",
        "`UTType.conforms(to: .image)` → `.media`. The conformance graph is \
         populated from installed apps' declared types, so it is a property of \
         the machine, not of the filename.",
    ),
    ("figure.jpg", "As `figure.png`: `.image` → `.media`."),
    ("movie.mp4", "`UTType.conforms(to: .movie)` → `.media`."),
    ("audio.m4a", "`UTType.conforms(to: .audio)` → `.media`."),
    (
        "archive.zip",
        "Conforms to `.archive`, which the block does not test, so it reaches \
         `.general`.",
    ),
    (
        "noextension",
        "`UTType(filenameExtension: \"\")` is `nil`; the whole block is skipped \
         and the result is `.general`.",
    ),
    (
        "UPPER.PDF",
        "Same as `paper.pdf` — the extension is lowercased before the table \
         lookup, so the uppercase spelling changes nothing and both land in the \
         platform tail.",
    ),
    (
        "weird.name.with.dots.pdf",
        "Foundation's `pathExtension` takes the LAST dot, so this is `pdf` and \
         it lands in the platform tail like the others. Included because a \
         hand-rolled `split('.')` would read `name` here and answer differently.",
    ),
];

#[test]
fn infer_artifact_type_matches_swift_for_the_pure_half() {
    use imbib_core::pdf::infer_artifact_type_from_filename;

    let mut report = Report::default();
    let mut exempt_hit = 0;
    let mut rows = 0;

    for case in golden("artifact_infer_type.json") {
        rows += 1;
        let filename = s(&case["filename"]);
        let want = s(&case["artifactType"]).to_string();
        let got = infer_artifact_type_from_filename(filename);

        if UTTYPE_EXEMPT_ROWS.iter().any(|(f, _)| *f == filename) {
            exempt_hit += 1;
            assert!(
                got.is_none(),
                "{filename:?} is listed as a UTType exemption but the pure half \
                 now classifies it as {got:?} — remove the entry (and check the \
                 answer matches Swift's {want:?})"
            );
            continue;
        }

        report.eq(filename, Some(want), got.map(|t| t.as_str().to_string()));
    }

    assert_eq!(rows, 52, "the artifact_infer_type corpus changed size");
    assert_eq!(
        exempt_hit,
        UTTYPE_EXEMPT_ROWS.len(),
        "a listed UTType exemption is no longer in the corpus — the platform \
         carve-out must shrink with it, never stay wide"
    );
    report.assert_empty("inferArtifactType (pure half)", 43);
}

/// The exemption boundary, stated from the other side: `None` is not `General`.
/// Collapsing them would type every figure a researcher drops in as a generic
/// file, and every corpus row would still pass, because Swift's answer for the
/// `.pdf` rows happens to BE `.general`.
#[test]
fn undecided_rows_are_none_and_general_is_never_returned() {
    use imbib_core::pdf::infer_artifact_type_from_filename;

    for (filename, _) in UTTYPE_EXEMPT_ROWS {
        assert_eq!(
            infer_artifact_type_from_filename(filename),
            None,
            "{filename} should be undecided in the pure half"
        );
    }

    // Nothing the pure half decides is ever `General`; that verdict belongs to
    // the platform tail alone.
    for case in golden("artifact_infer_type.json") {
        let got = infer_artifact_type_from_filename(s(&case["filename"]));
        assert_ne!(
            got.map(|t| t.as_str()),
            Some("impress/artifact/general"),
            "{:?}: the pure half must never answer General",
            s(&case["filename"])
        );
    }
}
