//
//  GoldenCorpus.swift
//  PublicationManagerCoreTests
//
//  Shared corpus + encoders for the Stage 7 Swift -> Rust parser port.
//
//  The *inputs* live here; the *expected outputs* live in
//  crates/imbib-core/test_fixtures/golden/*.json and were captured from the
//  Swift implementations before they were deleted (see git history for
//  SwiftGoldenCorpusCapture.swift).
//
//  Two consumers assert against those goldens:
//    - Rust:  crates/imbib-core/tests/golden_parity.rs
//    - Swift: GoldenCorpusParityTests.swift (FFI-backed path)
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
