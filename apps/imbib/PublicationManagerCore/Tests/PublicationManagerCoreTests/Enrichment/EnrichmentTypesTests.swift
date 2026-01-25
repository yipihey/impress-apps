//
//  EnrichmentTypesTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class EnrichmentTypesTests: XCTestCase {

    // MARK: - IdentifierType Tests
    // Note: IdentifierType is defined in SearchResult.swift

    func testIdentifierTypeCodableRoundTrip() throws {
        for type in IdentifierType.allCases {
            let encoded = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(IdentifierType.self, from: encoded)
            XCTAssertEqual(decoded, type)
        }
    }

    func testIdentifierTypeRawValues() {
        XCTAssertEqual(IdentifierType.doi.rawValue, "doi")
        XCTAssertEqual(IdentifierType.arxiv.rawValue, "arxiv")
        XCTAssertEqual(IdentifierType.pmid.rawValue, "pmid")
        XCTAssertEqual(IdentifierType.pmcid.rawValue, "pmcid")
        XCTAssertEqual(IdentifierType.bibcode.rawValue, "bibcode")
        XCTAssertEqual(IdentifierType.semanticScholar.rawValue, "semanticScholar")
        XCTAssertEqual(IdentifierType.openAlex.rawValue, "openAlex")
        XCTAssertEqual(IdentifierType.dblp.rawValue, "dblp")
    }

    // MARK: - EnrichmentSource Tests

    func testEnrichmentSourceCodableRoundTrip() throws {
        for source in EnrichmentSource.allCases {
            let encoded = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(EnrichmentSource.self, from: encoded)
            XCTAssertEqual(decoded, source)
        }
    }

    func testEnrichmentSourceDisplayNames() {
        XCTAssertEqual(EnrichmentSource.ads.displayName, "NASA ADS")
    }

    func testEnrichmentSourceIdentifiable() {
        XCTAssertEqual(EnrichmentSource.ads.id, "ads")
    }

    // MARK: - OpenAccessStatus Tests

    func testOpenAccessStatusCodableRoundTrip() throws {
        let statuses: [OpenAccessStatus] = [.gold, .green, .bronze, .hybrid, .closed, .unknown]
        for status in statuses {
            let encoded = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(OpenAccessStatus.self, from: encoded)
            XCTAssertEqual(decoded, status)
        }
    }

    // MARK: - EnrichmentCapabilities Tests

    func testEnrichmentCapabilitiesSingleFlag() {
        let caps = EnrichmentCapabilities.citationCount
        XCTAssertTrue(caps.contains(.citationCount))
        XCTAssertFalse(caps.contains(.references))
        XCTAssertFalse(caps.contains(.citations))
    }

    func testEnrichmentCapabilitiesMultipleFlags() {
        let caps: EnrichmentCapabilities = [.citationCount, .references, .pdfURL]
        XCTAssertTrue(caps.contains(.citationCount))
        XCTAssertTrue(caps.contains(.references))
        XCTAssertTrue(caps.contains(.pdfURL))
        XCTAssertFalse(caps.contains(.citations))
        XCTAssertFalse(caps.contains(.abstract))
    }

    func testEnrichmentCapabilitiesAll() {
        let caps = EnrichmentCapabilities.all
        XCTAssertTrue(caps.contains(.citationCount))
        XCTAssertTrue(caps.contains(.references))
        XCTAssertTrue(caps.contains(.citations))
        XCTAssertTrue(caps.contains(.abstract))
        XCTAssertTrue(caps.contains(.pdfURL))
        XCTAssertTrue(caps.contains(.authorStats))
        XCTAssertTrue(caps.contains(.openAccess))
        XCTAssertTrue(caps.contains(.venue))
    }

    func testEnrichmentCapabilitiesDescription() {
        let caps: EnrichmentCapabilities = [.citationCount, .references]
        XCTAssertTrue(caps.description.contains("citations"))
        XCTAssertTrue(caps.description.contains("references"))
    }

    // MARK: - PaperStub Tests

    func testPaperStubCodableRoundTrip() throws {
        let stub = PaperStub(
            id: "S2:12345",
            title: "Test Paper",
            authors: ["Einstein, Albert", "Bohr, Niels"],
            year: 1935,
            venue: "Physical Review",
            doi: "10.1103/PhysRev.47.777",
            arxivID: nil,
            citationCount: 1000,
            isOpenAccess: true
        )

        let encoded = try JSONEncoder().encode(stub)
        let decoded = try JSONDecoder().decode(PaperStub.self, from: encoded)

        XCTAssertEqual(decoded.id, stub.id)
        XCTAssertEqual(decoded.title, stub.title)
        XCTAssertEqual(decoded.authors, stub.authors)
        XCTAssertEqual(decoded.year, stub.year)
        XCTAssertEqual(decoded.venue, stub.venue)
        XCTAssertEqual(decoded.doi, stub.doi)
        XCTAssertEqual(decoded.arxivID, stub.arxivID)
        XCTAssertEqual(decoded.citationCount, stub.citationCount)
        XCTAssertEqual(decoded.isOpenAccess, stub.isOpenAccess)
    }

    func testPaperStubFirstAuthorLastNameCommaSeparated() {
        let stub = PaperStub(
            id: "1",
            title: "Test",
            authors: ["Einstein, Albert"]
        )
        XCTAssertEqual(stub.firstAuthorLastName, "Einstein")
    }

    func testPaperStubFirstAuthorLastNameSpaceSeparated() {
        let stub = PaperStub(
            id: "1",
            title: "Test",
            authors: ["Albert Einstein"]
        )
        XCTAssertEqual(stub.firstAuthorLastName, "Einstein")
    }

    func testPaperStubFirstAuthorLastNameSingleName() {
        let stub = PaperStub(
            id: "1",
            title: "Test",
            authors: ["Aristotle"]
        )
        XCTAssertEqual(stub.firstAuthorLastName, "Aristotle")
    }

    func testPaperStubFirstAuthorLastNameEmpty() {
        let stub = PaperStub(
            id: "1",
            title: "Test",
            authors: []
        )
        XCTAssertNil(stub.firstAuthorLastName)
    }

    func testPaperStubAuthorDisplayShortSingleAuthor() {
        let stub = PaperStub(
            id: "1",
            title: "Test",
            authors: ["Einstein, Albert"]
        )
        XCTAssertEqual(stub.authorDisplayShort, "Einstein")
    }

    func testPaperStubAuthorDisplayShortMultipleAuthors() {
        let stub = PaperStub(
            id: "1",
            title: "Test",
            authors: ["Einstein, Albert", "Podolsky, Boris", "Rosen, Nathan"]
        )
        XCTAssertEqual(stub.authorDisplayShort, "Einstein et al.")
    }

    func testPaperStubAuthorDisplayShortNoAuthors() {
        let stub = PaperStub(
            id: "1",
            title: "Test",
            authors: []
        )
        XCTAssertEqual(stub.authorDisplayShort, "Unknown")
    }

    func testPaperStubIdentifiers() {
        let stub = PaperStub(
            id: "1",
            title: "Test",
            authors: [],
            doi: "10.1234/test",
            arxivID: "2301.12345"
        )
        XCTAssertEqual(stub.identifiers[.doi], "10.1234/test")
        XCTAssertEqual(stub.identifiers[.arxiv], "2301.12345")
        XCTAssertNil(stub.identifiers[.pmid])
    }

    func testPaperStubEquatable() {
        let stub1 = PaperStub(id: "1", title: "Test", authors: ["Smith"])
        let stub2 = PaperStub(id: "1", title: "Test", authors: ["Smith"])
        let stub3 = PaperStub(id: "2", title: "Test", authors: ["Smith"])

        XCTAssertEqual(stub1, stub2)
        XCTAssertNotEqual(stub1, stub3)
    }

    func testPaperStubHashable() {
        let stub1 = PaperStub(id: "1", title: "Test", authors: ["Smith"])
        let stub2 = PaperStub(id: "1", title: "Test", authors: ["Smith"])

        var set: Set<PaperStub> = [stub1]
        set.insert(stub2)  // Should not add duplicate
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - AuthorStats Tests

    func testAuthorStatsCodableRoundTrip() throws {
        let stats = AuthorStats(
            authorID: "A12345",
            name: "Albert Einstein",
            hIndex: 50,
            citationCount: 100000,
            paperCount: 300,
            affiliations: ["Princeton", "ETH Zurich"]
        )

        let encoded = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(AuthorStats.self, from: encoded)

        XCTAssertEqual(decoded.authorID, stats.authorID)
        XCTAssertEqual(decoded.name, stats.name)
        XCTAssertEqual(decoded.hIndex, stats.hIndex)
        XCTAssertEqual(decoded.citationCount, stats.citationCount)
        XCTAssertEqual(decoded.paperCount, stats.paperCount)
        XCTAssertEqual(decoded.affiliations, stats.affiliations)
    }

    func testAuthorStatsMinimalInit() {
        let stats = AuthorStats(authorID: "A1", name: "Test Author")
        XCTAssertEqual(stats.authorID, "A1")
        XCTAssertEqual(stats.name, "Test Author")
        XCTAssertNil(stats.hIndex)
        XCTAssertNil(stats.citationCount)
        XCTAssertNil(stats.paperCount)
        XCTAssertNil(stats.affiliations)
    }

    // MARK: - EnrichmentData Tests

    func testEnrichmentDataCodableRoundTrip() throws {
        let data = EnrichmentData(
            citationCount: 100,
            referenceCount: 50,
            references: [PaperStub(id: "ref1", title: "Reference 1", authors: ["Smith"])],
            citations: [PaperStub(id: "cite1", title: "Citation 1", authors: ["Jones"])],
            abstract: "Test abstract",
            pdfURLs: [URL(string: "https://example.com/paper.pdf")!],
            openAccessStatus: .green,
            venue: "Nature",
            authorStats: [AuthorStats(authorID: "A1", name: "Smith")],
            source: .ads,
            fetchedAt: Date()
        )

        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(EnrichmentData.self, from: encoded)

        XCTAssertEqual(decoded.citationCount, data.citationCount)
        XCTAssertEqual(decoded.referenceCount, data.referenceCount)
        XCTAssertEqual(decoded.references?.count, data.references?.count)
        XCTAssertEqual(decoded.citations?.count, data.citations?.count)
        XCTAssertEqual(decoded.abstract, data.abstract)
        XCTAssertEqual(decoded.pdfURLs, data.pdfURLs)
        XCTAssertEqual(decoded.openAccessStatus, data.openAccessStatus)
        XCTAssertEqual(decoded.venue, data.venue)
        XCTAssertEqual(decoded.source, data.source)
    }

    func testEnrichmentDataAge() {
        let pastDate = Date().addingTimeInterval(-3600)  // 1 hour ago
        let data = EnrichmentData(source: .ads, fetchedAt: pastDate)

        XCTAssertGreaterThanOrEqual(data.age, 3600)
        XCTAssertLessThan(data.age, 3700)  // Some tolerance
    }

    func testEnrichmentDataIsStale() {
        // Fresh data (just now)
        let freshData = EnrichmentData(source: .ads, fetchedAt: Date())
        XCTAssertFalse(freshData.isStale(thresholdDays: 7))

        // Stale data (8 days ago)
        let staleDate = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let staleData = EnrichmentData(source: .ads, fetchedAt: staleDate)
        XCTAssertTrue(staleData.isStale(thresholdDays: 7))
    }

    func testEnrichmentDataMerging() {
        let data1 = EnrichmentData(
            citationCount: 100,
            abstract: "First abstract",
            source: .ads,
            fetchedAt: Date()
        )

        let data2 = EnrichmentData(
            referenceCount: 50,
            abstract: "Second abstract",  // Should be ignored
            venue: "Nature",
            source: .ads,
            fetchedAt: Date()
        )

        let merged = data1.merging(with: data2)

        XCTAssertEqual(merged.citationCount, 100)  // From data1
        XCTAssertEqual(merged.referenceCount, 50)  // From data2
        XCTAssertEqual(merged.abstract, "First abstract")  // From data1 (preferred)
        XCTAssertEqual(merged.venue, "Nature")  // From data2
        XCTAssertEqual(merged.source, .ads)  // Keeps original source
    }

    // MARK: - EnrichmentResult Tests

    func testEnrichmentResultInit() {
        let data = EnrichmentData(citationCount: 100, source: .ads)
        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test", .bibcode: "2020ApJ...123...45A"]

        let result = EnrichmentResult(data: data, resolvedIdentifiers: identifiers)

        XCTAssertEqual(result.data.citationCount, 100)
        XCTAssertEqual(result.resolvedIdentifiers[.doi], "10.1234/test")
        XCTAssertEqual(result.resolvedIdentifiers[.bibcode], "2020ApJ...123...45A")
    }

    // MARK: - EnrichmentPriority Tests

    func testEnrichmentPriorityOrdering() {
        XCTAssertLessThan(EnrichmentPriority.userTriggered, EnrichmentPriority.recentlyViewed)
        XCTAssertLessThan(EnrichmentPriority.recentlyViewed, EnrichmentPriority.libraryPaper)
        XCTAssertLessThan(EnrichmentPriority.libraryPaper, EnrichmentPriority.backgroundSync)
    }

    func testEnrichmentPriorityDescription() {
        XCTAssertEqual(EnrichmentPriority.userTriggered.description, "User Triggered")
        XCTAssertEqual(EnrichmentPriority.recentlyViewed.description, "Recently Viewed")
        XCTAssertEqual(EnrichmentPriority.libraryPaper.description, "Library Paper")
        XCTAssertEqual(EnrichmentPriority.backgroundSync.description, "Background Sync")
    }

    func testEnrichmentPrioritySorting() {
        var priorities: [EnrichmentPriority] = [.backgroundSync, .userTriggered, .libraryPaper, .recentlyViewed]
        priorities.sort()

        XCTAssertEqual(priorities, [.userTriggered, .recentlyViewed, .libraryPaper, .backgroundSync])
    }

    // MARK: - EnrichmentError Tests

    func testEnrichmentErrorDescriptions() {
        XCTAssertEqual(EnrichmentError.noIdentifier.errorDescription, "No identifier available for enrichment")
        XCTAssertEqual(EnrichmentError.noSourceAvailable.errorDescription, "No enrichment source could provide data")
        XCTAssertEqual(EnrichmentError.networkError("timeout").errorDescription, "Network error: timeout")
        XCTAssertEqual(EnrichmentError.rateLimited(retryAfter: 60).errorDescription, "Rate limited. Retry after 60 seconds")
        XCTAssertEqual(EnrichmentError.rateLimited(retryAfter: nil).errorDescription, "Rate limited. Please try again later")
        XCTAssertEqual(EnrichmentError.parseError("invalid JSON").errorDescription, "Failed to parse response: invalid JSON")
        XCTAssertEqual(EnrichmentError.notFound.errorDescription, "Paper not found in enrichment source")
        XCTAssertEqual(EnrichmentError.cancelled.errorDescription, "Enrichment request was cancelled")
    }

    // MARK: - EnrichmentState Tests

    func testEnrichmentStateIsLoading() {
        XCTAssertFalse(EnrichmentState.idle.isLoading)
        XCTAssertTrue(EnrichmentState.pending.isLoading)
        XCTAssertTrue(EnrichmentState.enriching.isLoading)
        XCTAssertFalse(EnrichmentState.complete(EnrichmentData(source: .ads)).isLoading)
        XCTAssertFalse(EnrichmentState.failed(.noIdentifier).isLoading)
    }

    func testEnrichmentStateData() {
        let data = EnrichmentData(citationCount: 100, source: .ads)

        XCTAssertNil(EnrichmentState.idle.data)
        XCTAssertNil(EnrichmentState.pending.data)
        XCTAssertNil(EnrichmentState.enriching.data)
        XCTAssertEqual(EnrichmentState.complete(data).data?.citationCount, 100)
        XCTAssertNil(EnrichmentState.failed(.noIdentifier).data)
    }

    func testEnrichmentStateError() {
        XCTAssertNil(EnrichmentState.idle.error)
        XCTAssertNil(EnrichmentState.pending.error)
        XCTAssertNil(EnrichmentState.enriching.error)
        XCTAssertNil(EnrichmentState.complete(EnrichmentData(source: .ads)).error)

        let state = EnrichmentState.failed(.noIdentifier)
        if case .noIdentifier = state.error {
            // Expected
        } else {
            XCTFail("Expected noIdentifier error")
        }
    }

    // MARK: - EnrichmentSettings Tests

    func testEnrichmentSettingsDefault() {
        let settings = EnrichmentSettings.default

        XCTAssertEqual(settings.preferredSource, .ads)
        XCTAssertEqual(settings.sourcePriority, [.ads])
        XCTAssertTrue(settings.autoSyncEnabled)
        XCTAssertEqual(settings.refreshIntervalDays, 7)
    }

    func testEnrichmentSettingsCodableRoundTrip() throws {
        let settings = EnrichmentSettings(
            preferredSource: .ads,
            sourcePriority: [.ads],
            autoSyncEnabled: false,
            refreshIntervalDays: 14
        )

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(EnrichmentSettings.self, from: encoded)

        XCTAssertEqual(decoded.preferredSource, settings.preferredSource)
        XCTAssertEqual(decoded.sourcePriority, settings.sourcePriority)
        XCTAssertEqual(decoded.autoSyncEnabled, settings.autoSyncEnabled)
        XCTAssertEqual(decoded.refreshIntervalDays, settings.refreshIntervalDays)
    }

    func testEnrichmentSettingsEquatable() {
        let settings1 = EnrichmentSettings.default
        let settings2 = EnrichmentSettings.default
        let settings3 = EnrichmentSettings(preferredSource: .ads, autoSyncEnabled: false)

        XCTAssertEqual(settings1, settings2)
        XCTAssertNotEqual(settings1, settings3)
    }
}
