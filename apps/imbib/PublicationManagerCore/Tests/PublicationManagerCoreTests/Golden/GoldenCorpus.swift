//
//  GoldenCorpus.swift
//  PublicationManagerCoreTests
//
//  Shared corpus + encoders for the Stage 7 Swift -> Rust parser port.
//
//  The *inputs* live here; the *expected outputs* live in
//  crates/imbib-core/test_fixtures/golden/*.json (items 1–5, 7) and
//  crates/imprint-core/test_fixtures/golden/ (item 6, section extraction), and
//  were captured from the Swift implementations before those bodies were
//  replaced or deleted (see git history for SwiftGoldenCorpusCapture.swift).
//
//  Two consumers assert against those goldens:
//    - Rust:  crates/imbib-core/tests/golden_parity.rs
//             crates/imprint-core/tests/golden_parity.rs
//    - Swift: GoldenCorpusParityTests.swift (FFI-backed path)
//
//  Wave 2 (items 4–7) covers: the `DocumentFormat` grammar table + detection,
//  `DeduplicationService` groupings, `SectionExtractor` output and section-id
//  derivation, and the ⌘F hybrid ranking.
//

import Foundation
@testable import PublicationManagerCore

enum GoldenCorpus {

    // MARK: - Item 1: identifier corpus

    static let identifierTexts: [String] = [
        "Check out this paper: 10.1038/nature12373 for details",
        "doi:10.1126/science.1234567",
        "DOI: 10.1126/science.1234567",
        "See https://doi.org/10.1038/nature12373 for details",
        "See http://dx.doi.org/10.1038/nature12373.",
        "Reference (10.1051/0004-6361/202348170) in parentheses",
        "Trailing period 10.1000/182. End of sentence",
        "Bracketed [10.1000/182] citation",
        "arXiv:2401.12345",
        "Preprint 2401.12345v2 available now",
        "Classic paper: astro-ph/0612345",
        "Old with version hep-th/9901001v1",
        "https://arxiv.org/abs/2301.12345",
        "arXiv DOI form 10.48550/arXiv.2401.12345",
        "Subject class math.CO/0309136 from 2003",
        "Bibcode 2023ApJ...123..456A in a sentence",
        "ADS record 1996ApJ...468...28K here",
        "A&A bibcode 2024A&A...686A.276A appears",
        "PMID: 12345678",
        "PubMed ID: 23456789",
        "PubMed 34567890",
        "https://pubmed.ncbi.nlm.nih.gov/12345678",
        "Everything at once: doi:10.1038/nature12373 arXiv:2401.12345 "
            + "bibcode 2023ApJ...123..456A PMID: 12345678",
        "Nothing to see here at all.",
        "",
        "Unicode: Müller & Ångström discuss 10.1038/nature12373 (2024)",
        "Multiple DOIs 10.1000/aaa and 10.2000/bbb",
        "URL-ish 10.1234/abc-def_ghi:jkl(mno)",
        "Line\nbreak\n10.1038/nature12373\nafter",
    ]

    static let arxivIDs: [String] = [
        "2401.12345",
        "2401.12345v2",
        "arXiv:2401.12345",
        "arXiv:2401.12345v3",
        "ARXIV:2401.12345",
        "  2401.12345  ",
        "astro-ph/0612345",
        "hep-th/9901001v1",
        "ASTRO-PH/0612345",
        "math.CO/0309136",
        "math.co/0309136",
        "cond-mat/9901001",
        "2401.1234",
        "2401.123",
        "1234.567890",
        "10.48550/arXiv.2401.12345",
        "2024A&A...686A.276A",
        "not-an-id",
        "",
        "v2",
        "2401.12345vv2",
    ]

    static let identifierFields: [[String: String]] = [
        [:],
        ["eprint": "2401.12345"],
        ["eprint": "2401.12345v2"],
        ["eprint": "arXiv:2401.12345"],
        ["eprint": "astro-ph/9412070"],
        ["eprint": "arXiv:hep-th/9901001"],
        ["eprint": "2024A&A...686A.276A"],
        ["eprint": "10.1038/nature12373"],
        ["eprint": "10.48550/arXiv.2401.12345"],
        ["eprint": "10.48550/arXiv.not-an-id"],
        ["eprint": "", "arxivid": "2401.12345"],
        ["arxivid": "arXiv:2401.12345v2"],
        ["arxiv": "1905.07890"],
        ["eprint": "junk", "arxivid": "also junk", "arxiv": "2401.12345"],
        ["doi": "10.1038/nature12373"],
        ["doi": "10.1038/nature12373", "eprint": "2401.12345", "bibcode": "2023ApJ...123..456A"],
        ["pmid": "12345678", "pmcid": "PMC1234567"],
        ["bibcode": "2023ApJ...123..456A"],
        ["adsurl": "https://ui.adsabs.harvard.edu/abs/2023ApJ...123..456A/abstract"],
        ["adsurl": "https://adsabs.harvard.edu/abs/1996ApJ...468...28K"],
        ["adsurl": "https://example.org/abs/2023ApJ...123..456A"],
        ["bibcode": "2023ApJ...123..456A", "adsurl": "https://ui.adsabs.harvard.edu/abs/1996ApJ...468...28K"],
        [
            "doi": "10.1038/nature12373",
            "eprint": "2401.12345",
            "bibcode": "2023ApJ...123..456A",
            "pmid": "12345678",
            "pmcid": "PMC1234567",
        ],
    ]

    static let adsURLs: [String] = [
        "https://ui.adsabs.harvard.edu/abs/2023ApJ...123..456A/abstract",
        "https://adsabs.harvard.edu/abs/1996ApJ...468...28K",
        "https://ui.adsabs.harvard.edu/abs/2024A&A...686A.276A/abstract",
        "http://adsabs.harvard.edu/abs/1996ApJ...468...28K",
        "https://example.org/abs/2023ApJ...123..456A",
        "https://ui.adsabs.harvard.edu/",
        "https://ui.adsabs.harvard.edu/abs/",
        "not a url",
        "",
    ]

    // MARK: - Item 2: BibTeX corpus

    static let bibtexFixtures: [String] = [
        "bibtex/simple.bib",
        "bibtex/ads_style.bib",
        "bibtex/latex_chars.bib",
        "bibtex/nested_braces.bib",
        "bibtex/string_macros.bib",
        "bibtex/thesis_ref.bib",
        "golden/bibtex/adversarial.bib",
    ]

    static let inlineBibTeX: [(String, String)] = [
        ("inline/empty", ""),
        ("inline/whitespace", "   \n\n  \t\n"),
        (
            "inline/minimal",
            "@article{key, title = {T}}"
        ),
        (
            "inline/no-trailing-newline",
            "@misc{k, note = {n}}"
        ),
        (
            "inline/leading-junk",
            "This is free text before the first entry.\n@article{k2, title = {T2}}"
        ),
        (
            "inline/percent-comment",
            "% a comment line\n@article{k3, title = {T3}}"
        ),
        (
            "inline/uppercase-fields",
            "@ARTICLE{K4, TITLE = {T4}, Author = {A4}, YeAr = {2024}}"
        ),
        (
            "inline/field-name-with-dash",
            "@misc{k5, Bdsk-File-1 = {AAA}, date-added = {2020-01-01}}"
        ),
        (
            "inline/quoted-escape",
            "@article{k6, title = \"Testing \\\"Quotes\\\" inside\"}"
        ),
        (
            "inline/nested-quotes-braces",
            "@article{k7, title = \"{Outer {inner} brace} tail\"}"
        ),
        (
            "inline/crossref-chain",
            """
            @proceedings{parent, title = {Parent Proc}, year = {2019}, publisher = {ACM}}
            @inproceedings{child, author = {C}, crossref = {parent}, title = {Child}}
            """
        ),
        (
            "inline/crossref-case-insensitive",
            """
            @proceedings{PARENT, title = {Parent Proc}, year = {2019}}
            @inproceedings{child2, crossref = {parent}, title = {Child2}}
            """
        ),
        (
            "inline/crossref-missing",
            "@inproceedings{orphan, crossref = {nope}, title = {Orphan}}"
        ),
        (
            "inline/string-macro-usage",
            """
            @string{jn = "The Journal"}
            @article{k8, journal = jn, month = jan}
            """
        ),
        (
            "inline/month-macro",
            "@article{k9, month = sep, year = 1996}"
        ),
        (
            "inline/concatenation",
            """
            @string{a = "Alpha"}
            @string{b = "Beta"}
            @article{k10, title = a # " and " # b}
            """
        ),
        (
            "inline/duplicate-fields",
            "@article{k11, title = {First}, title = {Second}}"
        ),
        (
            "inline/entry-no-fields",
            "@misc{lonely}"
        ),
        (
            "inline/preamble",
            "@preamble{\"\\newcommand{\\x}{y}\"}\n@article{k12, title = {T}}"
        ),
        (
            "inline/comment-braced",
            "@comment{ignored content}\n@article{k13, title = {T}}"
        ),
        (
            "inline/latex-escapes",
            "@article{k14, title = {50\\% of caf{\\'e}s, {\\\"u}ber \\{braced\\}}}"
        ),
        (
            "inline/backslash-brace-pair",
            "@article{k15, note = {double \\\\{ and \\\\} here}}"
        ),
        (
            "inline/unicode-direct",
            "@article{k16, author = {Müller, Jörg}, title = {Ångström 日本語 α β γ}}"
        ),
        (
            "inline/ampersand-citekey",
            "@ARTICLE{2024A&A...686A.276A, title = {Amp}, year = 2024}"
        ),
        (
            "inline/numeric-value",
            "@article{k17, year = 2024, volume = 42}"
        ),
        (
            "inline/bare-word-value",
            "@article{k18, edition = second}"
        ),
        (
            "inline/many-blank-lines",
            "@article{k19, title = {A}}\n\n\n\n@article{k20, title = {B}}\n"
        ),
    ]

    // MARK: - Item 3: RIS corpus

    static let risFixtures: [String] = [
        "ris/sample.ris",
        "ris/all_types.ris",
        "ris/multiple_authors.ris",
        "golden/ris/adversarial.ris",
    ]

    static let inlineRIS: [(String, String)] = [
        ("inline/minimal", "TY  - JOUR\nTI  - Title\nER  -"),
        ("inline/no-er", "TY  - JOUR\nTI  - Title"),
        ("inline/two-entries", "TY  - JOUR\nTI  - A\nER  -\nTY  - BOOK\nTI  - B\nER  -"),
        ("inline/blank-lines-between", "TY  - JOUR\nTI  - A\nER  -\n\n\nTY  - BOOK\nTI  - B\nER  -"),
        ("inline/continuation", "TY  - JOUR\nAB  - line one\nline two\nline three\nER  -"),
        ("inline/repeated-tags", "TY  - JOUR\nAU  - A, One\nAU  - B, Two\nKW  - k1\nKW  - k2\nER  -"),
        ("inline/unknown-tag", "TY  - JOUR\nXQ  - mystery\nTI  - T\nER  -"),
        ("inline/unknown-type", "TY  - ZZZZ\nTI  - T\nER  -"),
        ("inline/one-space-separator", "TY - JOUR\nTI - T\nER - "),
        ("inline/no-space-after-dash", "TY  -JOUR\nTI  -T\nER  -"),
        ("inline/leading-junk", "some junk header\nTY  - JOUR\nTI  - T\nER  -"),
        ("inline/er-without-ty", "ER  -\nTY  - JOUR\nTI  - T\nER  -"),
        ("inline/numeric-tag", "TY  - JOUR\nA1  - Author One\nT1  - Primary\nER  -"),
        ("inline/trailing-spaces", "TY  - JOUR  \nTI  - Title   \nER  -  "),
        ("inline/crlf", "TY  - JOUR\r\nTI  - Title\r\nER  -\r\n"),
        ("inline/unicode", "TY  - JOUR\nTI  - Ångström & Müller α\nER  -"),
    ]

    // MARK: - Item 4: DocumentFormat grammar corpus

    /// `(source, title)` pairs for `DocumentFormat.detect(from:title:)`.
    ///
    /// Covers each branch of the heuristic: the title-extension shortcut (and
    /// its unknown-extension and empty-extension fall-throughs), the two LaTeX
    /// preamble markers, every Markdown marker, the Typst `#`-code-mode
    /// near-miss that made an ADR compile as Typst, and the 200-line scan limit.
    static let formatDetectCases: [(source: String, title: String?)] = [
        ("", nil),
        ("   \n\n \t ", nil),
        ("", "ADR-0011.md"),
        ("", "notes.txt"),
        ("", "paper.tex"),
        ("", "paper.latex"),
        ("", "paper.typ"),
        ("", "readme.MARKDOWN"),
        ("", "notes.TEXT"),
        ("", "notes.mdown"),
        ("", "archive.tar.gz"),
        ("", "trailing."),
        ("", ".hidden"),
        ("", "no-extension-at-all"),
        ("", "ADR-0011: The impress Journal"),
        ("\\documentclass{article}\n\\begin{document}\nhi\n\\end{document}", nil),
        ("\\begin{document}\ntext\n\\end{document}", nil),
        ("\\documentclass{article}", "notes.md"),
        ("# ADR-0011\n\n## Status\nAccepted\n", nil),
        ("#import \"@preview/cetz:0.2.0\"\n#set page(margin: 2cm)\n\n= Intro\n", nil),
        ("####### seven hashes\n", nil),
        ("###### six hashes\n", nil),
        ("#nospace\n", nil),
        ("Intro paragraph\n\n```swift\nlet x = 1\n```\n", nil),
        ("~~~\ncode fence\n~~~\n", nil),
        ("   \t# indented heading\n", nil),
        ("= Typst heading\nbody\n", nil),
        (String(repeating: "body\n", count: 250) + "# late markdown heading\n", nil),
        ("# CRLF heading\r\nbody\r\n", nil),
        ("prose\n\n#import x\n", nil),
    ]

    /// Bare extensions for `DocumentFormat.detect(fromExtension:)`.
    static let formatExtensionCases: [String] = [
        "typ", "TYP", "tex", "TeX", "latex", "md", "MD", "markdown", "mdown",
        "txt", "text", "TEXT", "rs", "docx", "", " ", "typ ",
    ]

    // MARK: - Item 5: deduplication corpus

    /// A dedup scenario: a name plus the results fed to
    /// `DeduplicationService.deduplicate(_:)`.
    struct DedupScenario {
        let name: String
        let results: [SearchResult]
    }

    static func result(
        _ id: String,
        _ source: String,
        _ title: String,
        authors: [String] = ["Smith, John"],
        year: Int? = 2024,
        doi: String? = nil,
        arxiv: String? = nil,
        pmid: String? = nil,
        bibcode: String? = nil,
        semanticScholar: String? = nil,
        openAlex: String? = nil
    ) -> SearchResult {
        SearchResult(
            id: id,
            sourceID: source,
            title: title,
            authors: authors,
            year: year,
            doi: doi,
            arxivID: arxiv,
            pmid: pmid,
            bibcode: bibcode,
            semanticScholarID: semanticScholar,
            openAlexID: openAlex
        )
    }

    static var dedupScenarios: [DedupScenario] {
        [
            DedupScenario(name: "empty", results: []),
            DedupScenario(
                name: "single-source-fast-path",
                results: [
                    result("a", "arxiv", "Same Paper", doi: "10.1/x"),
                    result("b", "arxiv", "Same Paper", doi: "10.1/x"),
                    result("c", "arxiv", "Other Paper", doi: "10.1/y"),
                ]
            ),
            DedupScenario(
                name: "doi-match-priority-order",
                results: [
                    result("a", "arxiv", "Paper", doi: "10.1/x"),
                    result("b", "crossref", "Paper", doi: "10.1/x"),
                    result("c", "ads", "Different", doi: "10.2/y"),
                ]
            ),
            DedupScenario(
                name: "doi-normalization",
                results: [
                    result("a", "crossref", "Paper", doi: "10.1234/TEST"),
                    result("b", "arxiv", "Paper", doi: "https://doi.org/10.1234/test"),
                    result("c", "ads", "Paper", doi: "doi:10.1234/test"),
                    result("d", "pubmed", "Paper", doi: "http://doi.org/10.1234/test"),
                ]
            ),
            DedupScenario(
                name: "transitive-through-two-identifiers",
                results: [
                    result("a", "crossref", "Paper", doi: "10.1/x"),
                    result("b", "ads", "Paper", doi: "10.1/x", arxiv: "2301.00001"),
                    result("c", "arxiv", "Paper", arxiv: "2301.00001"),
                ]
            ),
            DedupScenario(
                name: "split-identifier-joins-doi-group",
                results: [
                    result("a", "crossref", "One", doi: "10.1/x"),
                    result("b", "arxiv", "Two", arxiv: "2301.00002"),
                    result("c", "ads", "One", doi: "10.1/x", arxiv: "2301.00002"),
                ]
            ),
            DedupScenario(
                name: "arxiv-version-suffix",
                results: [
                    result("a", "arxiv", "Paper", arxiv: "2301.12345v2"),
                    result("b", "semanticscholar", "Paper", arxiv: "2301.12345"),
                    result("c", "openalex", "Paper", arxiv: "2301.12345v11"),
                ]
            ),
            DedupScenario(
                name: "arxiv-prefixed-form",
                results: [
                    result("a", "arxiv", "Paper", arxiv: "arXiv:2301.99999"),
                    result("b", "crossref", "Paper", arxiv: "2301.99999"),
                ]
            ),
            DedupScenario(
                name: "pmid-and-bibcode",
                results: [
                    result("a", "pubmed", "Paper", pmid: "12345678"),
                    result("b", "crossref", "Paper", pmid: "12345678"),
                    result("c", "ads", "Astro", bibcode: "2023ApJ...123..456A"),
                    result("d", "openalex", "Astro", bibcode: "2023ApJ...123..456A"),
                ]
            ),
            DedupScenario(
                name: "no-identifiers-identical-metadata",
                results: [
                    result("a", "crossref", "Machine Learning for Everyone"),
                    result("b", "arxiv", "Machine Learning for Everyone"),
                ]
            ),
            DedupScenario(
                name: "unknown-sources",
                results: [
                    result("a", "zzz-unknown", "Paper", doi: "10.1/x"),
                    result("b", "another-unknown", "Paper", doi: "10.1/x"),
                    result("c", "dblp", "Paper", doi: "10.1/x"),
                ]
            ),
            DedupScenario(
                name: "aggregator-identifiers-are-carried",
                results: [
                    result("a", "crossref", "Paper", doi: "10.1/x", semanticScholar: "s2:123"),
                    result("b", "openalex", "Paper", doi: "10.1/x", openAlex: "W123"),
                ]
            ),
            DedupScenario(
                name: "every-source-once",
                results: [
                    result("dblp", "dblp", "Paper", doi: "10.1/x"),
                    result("arxiv", "arxiv", "Paper", doi: "10.1/x"),
                    result("openalex", "openalex", "Paper", doi: "10.1/x"),
                    result("s2", "semanticscholar", "Paper", doi: "10.1/x"),
                    result("ads", "ads", "Paper", doi: "10.1/x"),
                    result("pubmed", "pubmed", "Paper", doi: "10.1/x"),
                    result("crossref", "crossref", "Paper", doi: "10.1/x"),
                ]
            ),
        ]
    }

    // MARK: - Item 6: section extraction corpus

    /// Fixture documents under `crates/imprint-core/test_fixtures/golden/`.
    /// `format` of `nil` means "let the extractor auto-detect".
    static let sectionFixtures: [(name: String, format: String?)] = [
        ("sections/paper.typ", nil),
        ("sections/paper.typ", "typst"),
        ("sections/paper.tex", nil),
        ("sections/paper.tex", "latex"),
        ("sections/paper.tex", "typst"),
        ("sections/unicode.typ", nil),
        ("sections/flat.typ", nil),
        ("sections/crlf.typ", nil),
        ("sections/adversarial.typ", nil),
        ("sections/adversarial.typ", "latex"),
    ]

    /// The document id every section fixture is extracted against — fixed so
    /// the captured ids are reproducible.
    static let sectionDocumentID = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!

    /// `(documentID, title, orderIndex)` triples for the id derivation alone.
    /// These pin the *persisted* id shape independently of the heading scanner.
    static let sectionIDCases: [(doc: String, title: String, index: Int)] = [
        ("550E8400-E29B-41D4-A716-446655440000", "Introduction", 0),
        ("550E8400-E29B-41D4-A716-446655440000", "Introduction", 1),
        ("550E8400-E29B-41D4-A716-446655440000", "introduction", 0),
        ("550E8400-E29B-41D4-A716-446655440000", "  Introduction  ", 0),
        ("550E8400-E29B-41D4-A716-446655440000", "INTRODUCTION", 0),
        ("550E8400-E29B-41D4-A716-446655440000", "", 0),
        ("550E8400-E29B-41D4-A716-446655440000", "Résumé", 2),
        ("550E8400-E29B-41D4-A716-446655440000", "A Title With {Braces}", 3),
        ("00000000-0000-0000-0000-000000000000", "Introduction", 0),
        ("6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "Methods", 7),
    ]

    // MARK: - Item 7: hybrid search ranking corpus

    /// One publication as the three retrieval engines reported it. `nil` means
    /// "that engine did not return this publication" — load-bearing, since it
    /// decides the match type and whether the field boosts apply.
    struct RankingCandidate {
        let id: String
        let citeKey: String
        let title: String
        let authors: String
        let ftsScore: Float?
        let semanticSimilarity: Float?
        let chunkSimilarity: Float?
    }

    struct RankingScenario {
        let name: String
        let query: String
        let candidates: [RankingCandidate]
    }

    private static func candidate(
        _ id: String,
        citeKey: String = "",
        title: String = "",
        authors: String = "",
        fts: Float? = nil,
        semantic: Float? = nil,
        chunk: Float? = nil
    ) -> RankingCandidate {
        RankingCandidate(
            id: id,
            citeKey: citeKey,
            title: title,
            authors: authors,
            ftsScore: fts,
            semanticSimilarity: semantic,
            chunkSimilarity: chunk
        )
    }

    static var rankingScenarios: [RankingScenario] {
        [
            RankingScenario(name: "empty", query: "kaiser", candidates: []),
            RankingScenario(
                name: "fts-beats-semantic",
                query: "kaiser",
                candidates: [
                    candidate("00000000-0000-0000-0000-000000000002", semantic: 1.0),
                    candidate("00000000-0000-0000-0000-000000000001", fts: 0.001),
                ]
            ),
            RankingScenario(
                name: "all-field-boosts",
                query: "Kaiser",
                candidates: [
                    candidate(
                        "00000000-0000-0000-0000-00000000000a",
                        citeKey: "kaiser1984",
                        title: "The KAISER effect",
                        authors: "Kaiser, Nick",
                        fts: 0.0
                    ),
                    candidate(
                        "00000000-0000-0000-0000-00000000000b",
                        citeKey: "bbks1986",
                        title: "The statistics of peaks",
                        authors: "Bardeen, J.; Bond, J. R.; Kaiser, N.; Szalay, A.",
                        fts: 0.0
                    ),
                    candidate(
                        "00000000-0000-0000-0000-00000000000c",
                        citeKey: "other1990",
                        title: "Something else",
                        authors: "Nobody",
                        fts: 5.0
                    ),
                ]
            ),
            RankingScenario(
                name: "chunk-between-semantic-and-fts",
                query: "structure formation",
                candidates: [
                    candidate("00000000-0000-0000-0000-000000000011", fts: 1.0),
                    candidate("00000000-0000-0000-0000-000000000012", chunk: 0.9),
                    candidate("00000000-0000-0000-0000-000000000013", semantic: 0.99),
                    candidate("00000000-0000-0000-0000-000000000014", chunk: 0.36),
                ]
            ),
            RankingScenario(
                name: "combined-engines",
                query: "peaks",
                candidates: [
                    candidate(
                        "00000000-0000-0000-0000-000000000021",
                        title: "Statistics of peaks",
                        fts: 2.0,
                        semantic: 0.5,
                        chunk: 0.4
                    ),
                    candidate("00000000-0000-0000-0000-000000000022", fts: 2.0, chunk: 0.4),
                    candidate("00000000-0000-0000-0000-000000000023", semantic: 0.5, chunk: 0.4),
                    candidate("00000000-0000-0000-0000-000000000024", semantic: 0.5),
                ]
            ),
            RankingScenario(
                name: "exact-ties-need-a-tie-break",
                query: "zzz-no-match",
                candidates: [
                    candidate("ffffffff-ffff-ffff-ffff-ffffffffffff", fts: 1.0),
                    candidate("00000000-0000-0000-0000-000000000000", fts: 1.0),
                    candidate("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", fts: 1.0),
                    candidate("11111111-1111-1111-1111-111111111111", fts: 1.0),
                ]
            ),
            RankingScenario(
                name: "empty-query-earns-no-boosts",
                query: "",
                candidates: [
                    candidate(
                        "00000000-0000-0000-0000-000000000031",
                        citeKey: "anything",
                        title: "anything",
                        authors: "anything",
                        fts: 2.0
                    ),
                ]
            ),
            RankingScenario(
                name: "whitespace-query-earns-no-boosts",
                query: "   ",
                candidates: [
                    candidate(
                        "00000000-0000-0000-0000-000000000032",
                        citeKey: "a b",
                        title: "a b",
                        authors: "a b",
                        fts: 2.0
                    ),
                ]
            ),
            RankingScenario(
                name: "unicode-case-folding",
                query: "MÜLLER",
                candidates: [
                    candidate(
                        "00000000-0000-0000-0000-000000000041",
                        authors: "Müller, Jörg",
                        fts: 0.0
                    ),
                    candidate(
                        "00000000-0000-0000-0000-000000000042",
                        title: "Ångström and MÜLLER",
                        fts: 0.0
                    ),
                ]
            ),
            RankingScenario(
                name: "negative-and-large-fts-scores",
                query: "q",
                candidates: [
                    candidate("00000000-0000-0000-0000-000000000051", fts: -3.5),
                    candidate("00000000-0000-0000-0000-000000000052", fts: 1_000.25),
                    candidate("00000000-0000-0000-0000-000000000053", fts: 0.0),
                ]
            ),
        ]
    }

    // MARK: - Encoders

    /// Normalised, order-stable encoding of a Swift BibTeX parse.
    ///
    /// Entries keep source order (the round-trip promise depends on it);
    /// macros/preambles/comments are sorted because the Rust `strings` map is
    /// unordered across the FFI.
    static func encodeBibTeX(
        name: String,
        content: String,
        parser: any BibTeXParsing
    ) -> [String: Any] {
        var entries: [[String: Any]] = []
        var macros: [[String: String]] = []
        var preambles: [String] = []
        var comments: [String] = []
        var errorText: String?

        do {
            for item in try parser.parse(content) {
                switch item {
                case .entry(let entry):
                    entries.append([
                        "citeKey": entry.citeKey,
                        "entryType": entry.entryType,
                        "fields": entry.fields,
                    ])
                case .stringMacro(let macroName, let value):
                    macros.append(["name": macroName, "value": value])
                case .preamble(let value):
                    preambles.append(value)
                case .comment(let value):
                    comments.append(value)
                }
            }
        } catch {
            errorText = "\(error)"
        }

        macros.sort { ($0["name"] ?? "") < ($1["name"] ?? "") }
        preambles.sort()
        comments.sort()

        var record: [String: Any] = [
            "name": name,
            "entries": entries,
            "macros": macros,
            "preambles": preambles,
            "comments": comments,
            "error": errorText as Any? ?? NSNull(),
        ]
        // Fixture-backed cases are loaded from test_fixtures/<name>; inline
        // cases have to carry their input so the Rust side can replay them.
        if name.hasPrefix("inline/") {
            record["content"] = content
        }
        return record
    }

    /// Normalised encoding of a Swift RIS parse.
    static func encodeRIS(
        name: String,
        content: String,
        parser: any RISParsing
    ) -> [String: Any] {
        var entries: [[String: Any]] = []
        var errorText: String?
        do {
            for entry in try parser.parse(content) {
                entries.append([
                    "type": entry.type.rawValue,
                    "tags": entry.tags.map { [$0.tag.rawValue, $0.value] },
                ])
            }
        } catch {
            errorText = "\(error)"
        }
        var record: [String: Any] = [
            "name": name,
            "entries": entries,
            "error": errorText as Any? ?? NSNull(),
        ]
        if name.hasPrefix("inline/") {
            record["content"] = content
        }
        return record
    }
}
