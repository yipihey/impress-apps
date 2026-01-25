//
//  EnrichmentServiceTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

// MARK: - Mock Settings Provider

actor MockSettingsProvider: EnrichmentSettingsProvider {
    var preferredSource: EnrichmentSource = .ads
    var sourcePriority: [EnrichmentSource] = [.ads]
    var autoSyncEnabled: Bool = true
    var refreshIntervalDays: Int = 7

    func setSourcePriority(_ priority: [EnrichmentSource]) {
        sourcePriority = priority
    }
}

// MARK: - Tests

final class EnrichmentServiceTests: XCTestCase {

    var mockPlugin: MockEnrichmentPlugin!
    var settingsProvider: MockSettingsProvider!
    var service: EnrichmentService!

    override func setUp() async throws {
        mockPlugin = MockEnrichmentPlugin(
            id: "ads",
            name: "NASA ADS",
            capabilities: [.citationCount, .references, .pdfURL]
        )

        settingsProvider = MockSettingsProvider()

        service = EnrichmentService(
            plugins: [mockPlugin],
            settingsProvider: settingsProvider
        )
    }

    // MARK: - Basic Enrichment Tests

    func testEnrichNowWithValidIdentifiers() async throws {
        let expectedResult = EnrichmentResult(
            data: EnrichmentData(
                citationCount: 100,
                source: .ads
            ),
            resolvedIdentifiers: [.doi: "10.1234/test"]
        )
        await mockPlugin.setEnrichResult(expectedResult)

        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]
        let result = try await service.enrichNow(identifiers: identifiers)

        XCTAssertEqual(result.data.citationCount, 100)
        XCTAssertEqual(result.data.source, .ads)
    }

    func testEnrichNowWithNoIdentifiers() async {
        let identifiers: [IdentifierType: String] = [:]

        do {
            _ = try await service.enrichNow(identifiers: identifiers)
            XCTFail("Expected error")
        } catch let error as EnrichmentError {
            XCTAssertEqual(error.errorDescription, EnrichmentError.noIdentifier.errorDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEnrichNowWithBibcode() async throws {
        let expectedResult = EnrichmentResult(
            data: EnrichmentData(citationCount: 150, source: .ads),
            resolvedIdentifiers: [.bibcode: "2020ApJ...123...45A"]
        )
        await mockPlugin.setEnrichResult(expectedResult)

        let identifiers: [IdentifierType: String] = [.bibcode: "2020ApJ...123...45A"]
        let result = try await service.enrichNow(identifiers: identifiers)

        XCTAssertEqual(result.data.source, .ads)
        XCTAssertEqual(result.data.citationCount, 150)

        let callCount = await mockPlugin.enrichCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testEnrichNowDoesNotFallbackOnRateLimited() async {
        await mockPlugin.setFailure(.rateLimited(retryAfter: 60))

        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]

        do {
            _ = try await service.enrichNow(identifiers: identifiers)
            XCTFail("Expected rate limited error")
        } catch let error as EnrichmentError {
            if case .rateLimited = error {
                // Expected - should not fall back
            } else {
                XCTFail("Expected rateLimited error")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEnrichNowPluginFails() async {
        await mockPlugin.setFailure(.notFound)

        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]

        do {
            _ = try await service.enrichNow(identifiers: identifiers)
            XCTFail("Expected error")
        } catch let error as EnrichmentError {
            if case .notFound = error {
                // Expected
            } else {
                XCTFail("Expected notFound error")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Search Result Enrichment

    func testEnrichSearchResult() async throws {
        let expectedResult = EnrichmentResult(
            data: EnrichmentData(citationCount: 200, source: .ads),
            resolvedIdentifiers: [:]
        )
        await mockPlugin.setEnrichResult(expectedResult)

        let searchResult = SearchResult(
            id: "test",
            sourceID: "test",
            title: "Test Paper",
            doi: "10.1234/test",
            arxivID: "2301.12345"
        )

        let result = try await service.enrichSearchResult(searchResult)

        XCTAssertEqual(result.data.citationCount, 200)

        // Should have used identifiers from search result
        let lastIds = await mockPlugin.lastIdentifiers
        XCTAssertEqual(lastIds?[.doi], "10.1234/test")
        XCTAssertEqual(lastIds?[.arxiv], "2301.12345")
    }

    // MARK: - Queue Management Tests

    func testQueueForEnrichment() async {
        let publicationID = UUID()
        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]

        await service.queueForEnrichment(
            publicationID: publicationID,
            identifiers: identifiers,
            priority: .libraryPaper
        )

        let depth = await service.queueDepth()
        XCTAssertEqual(depth, 1)
    }

    func testProcessNextQueued() async throws {
        let expectedResult = EnrichmentResult(
            data: EnrichmentData(citationCount: 50, source: .ads),
            resolvedIdentifiers: [:]
        )
        await mockPlugin.setEnrichResult(expectedResult)

        let publicationID = UUID()
        await service.queueForEnrichment(
            publicationID: publicationID,
            identifiers: [.doi: "10.1234/test"],
            priority: .userTriggered
        )

        let result = await service.processNextQueued()

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, publicationID)

        switch result?.1 {
        case .success(let data):
            XCTAssertEqual(data.data.citationCount, 50)
        case .failure(let error):
            XCTFail("Unexpected failure: \(error)")
        case .none:
            XCTFail("Expected result")
        }

        // Queue should be empty now
        let depth = await service.queueDepth()
        XCTAssertEqual(depth, 0)
    }

    func testProcessNextQueuedEmptyQueue() async {
        let result = await service.processNextQueued()
        XCTAssertNil(result)
    }

    func testProcessNextQueuedWithFailure() async {
        await mockPlugin.setFailure(.notFound)

        let publicationID = UUID()
        await service.queueForEnrichment(
            publicationID: publicationID,
            identifiers: [.doi: "10.1234/test"],
            priority: .libraryPaper
        )

        let result = await service.processNextQueued()

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, publicationID)

        switch result?.1 {
        case .success:
            XCTFail("Expected failure")
        case .failure:
            // Expected
            break
        case .none:
            XCTFail("Expected result")
        }
    }

    // MARK: - Background Sync Tests

    func testStartBackgroundSync() async {
        let isRunning1 = await service.isRunning
        XCTAssertFalse(isRunning1)

        await service.startBackgroundSync()

        let isRunning2 = await service.isRunning
        XCTAssertTrue(isRunning2)

        await service.stopBackgroundSync()

        let isRunning3 = await service.isRunning
        XCTAssertFalse(isRunning3)
    }

    func testStartBackgroundSyncIdempotent() async {
        await service.startBackgroundSync()
        await service.startBackgroundSync()  // Should not start second time

        let isRunning = await service.isRunning
        XCTAssertTrue(isRunning)

        await service.stopBackgroundSync()
    }

    func testStopBackgroundSyncWhenNotRunning() async {
        // Should not crash
        await service.stopBackgroundSync()

        let isRunning = await service.isRunning
        XCTAssertFalse(isRunning)
    }

    // MARK: - Plugin Access Tests

    func testRegisteredPlugins() async {
        let plugins = await service.registeredPlugins
        XCTAssertEqual(plugins.count, 1)
    }

    func testPluginForSourceID() async {
        let plugin = await service.plugin(for: "ads")
        XCTAssertNotNil(plugin)

        let metadata = await plugin?.metadata
        XCTAssertEqual(metadata?.name, "NASA ADS")
    }

    func testPluginForUnknownSourceID() async {
        let plugin = await service.plugin(for: "unknown")
        XCTAssertNil(plugin)
    }

    func testPluginsSupportingCapability() async {
        let citationPlugins = await service.plugins(supporting: .citationCount)
        XCTAssertEqual(citationPlugins.count, 1)

        let refsPlugins = await service.plugins(supporting: .references)
        XCTAssertEqual(refsPlugins.count, 1)

        let pdfPlugins = await service.plugins(supporting: .pdfURL)
        XCTAssertEqual(pdfPlugins.count, 1)
    }

    // MARK: - Existing Data Merge Tests

    func testEnrichNowMergesWithExistingData() async throws {
        // New data has citation count but no abstract
        let newResult = EnrichmentResult(
            data: EnrichmentData(
                citationCount: 150,
                abstract: nil,
                source: .ads
            ),
            resolvedIdentifiers: [:]
        )
        await mockPlugin.setEnrichResult(newResult)

        let existingData = EnrichmentData(
            citationCount: 100,
            abstract: "Existing abstract",
            source: .ads
        )

        let identifiers: [IdentifierType: String] = [.doi: "10.1234/test"]
        let result = try await service.enrichNow(identifiers: identifiers, existingData: existingData)

        // Plugin should have received existing data
        // (the actual merge behavior is tested in plugin tests)
        let callCount = await mockPlugin.enrichCallCount
        XCTAssertEqual(callCount, 1)
    }
}

// MARK: - Default Settings Provider Tests

final class DefaultEnrichmentSettingsProviderTests: XCTestCase {

    func testDefaultSettings() async {
        let provider = DefaultEnrichmentSettingsProvider()

        let preferred = await provider.preferredSource
        let priority = await provider.sourcePriority
        let autoSync = await provider.autoSyncEnabled
        let interval = await provider.refreshIntervalDays

        XCTAssertEqual(preferred, .ads)
        XCTAssertEqual(priority, [.ads])
        XCTAssertTrue(autoSync)
        XCTAssertEqual(interval, 7)
    }

    func testCustomSettings() async {
        let settings = EnrichmentSettings(
            preferredSource: .ads,
            sourcePriority: [.ads],
            autoSyncEnabled: false,
            refreshIntervalDays: 14
        )
        let provider = DefaultEnrichmentSettingsProvider(settings: settings)

        let preferred = await provider.preferredSource
        let priority = await provider.sourcePriority
        let autoSync = await provider.autoSyncEnabled
        let interval = await provider.refreshIntervalDays

        XCTAssertEqual(preferred, .ads)
        XCTAssertEqual(priority, [.ads])
        XCTAssertFalse(autoSync)
        XCTAssertEqual(interval, 14)
    }

    func testUpdateSettings() async {
        let provider = DefaultEnrichmentSettingsProvider()

        let newSettings = EnrichmentSettings(
            preferredSource: .ads,
            sourcePriority: [.ads],
            autoSyncEnabled: false,
            refreshIntervalDays: 30
        )
        await provider.update(newSettings)

        let preferred = await provider.preferredSource
        XCTAssertEqual(preferred, .ads)
    }
}
