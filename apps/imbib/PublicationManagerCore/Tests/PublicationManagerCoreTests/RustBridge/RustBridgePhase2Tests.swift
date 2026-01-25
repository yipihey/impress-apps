//
//  RustBridgePhase2Tests.swift
//  PublicationManagerCoreTests
//
//  Tests for Phase 2 Rust bridges: RIS parsing, identifier extraction, deduplication
//

import Testing
import Foundation
@testable import PublicationManagerCore

@Suite("Phase 2 Rust Bridge Tests")
struct RustBridgePhase2Tests {

    // MARK: - RIS Parsing Tests

    @Suite("RIS Parser Bridge")
    struct RISParserBridgeTests {

        static let sampleRIS = """
        TY  - JOUR
        AU  - Smith, John
        AU  - Doe, Jane
        TI  - A Great Paper on Machine Learning
        JF  - Nature
        VL  - 42
        IS  - 7
        SP  - 100
        EP  - 115
        PY  - 2024
        DO  - 10.1038/nature12345
        AB  - This paper presents groundbreaking work.
        KW  - machine learning
        KW  - artificial intelligence
        ER  -
        """

        @Test("Swift RIS parser parses entries correctly")
        func swiftRISParser() throws {
            let parser = RISParser()
            let entries = try parser.parse(Self.sampleRIS)

            #expect(entries.count == 1)

            let entry = entries[0]
            #expect(entry.type == .JOUR)
            #expect(entry.title == "A Great Paper on Machine Learning")
            #expect(entry.authors.count == 2)
            #expect(entry.year == 2024)
            #expect(entry.doi == "10.1038/nature12345")
        }

        @Test("RIS parser factory creates correct parser")
        func parserFactory() {
            // Test Swift backend
            RISParserFactory.currentBackend = .swift
            let swiftParser = RISParserFactory.createParser()
            #expect(swiftParser is RISParser)

            // Rust backend will fall back to Swift if not available
            RISParserFactory.currentBackend = .rust
            _ = RISParserFactory.createParser()

            // Reset to Swift
            RISParserFactory.currentBackend = .swift
        }

        @Test("RIS to BibTeX conversion works")
        func risToBibTeX() throws {
            let parser = RISParser()
            let entries = try parser.parse(Self.sampleRIS)
            let risEntry = entries[0]

            let bibEntry = risEntry.toBibTeX()

            #expect(bibEntry.entryType == "article")
            #expect(bibEntry.fields["title"] == "A Great Paper on Machine Learning")
            #expect(bibEntry.fields["journal"] == "Nature")
            #expect(bibEntry.fields["year"] == "2024")
            #expect(bibEntry.fields["doi"] == "10.1038/nature12345")
        }
    }

    // MARK: - Identifier Extraction Tests

    @Suite("Identifier Extractor Bridge")
    struct IdentifierExtractorBridgeTests {

        @Test("Swift identifier extractor extracts DOIs")
        func swiftExtractDOIs() {
            let extractor = SwiftIdentifierExtractor()
            let text = "Check this paper: 10.1038/nature12345 for more info"
            let dois = extractor.extractDOIs(from: text)

            #expect(dois.count >= 1)
            if !dois.isEmpty {
                #expect(dois[0].contains("10.1038"))
            }
        }

        @Test("Swift identifier extractor extracts arXiv IDs")
        func swiftExtractArXiv() {
            let extractor = SwiftIdentifierExtractor()
            let text = "See arXiv:2301.12345 for the preprint"
            let arxivs = extractor.extractArXivIDs(from: text)

            #expect(!arxivs.isEmpty)
        }

        @Test("Identifier extractor factory creates correct extractor")
        func extractorFactory() {
            IdentifierExtractorFactory.currentBackend = .swift
            let swiftExtractor = IdentifierExtractorFactory.createExtractor()
            #expect(swiftExtractor is SwiftIdentifierExtractor)

            // Reset
            IdentifierExtractorFactory.currentBackend = .swift
        }

        @Test("Extracted identifier result equality")
        func extractedIdentifierEquality() {
            let result1 = ExtractedIdentifierResult(
                identifierType: "doi",
                value: "10.1038/nature12345",
                startIndex: 0,
                endIndex: 20
            )

            let result2 = ExtractedIdentifierResult(
                identifierType: "doi",
                value: "10.1038/nature12345",
                startIndex: 0,
                endIndex: 20
            )

            #expect(result1 == result2)
        }
    }

    // MARK: - Deduplication Tests

    @Suite("Deduplication Scorer Bridge")
    struct DeduplicationScorerBridgeTests {

        @Test("Swift deduplication scorer detects DOI match")
        func swiftDOIMatch() {
            let scorer = SwiftDeduplicationScorer()

            let entry1 = BibTeXEntry(
                citeKey: "Smith2024a",
                entryType: "article",
                fields: [
                    "title": "Machine Learning Paper",
                    "author": "John Smith",
                    "year": "2024",
                    "doi": "10.1038/nature12345"
                ]
            )

            let entry2 = BibTeXEntry(
                citeKey: "Smith2024b",
                entryType: "article",
                fields: [
                    "title": "Different Title",
                    "author": "J. Smith",
                    "year": "2024",
                    "doi": "10.1038/nature12345"
                ]
            )

            let result = scorer.calculateSimilarity(entry1: entry1, entry2: entry2)

            #expect(result.score == 1.0)
            #expect(result.reason.contains("DOI"))
            #expect(result.isMatch)
        }

        @Test("Swift deduplication scorer detects title similarity")
        func swiftTitleSimilarity() {
            let scorer = SwiftDeduplicationScorer()

            let entry1 = BibTeXEntry(
                citeKey: "Smith2024a",
                entryType: "article",
                fields: [
                    "title": "Deep Learning for Natural Language Processing",
                    "author": "John Smith",
                    "year": "2024"
                ]
            )

            let entry2 = BibTeXEntry(
                citeKey: "Smith2024b",
                entryType: "article",
                fields: [
                    "title": "Deep Learning for Natural Language Processing",
                    "author": "J. Smith",
                    "year": "2024"
                ]
            )

            let result = scorer.calculateSimilarity(entry1: entry1, entry2: entry2)

            #expect(result.score > 0.7)
            #expect(result.isPossibleMatch)
        }

        @Test("Swift titles match function")
        func swiftTitlesMatch() {
            let scorer = SwiftDeduplicationScorer()

            #expect(scorer.titlesMatch(
                title1: "Machine Learning",
                title2: "Machine Learning",
                threshold: 0.9
            ))

            #expect(scorer.titlesMatch(
                title1: "Machine Learning",
                title2: "machine learning",
                threshold: 0.9
            ))

            #expect(!scorer.titlesMatch(
                title1: "Machine Learning",
                title2: "Quantum Computing",
                threshold: 0.9
            ))
        }

        @Test("Swift authors overlap function")
        func swiftAuthorsOverlap() {
            let scorer = SwiftDeduplicationScorer()

            #expect(scorer.authorsOverlap(
                authors1: "John Smith and Jane Doe",
                authors2: "Smith, John"
            ))

            #expect(!scorer.authorsOverlap(
                authors1: "John Smith",
                authors2: "Jane Williams"
            ))
        }

        @Test("Deduplication factory creates correct scorer")
        func scorerFactory() {
            DeduplicationScorerFactory.currentBackend = .swift
            let swiftScorer = DeduplicationScorerFactory.createScorer()
            #expect(swiftScorer is SwiftDeduplicationScorer)

            // Reset
            DeduplicationScorerFactory.currentBackend = .swift
        }

        @Test("Deduplication match result properties")
        func matchResultProperties() {
            let highMatch = DeduplicationMatchResult(score: 0.9, reason: "DOI match")
            #expect(highMatch.isMatch)
            #expect(highMatch.isPossibleMatch)

            let mediumMatch = DeduplicationMatchResult(score: 0.6, reason: "Title similarity")
            #expect(!mediumMatch.isMatch)
            #expect(mediumMatch.isPossibleMatch)

            let lowMatch = DeduplicationMatchResult(score: 0.3, reason: "No significant similarity")
            #expect(!lowMatch.isMatch)
            #expect(!lowMatch.isPossibleMatch)
        }
    }

    // MARK: - Unified Format Converter Tests

    @Suite("Unified Format Converter")
    struct UnifiedFormatConverterTests {

        @Test("Format detection detects BibTeX")
        func detectBibTeX() {
            let bibtex = """
            @article{Smith2024,
                author = {John Smith},
                title = {A Great Paper},
                year = {2024}
            }
            """

            let format = UnifiedFormatConverter.detectFormat(bibtex)
            #expect(format == .bibtex)
        }

        @Test("Format detection detects RIS")
        func detectRIS() {
            let ris = """
            TY  - JOUR
            AU  - Smith, John
            TI  - A Great Paper
            PY  - 2024
            ER  -
            """

            let format = UnifiedFormatConverter.detectFormat(ris)
            #expect(format == .ris)
        }

        @Test("Unified parser auto-detects format")
        func autoDetectParse() throws {
            let bibtex = """
            @article{Smith2024,
                author = {John Smith},
                title = {A Great Paper},
                year = {2024}
            }
            """

            let entries = try UnifiedFormatConverter.parse(bibtex)
            #expect(entries.count == 1)
            #expect(entries[0].citeKey == "Smith2024")
        }

        @Test("RIS content can be parsed via unified converter")
        func parseRISContent() throws {
            let ris = """
            TY  - JOUR
            AU  - Smith, John
            TI  - A Great Paper
            PY  - 2024
            ER  -
            """

            let entries = try UnifiedFormatConverter.parse(ris)
            #expect(entries.count == 1)
            #expect(entries[0].fields["title"] == "A Great Paper")
        }

    }
}
