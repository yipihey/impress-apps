//
//  MockPublicationRepository.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import CoreData
@testable import PublicationManagerCore

/// In-memory mock publication storage for testing.
/// Uses a simple struct instead of Core Data for isolation.
public struct MockPublication: Identifiable, Equatable {
    public let id: UUID
    public var citeKey: String
    public var entryType: String
    public var title: String
    public var year: Int16
    public var abstract: String?
    public var doi: String?
    public var rawBibTeX: String?
    public var rawFields: String?
    public var dateAdded: Date
    public var dateModified: Date

    public init(
        id: UUID = UUID(),
        citeKey: String,
        entryType: String = "article",
        title: String = "",
        year: Int16 = 0,
        abstract: String? = nil,
        doi: String? = nil,
        rawBibTeX: String? = nil,
        rawFields: String? = nil,
        dateAdded: Date = Date(),
        dateModified: Date = Date()
    ) {
        self.id = id
        self.citeKey = citeKey
        self.entryType = entryType
        self.title = title
        self.year = year
        self.abstract = abstract
        self.doi = doi
        self.rawBibTeX = rawBibTeX
        self.rawFields = rawFields
        self.dateAdded = dateAdded
        self.dateModified = dateModified
    }

    public init(from entry: BibTeXEntry) {
        self.id = UUID()
        self.citeKey = entry.citeKey
        self.entryType = entry.entryType
        self.title = entry.title ?? ""
        self.year = Int16(entry.yearInt ?? 0)
        self.abstract = entry.abstract
        self.doi = entry.doi
        self.rawBibTeX = entry.rawBibTeX
        self.rawFields = nil
        self.dateAdded = Date()
        self.dateModified = Date()
    }

    public func toBibTeXEntry() -> BibTeXEntry {
        var fields: [String: String] = [:]
        fields["title"] = title
        if year != 0 { fields["year"] = String(year) }
        if let abstract = abstract { fields["abstract"] = abstract }
        if let doi = doi { fields["doi"] = doi }

        return BibTeXEntry(
            citeKey: citeKey,
            entryType: entryType,
            fields: fields,
            rawBibTeX: rawBibTeX
        )
    }
}

/// Mock publication repository for testing without Core Data.
public actor MockPublicationRepository {

    // MARK: - Storage

    private var publications: [UUID: MockPublication] = [:]

    // MARK: - Call Tracking

    public private(set) var fetchAllCallCount = 0
    public private(set) var fetchByCiteKeyCallCount = 0
    public private(set) var fetchByIDCallCount = 0
    public private(set) var searchCallCount = 0
    public private(set) var createCallCount = 0
    public private(set) var deleteCallCount = 0
    public private(set) var importCallCount = 0
    public private(set) var exportCallCount = 0

    public private(set) var lastSearchQuery: String?
    public private(set) var lastCreatedEntry: BibTeXEntry?
    public private(set) var lastDeletedIDs: [UUID] = []

    // MARK: - Configuration

    /// Error to throw from operations
    public var operationError: Error?

    // MARK: - Initialization

    public init() {}

    /// Initialize with pre-populated publications
    public init(publications: [MockPublication]) {
        for pub in publications {
            self.publications[pub.id] = pub
        }
    }

    // MARK: - Fetch Operations

    public func fetchAll(sortedBy sortKey: String = "dateAdded", ascending: Bool = false) async -> [MockPublication] {
        fetchAllCallCount += 1

        let sorted = publications.values.sorted { pub1, pub2 in
            let result: Bool
            switch sortKey {
            case "title":
                result = pub1.title < pub2.title
            case "year":
                result = pub1.year < pub2.year
            case "citeKey":
                result = pub1.citeKey < pub2.citeKey
            case "dateModified":
                result = pub1.dateModified < pub2.dateModified
            default: // dateAdded
                result = pub1.dateAdded < pub2.dateAdded
            }
            return ascending ? result : !result
        }

        return sorted
    }

    public func fetch(byCiteKey citeKey: String) async -> MockPublication? {
        fetchByCiteKeyCallCount += 1
        return publications.values.first { $0.citeKey == citeKey }
    }

    public func fetch(byID id: UUID) async -> MockPublication? {
        fetchByIDCallCount += 1
        return publications[id]
    }

    public func search(query: String) async -> [MockPublication] {
        searchCallCount += 1
        lastSearchQuery = query

        guard !query.isEmpty else { return await fetchAll() }

        let lowercasedQuery = query.lowercased()
        return publications.values.filter { pub in
            pub.title.lowercased().contains(lowercasedQuery) ||
            pub.citeKey.lowercased().contains(lowercasedQuery)
        }
    }

    public func allCiteKeys() async -> Set<String> {
        Set(publications.values.map { $0.citeKey })
    }

    // MARK: - Create Operations

    @discardableResult
    public func create(from entry: BibTeXEntry) async -> MockPublication {
        createCallCount += 1
        lastCreatedEntry = entry

        let publication = MockPublication(from: entry)
        publications[publication.id] = publication
        return publication
    }

    public func importEntries(_ entries: [BibTeXEntry]) async -> Int {
        importCallCount += 1

        var imported = 0
        for entry in entries {
            let existingCiteKeys = await allCiteKeys()
            if !existingCiteKeys.contains(entry.citeKey) {
                await create(from: entry)
                imported += 1
            }
        }
        return imported
    }

    // MARK: - Update Operations

    public func update(_ publication: MockPublication, with entry: BibTeXEntry) async {
        var updated = MockPublication(from: entry)
        updated = MockPublication(
            id: publication.id,
            citeKey: entry.citeKey,
            entryType: entry.entryType,
            title: entry.title ?? "",
            year: Int16(entry.yearInt ?? 0),
            abstract: entry.abstract,
            doi: entry.doi,
            rawBibTeX: entry.rawBibTeX,
            dateAdded: publication.dateAdded,
            dateModified: Date()
        )
        publications[publication.id] = updated
    }

    // MARK: - Delete Operations

    public func delete(_ publication: MockPublication) async {
        deleteCallCount += 1
        lastDeletedIDs = [publication.id]
        publications.removeValue(forKey: publication.id)
    }

    public func delete(_ publicationsToDelete: [MockPublication]) async {
        deleteCallCount += 1
        lastDeletedIDs = publicationsToDelete.map { $0.id }
        for pub in publicationsToDelete {
            publications.removeValue(forKey: pub.id)
        }
    }

    // MARK: - Export Operations

    public func exportAll() async -> String {
        exportCallCount += 1
        let allPubs = await fetchAll(sortedBy: "citeKey", ascending: true)
        let entries = allPubs.map { $0.toBibTeXEntry() }
        return BibTeXExporter().export(entries)
    }

    public func export(_ publicationsToExport: [MockPublication]) -> String {
        exportCallCount += 1
        let entries = publicationsToExport.map { $0.toBibTeXEntry() }
        return BibTeXExporter().export(entries)
    }

    // MARK: - Test Helpers

    /// Reset all tracked state
    public func reset() {
        publications.removeAll()
        fetchAllCallCount = 0
        fetchByCiteKeyCallCount = 0
        fetchByIDCallCount = 0
        searchCallCount = 0
        createCallCount = 0
        deleteCallCount = 0
        importCallCount = 0
        exportCallCount = 0
        lastSearchQuery = nil
        lastCreatedEntry = nil
        lastDeletedIDs = []
        operationError = nil
    }

    /// Add publications directly (for test setup)
    public func add(_ publication: MockPublication) {
        publications[publication.id] = publication
    }

    /// Get current publication count
    public var count: Int {
        publications.count
    }

    /// Get all publications (for test verification)
    public var allPublications: [MockPublication] {
        Array(publications.values)
    }
}

// MARK: - Factory Helpers

extension MockPublication {
    /// Create sample publications for testing
    public static func samples(count: Int = 5) -> [MockPublication] {
        let now = Date()
        return (0..<count).map { i in
            MockPublication(
                citeKey: "Sample\(2020 + i)",
                entryType: "article",
                title: "Sample Paper \(i + 1): A Study",
                year: Int16(2020 + i),
                abstract: "Abstract for sample paper \(i + 1)",
                doi: "10.1234/sample.\(i)",
                dateAdded: now.addingTimeInterval(Double(-i * 3600)),
                dateModified: now.addingTimeInterval(Double(-i * 1800))
            )
        }
    }
}
