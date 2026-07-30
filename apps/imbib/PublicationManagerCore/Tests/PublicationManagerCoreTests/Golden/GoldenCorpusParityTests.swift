//
//  GoldenCorpusParityTests.swift
//  PublicationManagerCoreTests
//
//  Stage 7 items 1–3: the FFI-backed parsers must reproduce, through the real
//  call sites, exactly what the deleted Swift implementations produced.
//
//  The goldens in crates/imbib-core/test_fixtures/golden/ were captured from
//  the Swift `IdentifierExtractor`, `BibTeXParser` and `RISParser` before those
//  files were removed. `crates/imbib-core/tests/golden_parity.rs` asserts the
//  same corpus at the Rust level; this suite asserts it at the boundary the app
//  actually uses, so a bridge-level regression (a lost field, a dropped
//  `@comment`, a stale xcframework) fails here.
//

import Foundation
import Testing
@testable import PublicationManagerCore

@Suite("Golden corpus parity (FFI-backed)")
struct GoldenCorpusParityTests {

    // MARK: - Loading

    static var goldenDir: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url = url.deletingLastPathComponent() }
        return url.appendingPathComponent("crates/imbib-core/test_fixtures/golden")
    }

    static func golden(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: goldenDir.appendingPathComponent(name))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    static func corpusFile(_ name: String) throws -> String {
        let url = goldenDir
            .deletingLastPathComponent()
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// RIS inputs where the Rust parser is deliberately more permissive.
    ///
    /// `TY - JOUR` (one space before the dash) is emitted by several reference
    /// managers; the Swift regex demanded exactly two, so those files imported
    /// as zero entries. Rust accepts them, which is a strict gain.
    static let risKnownDivergences: Set<String> = ["inline/one-space-separator"]

    // MARK: - Item 1: identifiers

    @Test("Text scanners reproduce the Swift goldens")
    func identifierTextScanners() throws {
        let g = try Self.golden("identifiers_golden.json")
        let cases = try #require(g["textCases"] as? [[String: Any]])
        #expect(cases.count == 29)

        for testCase in cases {
            let input = try #require(testCase["input"] as? String)
            #expect(
                IdentifierExtractor.extractDOIFromText(input) == testCase["doi"] as? String,
                "doi mismatch for \(input)"
            )
            #expect(
                IdentifierExtractor.extractArXivFromText(input) == testCase["arxiv"] as? String,
                "arxiv mismatch for \(input)"
            )
            #expect(
                IdentifierExtractor.extractBibcodeFromText(input) == testCase["bibcode"] as? String,
                "bibcode mismatch for \(input)"
            )
            #expect(
                IdentifierExtractor.extractPMIDFromText(input) == testCase["pmid"] as? String,
                "pmid mismatch for \(input)"
            )
        }
    }

    @Test("arXiv normalization reproduces the Swift goldens")
    func arxivNormalization() throws {
        let g = try Self.golden("identifiers_golden.json")
        let cases = try #require(g["normalizeCases"] as? [[String: Any]])

        for testCase in cases {
            let input = try #require(testCase["input"] as? String)
            #expect(
                IdentifierExtractor.normalizeArXivID(input) == testCase["normalized"] as? String,
                "normalize mismatch for \(input)"
            )
            #expect(
                IdentifierExtractor.isValidArXivIDFormat(input)
                    == testCase["isValidFormat"] as? Bool,
                "isValidFormat mismatch for \(input)"
            )
        }
    }

    @Test("Field extraction reproduces the Swift goldens")
    func identifierFieldExtraction() throws {
        let g = try Self.golden("identifiers_golden.json")
        let cases = try #require(g["fieldCases"] as? [[String: Any]])

        for testCase in cases {
            let fields = try #require(testCase["fields"] as? [String: String])
            #expect(
                IdentifierExtractor.arxivID(from: fields) == testCase["arxiv"] as? String,
                "arxiv mismatch for \(fields)"
            )
            #expect(
                IdentifierExtractor.doi(from: fields) == testCase["doi"] as? String,
                "doi mismatch for \(fields)"
            )
            #expect(
                IdentifierExtractor.bibcode(from: fields) == testCase["bibcode"] as? String,
                "bibcode mismatch for \(fields)"
            )
            #expect(
                IdentifierExtractor.pmid(from: fields) == testCase["pmid"] as? String,
                "pmid mismatch for \(fields)"
            )
            #expect(
                IdentifierExtractor.pmcid(from: fields) == testCase["pmcid"] as? String,
                "pmcid mismatch for \(fields)"
            )

            let expectedAll = try #require(testCase["all"] as? [String: String])
            var actualAll: [String: String] = [:]
            for (type, value) in IdentifierExtractor.allIdentifiers(from: fields) {
                actualAll[type.rawValue] = value
            }
            #expect(actualAll == expectedAll, "allIdentifiers mismatch for \(fields)")
        }
    }

    @Test("ADS URL bibcode extraction reproduces the Swift goldens")
    func adsURLBibcodes() throws {
        let g = try Self.golden("identifiers_golden.json")
        let cases = try #require(g["adsURLCases"] as? [[String: Any]])

        for testCase in cases {
            let input = try #require(testCase["input"] as? String)
            #expect(
                input.extractingBibcode() == testCase["bibcode"] as? String,
                "bibcode mismatch for \(input)"
            )
        }
    }

    // MARK: - Item 2: BibTeX

    @Test("BibTeX parsing reproduces the Swift goldens")
    func bibtexParsing() throws {
        let g = try Self.golden("bibtex_golden.json")
        let files = try #require(g["files"] as? [[String: Any]])
        #expect(files.count == 34)

        let parser = BibTeXParserFactory.createParser()

        for expected in files {
            let name = try #require(expected["name"] as? String)
            let content = try (expected["content"] as? String) ?? Self.corpusFile(name)
            let actual = GoldenCorpus.encodeBibTeX(name: name, content: content, parser: parser)

            let wantEntries = try #require(expected["entries"] as? [[String: Any]])
            let gotEntries = try #require(actual["entries"] as? [[String: Any]])
            #expect(gotEntries.count == wantEntries.count, "entry count for \(name)")
            guard gotEntries.count == wantEntries.count else { continue }

            for (want, got) in zip(wantEntries, gotEntries) {
                let key = want["citeKey"] as? String ?? "?"
                #expect(got["citeKey"] as? String == key, "citeKey in \(name)")
                #expect(
                    got["entryType"] as? String == want["entryType"] as? String,
                    "entryType of \(key) in \(name)"
                )
                let wantFields = want["fields"] as? [String: String] ?? [:]
                let gotFields = got["fields"] as? [String: String] ?? [:]
                #expect(gotFields == wantFields, "fields of \(key) in \(name)")
            }

            // Documented divergence: the Swift parser LaTeX-decoded `@string`
            // and `@preamble` bodies as it read them, so re-emitting them wrote
            // back invalid BibTeX — `Astronomy \& Astrophysics` came out as a
            // bare `&`, and `\newcommand{\noopsort}[1]{}` collapsed to
            // `\noopsort[1]`. The Rust parser keeps them verbatim; decoding is
            // applied here to prove the *only* difference is that step.
            let decodedMacros = (actual["macros"] as? [[String: String]] ?? []).map {
                ["name": $0["name"] ?? "", "value": ImbibRustCore.decodeLatex(input: $0["value"] ?? "")]
            }
            #expect(
                decodedMacros == (expected["macros"] as? [[String: String]]),
                "string macros for \(name)"
            )
            let decodedPreambles = (actual["preambles"] as? [String] ?? [])
                .map { ImbibRustCore.decodeLatex(input: $0) }
            #expect(
                decodedPreambles == (expected["preambles"] as? [String]),
                "preambles for \(name)"
            )
            #expect(
                (actual["comments"] as? [String]) == (expected["comments"] as? [String]),
                "comments for \(name)"
            )
            #expect(actual["error"] is NSNull, "unexpected parse error for \(name)")
        }
    }

    // MARK: - Item 3: RIS

    @Test("RIS parsing reproduces the Swift goldens")
    func risParsing() throws {
        let g = try Self.golden("ris_golden.json")
        let files = try #require(g["files"] as? [[String: Any]])
        #expect(files.count == 20)

        let parser = RISParserFactory.createParser()

        for expected in files {
            let name = try #require(expected["name"] as? String)
            guard !Self.risKnownDivergences.contains(name) else { continue }

            let content = try (expected["content"] as? String) ?? Self.corpusFile(name)
            let actual = GoldenCorpus.encodeRIS(name: name, content: content, parser: parser)

            let wantEntries = try #require(expected["entries"] as? [[String: Any]])
            let gotEntries = try #require(actual["entries"] as? [[String: Any]])
            #expect(gotEntries.count == wantEntries.count, "entry count for \(name)")
            guard gotEntries.count == wantEntries.count else { continue }

            for (index, (want, got)) in zip(wantEntries, gotEntries).enumerated() {
                #expect(
                    got["type"] as? String == want["type"] as? String,
                    "type of entry \(index) in \(name)"
                )
                let wantTags = want["tags"] as? [[String]] ?? []
                let gotTags = got["tags"] as? [[String]] ?? []
                #expect(gotTags == wantTags, "tags of entry \(index) in \(name)")
            }
        }
    }
}
