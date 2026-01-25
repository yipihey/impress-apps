//
//  BrowserURLProviderTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-06.
//

import XCTest
@testable import PublicationManagerCore
import CoreData

final class BrowserURLProviderTests: XCTestCase {

    private var persistenceController: PersistenceController!

    override func setUp() async throws {
        try await super.setUp()
        persistenceController = .preview
    }

    override func tearDown() async throws {
        persistenceController = nil
        try await super.tearDown()
    }

    // MARK: - DefaultBrowserURLProvider Tests

    @MainActor
    func testDefaultProvider_withDOI_returnsDOIResolver() {
        let pub = createPublication(doi: "10.1234/test.doi")

        let url = DefaultBrowserURLProvider.browserPDFURL(for: pub)

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "https://doi.org/10.1234/test.doi")
    }

    @MainActor
    func testDefaultProvider_withNoDOI_returnsNil() {
        let pub = createPublication()

        let url = DefaultBrowserURLProvider.browserPDFURL(for: pub)

        XCTAssertNil(url)
    }

    func testDefaultProvider_sourceID_isDefault() {
        XCTAssertEqual(DefaultBrowserURLProvider.sourceID, "default")
    }

    // MARK: - ADS BrowserURLProvider Tests

    @MainActor
    func testADSProvider_withDOI_returnsDOIResolver() {
        // DOI takes priority over bibcode for browser access
        let pub = createPublication(doi: "10.1234/test", bibcode: "2024ApJ...900..123A")

        let url = ADSSource.browserPDFURL(for: pub)

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "https://doi.org/10.1234/test")
    }

    @MainActor
    func testADSProvider_withBibcodeOnly_returnsAbstractPage() {
        // Without DOI, falls back to ADS abstract page
        let pub = createPublication(bibcode: "2024ApJ...900..123A")

        let url = ADSSource.browserPDFURL(for: pub)

        XCTAssertNotNil(url)
        XCTAssertEqual(
            url?.absoluteString,
            "https://ui.adsabs.harvard.edu/abs/2024ApJ...900..123A/abstract"
        )
    }

    @MainActor
    func testADSProvider_withNoDOIOrBibcode_returnsNil() {
        let pub = createPublication()

        let url = ADSSource.browserPDFURL(for: pub)

        XCTAssertNil(url)
    }

    func testADSProvider_sourceID_isADS() {
        XCTAssertEqual(ADSSource.sourceID, "ads")
    }

    // MARK: - Registry Tests

    func testRegistry_registerProvider_addsProvider() async {
        let registry = BrowserURLProviderRegistry.shared

        await registry.register(ADSSource.self, priority: 10)

        let sources = await registry.registeredSources
        XCTAssertTrue(sources.contains("ads"))
    }

    @MainActor
    func testRegistry_browserURL_withRegisteredProvider_usesProvider() async {
        let registry = BrowserURLProviderRegistry.shared
        await registry.register(ADSSource.self, priority: 10)

        let pub = createPublication(bibcode: "2024ApJ...900..123A")
        let url = await registry.browserURL(for: pub)

        XCTAssertNotNil(url)
        // ADS provider now returns abstract page for bibcode-only papers
        XCTAssertTrue(url?.absoluteString.contains("adsabs.harvard.edu") ?? false)
    }

    @MainActor
    func testRegistry_browserURL_fallsBackToDOI() async {
        let registry = BrowserURLProviderRegistry.shared

        let pub = createPublication(doi: "10.1234/fallback.test")
        let url = await registry.browserURL(for: pub)

        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("doi.org") ?? false)
    }

    @MainActor
    func testRegistry_browserURL_withNoSource_returnsNil() async {
        let registry = BrowserURLProviderRegistry.shared

        let pub = createPublication()
        let url = await registry.browserURL(for: pub)

        XCTAssertNil(url)
    }

    @MainActor
    func testRegistry_browserURLFromSource_withRegisteredSource_returnsURL() async {
        let registry = BrowserURLProviderRegistry.shared
        await registry.register(ADSSource.self, priority: 10)

        let pub = createPublication(bibcode: "2024Test...1...1A")
        let url = await registry.browserURL(from: "ads", for: pub)

        XCTAssertNotNil(url)
        // ADS provider now returns abstract page for bibcode-only papers
        XCTAssertTrue(url?.absoluteString.contains("adsabs.harvard.edu") ?? false)
    }

    @MainActor
    func testRegistry_browserURLFromSource_withUnregisteredSource_returnsNil() async {
        let registry = BrowserURLProviderRegistry.shared

        let pub = createPublication(bibcode: "2024Test...1...1A")
        let url = await registry.browserURL(from: "nonexistent", for: pub)

        XCTAssertNil(url)
    }

    // MARK: - Helpers

    @MainActor
    private func createPublication(
        doi: String? = nil,
        bibcode: String? = nil
    ) -> CDPublication {
        let pub = CDPublication(context: persistenceController.viewContext)
        pub.id = UUID()
        pub.citeKey = "TestKey2024"
        pub.entryType = "article"
        pub.title = "Test Publication"
        pub.year = 2024
        pub.dateAdded = Date()
        pub.dateModified = Date()

        // Set doi directly on the CDPublication property
        pub.doi = doi

        // Set bibcode in fields (that's where it's stored)
        var fields: [String: String] = ["author": "Test Author"]
        if let bibcode = bibcode {
            fields["bibcode"] = bibcode
        }
        pub.fields = fields

        return pub
    }
}
