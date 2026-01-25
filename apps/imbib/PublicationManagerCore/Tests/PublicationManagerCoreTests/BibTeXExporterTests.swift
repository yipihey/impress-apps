//
//  BibTeXExporterTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class BibTeXExporterTests: XCTestCase {

    var exporter: BibTeXExporter!

    override func setUp() {
        super.setUp()
        exporter = BibTeXExporter()
    }

    override func tearDown() {
        exporter = nil
        super.tearDown()
    }

    // MARK: - Basic Export

    func testExportSimpleEntry() {
        let entry = BibTeXEntry(
            citeKey: "Test2023",
            entryType: "article",
            fields: [
                "author": "John Doe",
                "title": "Test Article",
                "year": "2023"
            ]
        )

        let output = exporter.export(entry)

        XCTAssertTrue(output.contains("@article{Test2023,"))
        XCTAssertTrue(output.contains("author = {John Doe}"))
        XCTAssertTrue(output.contains("title = {Test Article}"))
        // Year is numeric, so no braces
        XCTAssertTrue(output.contains("year = 2023") || output.contains("year = {2023}"))
    }

    func testExportMultipleEntries() {
        let entries = [
            BibTeXEntry(citeKey: "Entry1", entryType: "article", fields: ["title": "First"]),
            BibTeXEntry(citeKey: "Entry2", entryType: "book", fields: ["title": "Second"]),
        ]

        let output = exporter.export(entries)

        XCTAssertTrue(output.contains("@article{Entry1,"))
        XCTAssertTrue(output.contains("@book{Entry2,"))
    }

    // MARK: - Field Ordering

    func testFieldOrdering() {
        let entry = BibTeXEntry(
            citeKey: "Test",
            entryType: "article",
            fields: [
                "abstract": "The abstract",
                "author": "Author",
                "year": "2023",
                "title": "Title",
                "journal": "Journal"
            ]
        )

        let output = exporter.export(entry)
        let lines = output.components(separatedBy: "\n")

        // Find indices of fields
        let authorIndex = lines.firstIndex { $0.contains("author =") }
        let titleIndex = lines.firstIndex { $0.contains("title =") }
        let journalIndex = lines.firstIndex { $0.contains("journal =") }
        let yearIndex = lines.firstIndex { $0.contains("year =") }
        let abstractIndex = lines.firstIndex { $0.contains("abstract =") }

        // Verify ordering
        XCTAssertNotNil(authorIndex)
        XCTAssertNotNil(titleIndex)
        XCTAssertNotNil(journalIndex)
        XCTAssertNotNil(yearIndex)
        XCTAssertNotNil(abstractIndex)

        // author should come before title
        if let ai = authorIndex, let ti = titleIndex {
            XCTAssertLessThan(ai, ti)
        }

        // abstract should come after year
        if let yi = yearIndex, let abi = abstractIndex {
            XCTAssertLessThan(yi, abi)
        }
    }

    // MARK: - Round Trip

    func testRoundTrip() throws {
        let original = """
        @article{Test2023,
            author = {John Doe},
            title = {Test Article},
            journal = {Test Journal},
            year = {2023},
            volume = {1},
            pages = {1--10}
        }
        """

        let parser = BibTeXParser()
        let entries = try parser.parseEntries(original)
        let exported = exporter.export(entries)
        let reparsed = try parser.parseEntries(exported)

        XCTAssertEqual(entries.count, reparsed.count)
        XCTAssertEqual(entries[0].citeKey, reparsed[0].citeKey)
        XCTAssertEqual(entries[0].entryType, reparsed[0].entryType)
        XCTAssertEqual(entries[0].fields["author"], reparsed[0].fields["author"])
        XCTAssertEqual(entries[0].fields["title"], reparsed[0].fields["title"])
    }
}

// MARK: - Cite Key Generator Tests

final class CiteKeyGeneratorTests: XCTestCase {

    var generator: CiteKeyGenerator!

    override func setUp() {
        super.setUp()
        generator = CiteKeyGenerator()
    }

    override func tearDown() {
        generator = nil
        super.tearDown()
    }

    func testGenerateBasicCiteKey() {
        let fields: [String: String] = [
            "author": "Einstein, Albert",
            "year": "1905",
            "title": "On the Electrodynamics of Moving Bodies"
        ]

        let key = generator.generate(from: fields)

        XCTAssertTrue(key.hasPrefix("Einstein"))
        XCTAssertTrue(key.contains("1905"))
    }

    func testGenerateWithMultipleAuthors() {
        let fields: [String: String] = [
            "author": "Watson, James and Crick, Francis",
            "year": "1953",
            "title": "Molecular Structure"
        ]

        let key = generator.generate(from: fields)

        XCTAssertTrue(key.hasPrefix("Watson"))
    }

    func testGenerateWithFirstLastFormat() {
        let fields: [String: String] = [
            "author": "Albert Einstein",
            "year": "1915",
            "title": "General Relativity"
        ]

        let key = generator.generate(from: fields)

        XCTAssertTrue(key.hasPrefix("Einstein"))
    }

    func testGenerateUnique() {
        let fields: [String: String] = [
            "author": "Smith, John",
            "year": "2020",
            "title": "Paper"
        ]

        let existingKeys: Set<String> = ["Smith2020Paper", "Smith2020Papera"]

        let key = generator.generateUnique(from: fields, existingKeys: existingKeys)

        XCTAssertEqual(key, "Smith2020Paperb")
    }

    func testGenerateFromSearchResult() {
        let result = SearchResult(
            id: "test",
            sourceID: "test",
            title: "Quantum Computing Advances",
            authors: ["Alice Researcher"],
            year: 2024
        )

        let key = generator.generate(from: result)

        XCTAssertTrue(key.hasPrefix("Researcher"))
        XCTAssertTrue(key.contains("2024"))
    }
}
