//
//  GoldenCorpusParityTests.swift
//  PublicationManagerCoreTests
//
//  Stage 7 items 1–7: the FFI-backed implementations must reproduce, through the
//  real call sites, exactly what the Swift implementations they replaced did.
//
//  Items 1–3 are the parsers (identifiers, BibTeX, RIS). Items 4–7 are the
//  `DocumentFormat` grammar, `DeduplicationService`, `SectionExtractor` and the
//  ⌘F hybrid ranking.
//
//  The goldens in crates/imbib-core/test_fixtures/golden/ were captured from
//  the Swift `IdentifierExtractor`, `BibTeXParser` and `RISParser` before those
//  files were removed. `crates/imbib-core/tests/golden_parity.rs` asserts the
//  same corpus at the Rust level; this suite asserts it at the boundary the app
//  actually uses, so a bridge-level regression (a lost field, a dropped
//  `@comment`, a stale xcframework) fails here.
//

import Foundation
import ImpressRustCore
import Testing
@testable import PublicationManagerCore

@Suite("Golden corpus parity (FFI-backed)")
struct GoldenCorpusParityTests {

    // MARK: - Loading

    static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url = url.deletingLastPathComponent() }
        return url
    }

    static var goldenDir: URL {
        repoRoot.appendingPathComponent("crates/imbib-core/test_fixtures/golden")
    }

    /// Items 4, 5 and 7 keep their goldens next to wave 1's, in imbib-core.
    /// Item 6's live in imprint-core, which owns the section extractor.
    static var imprintGoldenDir: URL {
        repoRoot.appendingPathComponent("crates/imprint-core/test_fixtures/golden")
    }

    static func golden(_ name: String) throws -> [String: Any] {
        try golden(name, in: goldenDir)
    }

    static func golden(_ name: String, in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
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

    // MARK: - Item 4: DocumentFormat grammar

    @Test("The DocumentFormat grammar reproduces the Swift goldens")
    func documentFormatGrammar() throws {
        let g = try Self.golden("document_format_golden.json")
        let formats = try #require(g["formats"] as? [[String: Any]])
        #expect(formats.count == 4)

        func affixes(_ value: Any?) -> [String: String]? {
            (value as? [String: String])
        }
        func encode(_ pair: (prefix: String, suffix: String)?) -> [String: String]? {
            pair.map { ["prefix": $0.prefix, "suffix": $0.suffix] }
        }

        // Order matters: `allCases` order is what a format picker renders.
        for (expected, format) in zip(formats, DocumentFormat.allCases) {
            let id = try #require(expected["id"] as? String)
            #expect(id == format.rawValue, "format order changed")
            #expect(format.displayName == expected["displayName"] as? String, "displayName of \(id)")
            #expect(format.previewKind.rawValue == expected["previewKind"] as? String, "previewKind of \(id)")
            #expect(format.hasPreview == expected["hasPreview"] as? Bool, "hasPreview of \(id)")
            #expect(format.requiresCompile == expected["requiresCompile"] as? Bool, "requiresCompile of \(id)")
            #expect(format.fileExtension == expected["fileExtension"] as? String, "fileExtension of \(id)")
            #expect(format.mainFileName == expected["mainFileName"] as? String, "mainFileName of \(id)")
            #expect(format.commentPrefix == expected["commentPrefix"] as? String, "commentPrefix of \(id)")
            #expect(encode(format.citationInsert) == affixes(expected["citationInsert"]), "citationInsert of \(id)")
            #expect(encode(format.boldWrap) == affixes(expected["boldWrap"]), "boldWrap of \(id)")
            #expect(encode(format.italicWrap) == affixes(expected["italicWrap"]), "italicWrap of \(id)")
            #expect(format.defaultDebounceMs == expected["defaultDebounceMs"] as? Int, "defaultDebounceMs of \(id)")
        }
    }

    @Test("DocumentFormat detection reproduces the Swift goldens")
    func documentFormatDetection() throws {
        let g = try Self.golden("document_format_golden.json")

        let detectCases = try #require(g["detectCases"] as? [[String: Any]])
        #expect(detectCases.count == 30)
        for testCase in detectCases {
            let source = try #require(testCase["source"] as? String)
            let title = testCase["title"] as? String
            #expect(
                DocumentFormat.detect(from: source, title: title).rawValue
                    == testCase["format"] as? String,
                "detect(from: \(source.prefix(30).debugDescription), title: \(title ?? "nil"))"
            )
        }

        let extensionCases = try #require(g["extensionCases"] as? [[String: Any]])
        #expect(extensionCases.count == 17)
        for testCase in extensionCases {
            let ext = try #require(testCase["extension"] as? String)
            #expect(
                DocumentFormat.detect(fromExtension: ext)?.rawValue == testCase["format"] as? String,
                "detect(fromExtension: \(ext.debugDescription))"
            )
        }
    }

    // MARK: - Item 5: deduplication

    /// The one scenario where Rust deliberately disagrees: Swift's
    /// `normalizeArXiv` stripped only a trailing `v<n>`, so `arXiv:2301.99999`
    /// and `2301.99999` stayed two results. Rust also strips the scheme prefix
    /// and merges them, which is what the surface always wanted.
    static let dedupKnownDivergences: Set<String> = ["arxiv-prefixed-form"]

    @Test("Deduplication grouping reproduces the Swift goldens")
    func deduplicationGrouping() async throws {
        let g = try Self.golden("deduplication_golden.json")
        let scenarios = try #require(g["scenarios"] as? [[String: Any]])
        #expect(scenarios.count == 13)

        let service = DeduplicationService()
        let byName = Dictionary(
            uniqueKeysWithValues: GoldenCorpus.dedupScenarios.map { ($0.name, $0.results) }
        )

        for expected in scenarios {
            let name = try #require(expected["name"] as? String)
            guard !Self.dedupKnownDivergences.contains(name) else { continue }
            let results = try #require(byName[name], "corpus lost scenario \(name)")

            let groups = await service.deduplicate(results)
            let wantGroups = try #require(expected["groups"] as? [[String: Any]])
            #expect(groups.count == wantGroups.count, "group count for \(name)")
            guard groups.count == wantGroups.count else { continue }

            for (index, (want, got)) in zip(wantGroups, groups).enumerated() {
                #expect(got.primary.id == want["primary"] as? String, "group \(index) primary in \(name)")
                // Order, not just membership: the alternates are in source-priority
                // order, which a "also on arXiv, DBLP" row renders directly.
                #expect(
                    got.alternates.map(\.id) == want["alternates"] as? [String],
                    "group \(index) alternates in \(name)"
                )
                var gotIdentifiers: [String: String] = [:]
                for (type, value) in got.identifiers { gotIdentifiers[type.rawValue] = value }
                #expect(
                    gotIdentifiers == want["identifiers"] as? [String: String],
                    "group \(index) identifiers in \(name)"
                )
            }
        }
    }

    @Test("The source-priority table is the Rust one")
    func deduplicationSourcePriority() {
        #expect(
            DeduplicationService.sourcePriorities.map(\.sourceID)
                == ["crossref", "pubmed", "ads", "semanticscholar", "openalex", "arxiv", "dblp"]
        )
        #expect(DeduplicationService.sourcePriorities.map(\.priority) == [10, 20, 30, 40, 50, 60, 70])
        #expect(DeduplicationService.priority(forSource: "europepmc") == 100)
    }

    // MARK: - Item 6: section extraction

    @Test("Section extraction reproduces the Swift goldens")
    func sectionExtraction() throws {
        let g = try Self.golden("sections_golden.json", in: Self.imprintGoldenDir)
        let documents = try #require(g["documents"] as? [[String: Any]])
        #expect(documents.count == 10)

        for expected in documents {
            let name = try #require(expected["name"] as? String)
            let formatName = expected["format"] as? String
            let source = try String(
                contentsOf: Self.imprintGoldenDir.appendingPathComponent(name),
                encoding: .utf8
            )
            let format: SectionFormat? = formatName.map { $0 == "latex" ? .latex : .typst }
            let documentIDString = try #require(expected["documentID"] as? String)
            let documentID = try #require(UUID(uuidString: documentIDString))

            #expect(
                SectionFormat.autoDetect(source).rustName == expected["autoDetected"] as? String,
                "autoDetect of \(name)"
            )

            let sections = SectionExtractor.extract(
                from: source, documentID: documentID, format: format
            )
            let wantSections = try #require(expected["sections"] as? [[String: Any]])
            let scope = "\(name) format=\(formatName ?? "auto")"
            #expect(sections.count == wantSections.count, "section count for \(scope)")
            guard sections.count == wantSections.count else { continue }

            for (want, got) in zip(wantSections, sections) {
                let index = want["orderIndex"] as? Int ?? -1
                #expect(got.id.uuidString.lowercased() == want["id"] as? String, "id of \(index) in \(scope)")
                #expect(got.title == want["title"] as? String, "title of \(index) in \(scope)")
                #expect(got.level == want["level"] as? Int, "level of \(index) in \(scope)")
                #expect(got.start == want["start"] as? Int, "start of \(index) in \(scope)")
                #expect(got.end == want["end"] as? Int, "end of \(index) in \(scope)")
                #expect(got.bodyStart == want["bodyStart"] as? Int, "bodyStart of \(index) in \(scope)")
                #expect(got.orderIndex == index, "orderIndex of \(index) in \(scope)")
                #expect(got.sectionType == want["sectionType"] as? String, "sectionType of \(index) in \(scope)")
                #expect(got.wordCount == want["wordCount"] as? Int, "wordCount of \(index) in \(scope)")
            }
        }
    }

    @Test("Section id derivation reproduces the Swift goldens")
    func sectionIDDerivation() throws {
        // The narrow invariant a data migration depends on: these ids are
        // persisted as `manuscript-section` row ids, so a derivation change does
        // not error — it silently orphans every existing row.
        let g = try Self.golden("sections_golden.json", in: Self.imprintGoldenDir)
        let cases = try #require(g["idCases"] as? [[String: Any]])
        #expect(cases.count == 10)

        for testCase in cases {
            let documentIDString = try #require(testCase["documentID"] as? String)
            let documentID = try #require(UUID(uuidString: documentIDString))
            let title = try #require(testCase["title"] as? String)
            let index = try #require(testCase["orderIndex"] as? Int)
            #expect(
                SectionExtractor.sectionID(documentID: documentID, title: title, orderIndex: index)
                    .uuidString.lowercased() == testCase["id"] as? String,
                "id for \(title.debugDescription)@\(index)"
            )
        }
    }

    @Test("Section UTF-16 offsets address the same text as the Character offsets")
    func sectionUTF16Offsets() throws {
        // The `*UTF16` fields are new, so they have no golden. What they must
        // satisfy is that they address the SAME text — that is the property the
        // NSRange consumers (bracket ruler, prompt context, caret jump) rely on.
        let g = try Self.golden("sections_golden.json", in: Self.imprintGoldenDir)
        for document in try #require(g["documents"] as? [[String: Any]]) {
            let name = try #require(document["name"] as? String)
            let source = try String(
                contentsOf: Self.imprintGoldenDir.appendingPathComponent(name),
                encoding: .utf8
            )
            let characters = Array(source)
            let ns = source as NSString
            let format = (document["format"] as? String).map { $0 == "latex" ? SectionFormat.latex : .typst }

            for section in SectionExtractor.extract(from: source, documentID: UUID(), format: format) {
                let byCharacter = String(characters[section.start..<section.end])
                let byUTF16 = ns.substring(
                    with: NSRange(location: section.startUTF16, length: section.endUTF16 - section.startUTF16)
                )
                #expect(byCharacter == byUTF16, "section \(section.orderIndex) of \(name)")
            }
        }
    }

    // MARK: - Item 7: hybrid search ranking

    @Test("Hybrid search ranking reproduces the Swift goldens")
    func hybridSearchRanking() throws {
        let g = try Self.golden("search_ranking_golden.json")
        let scenarios = try #require(g["scenarios"] as? [[String: Any]])
        #expect(scenarios.count == 10)

        for expected in scenarios {
            let name = try #require(expected["name"] as? String)
            let query = try #require(expected["query"] as? String)
            let candidates = try #require(expected["candidates"] as? [[String: Any]]).map { row in
                SharedHybridCandidate(
                    id: row["id"] as? String ?? "",
                    citeKey: row["citeKey"] as? String ?? "",
                    title: row["title"] as? String ?? "",
                    authors: row["authors"] as? String ?? "",
                    ftsScore: (row["ftsScore"] as? Double).map { Float($0) },
                    semanticSimilarity: (row["semanticSimilarity"] as? Double).map { Float($0) },
                    chunkSimilarity: (row["chunkSimilarity"] as? Double).map { Float($0) }
                )
            }

            let ranked = rankHybridSearchResults(query: query, candidates: candidates)
            let want = try #require(expected["ranked"] as? [[String: Any]])
            #expect(ranked.count == want.count, "row count for \(name)")
            guard ranked.count == want.count else { continue }

            for (position, (wantRow, gotRow)) in zip(want, ranked).enumerated() {
                #expect(gotRow.id == wantRow["id"] as? String, "#\(position) id in \(name)")
                #expect(
                    gotRow.score == (wantRow["score"] as? Double).map({ Float($0) }),
                    "#\(position) score in \(name)"
                )
                #expect(
                    gotRow.matchType == wantRow["matchType"] as? String,
                    "#\(position) matchType in \(name)"
                )
            }
        }
    }
}
