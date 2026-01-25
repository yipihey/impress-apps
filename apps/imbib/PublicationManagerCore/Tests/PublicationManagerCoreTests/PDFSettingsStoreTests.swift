//
//  PDFSettingsStoreTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class PDFSettingsStoreTests: XCTestCase {

    var store: PDFSettingsStore!
    var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Use a separate UserDefaults suite for testing
        testDefaults = UserDefaults(suiteName: "PDFSettingsStoreTests-\(UUID().uuidString)")!
        store = PDFSettingsStore(userDefaults: testDefaults)
    }

    override func tearDown() {
        // Clean up test suite
        testDefaults.removePersistentDomain(forName: testDefaults.description)
        super.tearDown()
    }

    // MARK: - Default Settings Tests

    func testDefaultSettings() async {
        // Given - fresh store with no saved settings

        // When
        let settings = await store.settings

        // Then - should return defaults
        XCTAssertEqual(settings.sourcePriority, .preprint)
        XCTAssertEqual(settings.libraryProxyURL, "")
        XCTAssertFalse(settings.proxyEnabled)
    }

    // MARK: - Source Priority Tests

    func testUpdateSourcePriority_toPublisher() async {
        // Given
        let initialSettings = await store.settings
        XCTAssertEqual(initialSettings.sourcePriority, .preprint)

        // When
        await store.updateSourcePriority(.publisher)

        // Then
        let updatedSettings = await store.settings
        XCTAssertEqual(updatedSettings.sourcePriority, .publisher)
    }

    func testUpdateSourcePriority_toPreprint() async {
        // Given - set to publisher first
        await store.updateSourcePriority(.publisher)

        // When
        await store.updateSourcePriority(.preprint)

        // Then
        let settings = await store.settings
        XCTAssertEqual(settings.sourcePriority, .preprint)
    }

    // MARK: - Library Proxy Tests

    func testUpdateLibraryProxy_enableWithURL() async {
        // Given
        let proxyURL = "https://stanford.idm.oclc.org/login?url="

        // When
        await store.updateLibraryProxy(url: proxyURL, enabled: true)

        // Then
        let settings = await store.settings
        XCTAssertTrue(settings.proxyEnabled)
        XCTAssertEqual(settings.libraryProxyURL, proxyURL)
    }

    func testUpdateLibraryProxy_disablePreservesURL() async {
        // Given - enable proxy first
        let proxyURL = "https://example.edu/proxy?url="
        await store.updateLibraryProxy(url: proxyURL, enabled: true)

        // When - disable but keep URL
        await store.updateLibraryProxy(url: proxyURL, enabled: false)

        // Then - URL should be preserved but disabled
        let settings = await store.settings
        XCTAssertFalse(settings.proxyEnabled)
        XCTAssertEqual(settings.libraryProxyURL, proxyURL)
    }

    func testUpdateLibraryProxy_emptyURL() async {
        // Given - enable proxy with URL
        await store.updateLibraryProxy(url: "https://test.edu/", enabled: true)

        // When - clear URL
        await store.updateLibraryProxy(url: "", enabled: true)

        // Then
        let settings = await store.settings
        XCTAssertTrue(settings.proxyEnabled)
        XCTAssertEqual(settings.libraryProxyURL, "")
    }

    // MARK: - Persistence Tests

    func testSettingsPersistAcrossInstances() async {
        // Given
        await store.updateSourcePriority(.publisher)
        await store.updateLibraryProxy(url: "https://test.edu/proxy?url=", enabled: true)

        // When - create a new store with same UserDefaults
        await store.clearCache()
        let newStore = PDFSettingsStore(userDefaults: testDefaults)

        // Then - settings should persist
        let settings = await newStore.settings
        XCTAssertEqual(settings.sourcePriority, .publisher)
        XCTAssertTrue(settings.proxyEnabled)
        XCTAssertEqual(settings.libraryProxyURL, "https://test.edu/proxy?url=")
    }

    func testReset_clearsAllSettings() async {
        // Given - customize settings
        await store.updateSourcePriority(.publisher)
        await store.updateLibraryProxy(url: "https://test.edu/", enabled: true)

        // When
        await store.reset()

        // Then - should return to defaults
        let settings = await store.settings
        XCTAssertEqual(settings.sourcePriority, .preprint)
        XCTAssertFalse(settings.proxyEnabled)
        XCTAssertEqual(settings.libraryProxyURL, "")
    }

    // MARK: - PDFSettings Codable Tests

    func testPDFSettings_codableRoundTrip() throws {
        // Given
        let settings = PDFSettings(
            sourcePriority: .publisher,
            libraryProxyURL: "https://stanford.idm.oclc.org/login?url=",
            proxyEnabled: true
        )

        // When
        let encoder = JSONEncoder()
        let data = try encoder.encode(settings)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PDFSettings.self, from: data)

        // Then
        XCTAssertEqual(decoded, settings)
    }

    func testPDFSettings_equatable() {
        // Given
        let settings1 = PDFSettings(
            sourcePriority: .preprint,
            libraryProxyURL: "https://test.edu/",
            proxyEnabled: true
        )
        let settings2 = PDFSettings(
            sourcePriority: .preprint,
            libraryProxyURL: "https://test.edu/",
            proxyEnabled: true
        )
        let settings3 = PDFSettings(
            sourcePriority: .publisher,
            libraryProxyURL: "https://test.edu/",
            proxyEnabled: true
        )

        // Then
        XCTAssertEqual(settings1, settings2)
        XCTAssertNotEqual(settings1, settings3)
    }

    // MARK: - PDFSourcePriority Tests

    func testPDFSourcePriority_displayName() {
        XCTAssertEqual(PDFSourcePriority.preprint.displayName, "Preprint (arXiv, etc.)")
        XCTAssertEqual(PDFSourcePriority.publisher.displayName, "Publisher")
    }

    func testPDFSourcePriority_description() {
        XCTAssertEqual(PDFSourcePriority.preprint.description, "Free and always accessible")
        XCTAssertEqual(PDFSourcePriority.publisher.description, "Original version, may require proxy")
    }

    func testPDFSourcePriority_allCases() {
        XCTAssertEqual(PDFSourcePriority.allCases.count, 2)
        XCTAssertTrue(PDFSourcePriority.allCases.contains(.preprint))
        XCTAssertTrue(PDFSourcePriority.allCases.contains(.publisher))
    }

    // MARK: - Common Proxies Tests

    func testCommonProxies_notEmpty() {
        XCTAssertFalse(PDFSettings.commonProxies.isEmpty)
    }

    func testCommonProxies_containsStanford() {
        let stanford = PDFSettings.commonProxies.first { $0.name == "Stanford" }
        XCTAssertNotNil(stanford)
        XCTAssertEqual(stanford?.url, "https://stanford.idm.oclc.org/login?url=")
    }

    func testCommonProxies_allHaveValidURLs() {
        for proxy in PDFSettings.commonProxies {
            XCTAssertFalse(proxy.name.isEmpty, "Proxy name should not be empty")
            XCTAssertFalse(proxy.url.isEmpty, "Proxy URL should not be empty")
            XCTAssertTrue(
                proxy.url.hasPrefix("https://") || proxy.url.hasPrefix("http://"),
                "Proxy URL should use HTTP(S): \(proxy.name)"
            )
            XCTAssertTrue(proxy.url.hasSuffix("url="), "Proxy URL should end with 'url=': \(proxy.name)")
        }
    }
}
