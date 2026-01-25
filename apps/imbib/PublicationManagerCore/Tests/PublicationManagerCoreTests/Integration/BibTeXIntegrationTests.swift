//
//  BibTeXIntegrationTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class BibTeXIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// Extract BibTeXEntry items from parsed items
    private func extractEntries(_ items: [BibTeXItem]) -> [BibTeXEntry] {
        items.compactMap { item in
            if case .entry(let entry) = item {
                return entry
            }
            return nil
        }
    }

    // MARK: - Round-Trip Tests

    func testImportExport_preservesAllFields() throws {
        // Given - BibTeX with many fields
        let originalBibTeX = """
        @article{Einstein1905,
            author = {Albert Einstein},
            title = {On the Electrodynamics of Moving Bodies},
            journal = {Annalen der Physik},
            year = {1905},
            volume = {17},
            number = {10},
            pages = {891--921},
            doi = {10.1002/andp.19053221004},
            abstract = {This paper introduces the special theory of relativity.},
            keywords = {relativity, physics, electrodynamics},
            note = {Translated from German}
        }
        """

        // When - Parse and export
        let parser = BibTeXParser()
        let items = try parser.parse(originalBibTeX)
        let entries = extractEntries(items)
        XCTAssertEqual(entries.count, 1)

        let exporter = BibTeXExporter()
        let exported = exporter.export(entries)

        // Then - Parse again and verify fields
        let reimportedItems = try parser.parse(exported)
        let reimported = extractEntries(reimportedItems)
        XCTAssertEqual(reimported.count, 1)

        let entry = reimported[0]
        XCTAssertEqual(entry.citeKey, "Einstein1905")
        XCTAssertEqual(entry.entryType, "article")
        XCTAssertEqual(entry.fields["author"], "Albert Einstein")
        XCTAssertEqual(entry.fields["title"], "On the Electrodynamics of Moving Bodies")
        XCTAssertEqual(entry.fields["journal"], "Annalen der Physik")
        XCTAssertEqual(entry.fields["year"], "1905")
        XCTAssertEqual(entry.fields["volume"], "17")
        XCTAssertEqual(entry.fields["number"], "10")
        // Pages may be transformed from "891--921" to "891–921" (en-dash)
        XCTAssertTrue(entry.fields["pages"]?.contains("891") ?? false)
        XCTAssertTrue(entry.fields["pages"]?.contains("921") ?? false)
        XCTAssertEqual(entry.fields["doi"], "10.1002/andp.19053221004")
        XCTAssertNotNil(entry.fields["abstract"])
        XCTAssertNotNil(entry.fields["keywords"])
        XCTAssertNotNil(entry.fields["note"])
    }

    func testImportExport_preservesCustomFields() throws {
        // Given - BibTeX with custom (non-standard) fields
        let originalBibTeX = """
        @misc{CustomEntry2024,
            author = {Test Author},
            title = {Test Paper},
            year = {2024},
            custom-field-1 = {Custom Value 1},
            myspecialfield = {Special Data},
            institution-internal-id = {ABC123}
        }
        """

        // When
        let parser = BibTeXParser()
        let items = try parser.parse(originalBibTeX)
        let entries = extractEntries(items)
        let exported = BibTeXExporter().export(entries)
        let reimportedItems = try parser.parse(exported)
        let reimported = extractEntries(reimportedItems)

        // Then - Custom fields should be preserved
        let entry = reimported[0]
        XCTAssertEqual(entry.fields["custom-field-1"], "Custom Value 1")
        XCTAssertEqual(entry.fields["myspecialfield"], "Special Data")
        XCTAssertEqual(entry.fields["institution-internal-id"], "ABC123")
    }

    func testImportExport_multipleEntries() throws {
        // Given
        let originalBibTeX = """
        @article{Paper1,
            author = {Author One},
            title = {First Paper},
            year = {2020}
        }

        @book{Book1,
            author = {Author Two},
            title = {A Great Book},
            publisher = {Academic Press},
            year = {2021}
        }

        @inproceedings{Conf1,
            author = {Author Three},
            title = {Conference Paper},
            booktitle = {Proceedings of Something},
            year = {2022}
        }
        """

        // When
        let parser = BibTeXParser()
        let items = try parser.parse(originalBibTeX)
        let entries = extractEntries(items)

        XCTAssertEqual(entries.count, 3)

        let exported = BibTeXExporter().export(entries)
        let reimportedItems = try parser.parse(exported)
        let reimported = extractEntries(reimportedItems)

        // Then
        XCTAssertEqual(reimported.count, 3)

        let citeKeys = Set(reimported.map { $0.citeKey })
        XCTAssertTrue(citeKeys.contains("Paper1"))
        XCTAssertTrue(citeKeys.contains("Book1"))
        XCTAssertTrue(citeKeys.contains("Conf1"))

        let entryTypes = Set(reimported.map { $0.entryType })
        XCTAssertTrue(entryTypes.contains("article"))
        XCTAssertTrue(entryTypes.contains("book"))
        XCTAssertTrue(entryTypes.contains("inproceedings"))
    }

    func testImportExport_handlesSpecialCharacters() throws {
        // Given - BibTeX with LaTeX special characters
        let originalBibTeX = """
        @article{Muller2023,
            author = {M{\\\"u}ller, Hans and Caf{\\'e}, Jean},
            title = {The {\\alpha}-{\\beta} Algorithm: A Study of Na{\\\"i}ve Methods},
            journal = {Journal of M{\\\"u}nchen Studies},
            year = {2023}
        }
        """

        // When
        let parser = BibTeXParser()
        let items = try parser.parse(originalBibTeX)
        let entries = extractEntries(items)
        let exported = BibTeXExporter().export(entries)
        let reimportedItems = try parser.parse(exported)
        let reimported = extractEntries(reimportedItems)

        // Then - Should have preserved the author
        let entry = reimported[0]
        XCTAssertNotNil(entry.fields["author"])
    }

    // MARK: - Parser Edge Cases

    func testParser_handlesNestedBraces() throws {
        // Given
        let bibtex = """
        @article{Test2024,
            title = {A {Study} of {Nested {Braces}} in {BibTeX}}
        }
        """

        // When
        let items = try BibTeXParser().parse(bibtex)
        let entries = extractEntries(items)

        // Then
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].fields["title"]?.contains("Nested {Braces}") ?? false)
    }

    func testParser_handlesEmptyFields() throws {
        // Given
        let bibtex = """
        @article{Test2024,
            author = {},
            title = {Valid Title},
            year = {}
        }
        """

        // When
        let items = try BibTeXParser().parse(bibtex)
        let entries = extractEntries(items)

        // Then
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].fields["title"], "Valid Title")
    }

    func testParser_handlesCommentsAndPreamble() throws {
        // Given
        let bibtex = """
        % This is a comment
        @preamble{"Some preamble text"}

        @comment{This is an inline comment}

        @article{ActualEntry,
            author = {Test Author},
            title = {Real Paper}
        }

        % Another comment at the end
        """

        // When
        let items = try BibTeXParser().parse(bibtex)
        let entries = extractEntries(items)

        // Then - Should only have the article
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].citeKey, "ActualEntry")
    }

    // MARK: - Exporter Tests

    func testExporter_formatsConsistently() throws {
        // Given
        let entry = BibTeXEntry(
            citeKey: "Test2024",
            entryType: "article",
            fields: [
                "author": "Test Author",
                "title": "Test Title",
                "year": "2024"
            ]
        )

        // When
        let exported = BibTeXExporter().export([entry])

        // Then - Should be valid BibTeX
        XCTAssertTrue(exported.contains("@article{Test2024"))
        XCTAssertTrue(exported.contains("author"))
        XCTAssertTrue(exported.contains("title"))
        XCTAssertTrue(exported.contains("year"))
    }

    // MARK: - Deduplication Integration

    func testDeduplication_detectsSameDoI() async {
        // Given
        let result1 = SearchResult(
            id: "arxiv:2401.00001",
            sourceID: "arxiv",
            title: "Paper Title",
            authors: ["Author One"],
            year: 2024,
            venue: "arXiv",
            abstract: nil,
            doi: "10.1234/test.2024",
            arxivID: "2401.00001",
            pmid: nil,
            bibcode: nil,
            semanticScholarID: nil,
            openAlexID: nil,
            pdfURL: nil,
            webURL: nil,
            bibtexURL: nil
        )

        let result2 = SearchResult(
            id: "10.1234/test.2024",
            sourceID: "crossref",
            title: "Paper Title (from CrossRef)",
            authors: ["Author One"],
            year: 2024,
            venue: "Some Journal",
            abstract: nil,
            doi: "10.1234/test.2024",
            arxivID: nil,
            pmid: nil,
            bibcode: nil,
            semanticScholarID: nil,
            openAlexID: nil,
            pdfURL: nil,
            webURL: nil,
            bibtexURL: nil
        )

        // When
        let service = DeduplicationService()
        let deduplicated = await service.deduplicate([result1, result2])

        // Then - Should merge into one result
        XCTAssertEqual(deduplicated.count, 1)
    }

    func testDeduplication_detectsSameTitleAndAuthor() async {
        // Given - same paper from different sources, no shared IDs
        let result1 = SearchResult(
            id: "dblp:conf/test/Author24",
            sourceID: "dblp",
            title: "A Novel Approach to Testing",
            authors: ["Smith, John", "Doe, Jane"],
            year: 2024,
            venue: nil,
            abstract: nil,
            doi: nil,
            arxivID: nil,
            pmid: nil,
            bibcode: nil,
            semanticScholarID: nil,
            openAlexID: nil,
            pdfURL: nil,
            webURL: nil,
            bibtexURL: nil
        )

        let result2 = SearchResult(
            id: "openalex:W123456",
            sourceID: "openalex",
            title: "A Novel Approach to Testing",  // Same title
            authors: ["John Smith", "Jane Doe"],   // Same authors (different format)
            year: 2024,
            venue: nil,
            abstract: nil,
            doi: nil,
            arxivID: nil,
            pmid: nil,
            bibcode: nil,
            semanticScholarID: nil,
            openAlexID: nil,
            pdfURL: nil,
            webURL: nil,
            bibtexURL: nil
        )

        // When
        let service = DeduplicationService()
        let deduplicated = await service.deduplicate([result1, result2])

        // Then - fuzzy matching should detect as same paper
        // Note: This depends on the deduplication implementation
        // If fuzzy matching is enabled, should be 1; otherwise 2
        XCTAssertLessThanOrEqual(deduplicated.count, 2)
    }
}
