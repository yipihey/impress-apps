//
//  PaneLayoutStoreTests.swift
//  Headless coverage for the declarative pane-layout system: persistence
//  round-trips, named save/apply/delete, and built-in starter layouts.
//  Runs in `autonomous-test.sh quick` (no app launch).
//

import XCTest
@testable import PublicationManagerCore

@MainActor
final class PaneLayoutStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PaneLayoutStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultStateAndStarterLayouts() {
        let store = PaneLayoutStore(defaults: defaults)
        XCTAssertTrue(store.current.sidebarVisible)
        XCTAssertTrue(store.current.detailPaneVisible)
        XCTAssertEqual(store.current.detailTab, "info")
        XCTAssertEqual(store.layouts.map(\.name), ["Triage", "Reading", "Full"])
    }

    func testCurrentStatePersistsAcrossInstances() {
        let store = PaneLayoutStore(defaults: defaults)
        store.current.sidebarVisible = false
        store.current.detailTab = "pdf"

        let reloaded = PaneLayoutStore(defaults: defaults)
        XCTAssertFalse(reloaded.current.sidebarVisible)
        XCTAssertEqual(reloaded.current.detailTab, "pdf")
        XCTAssertTrue(reloaded.current.detailPaneVisible)
    }

    func testSaveApplyRoundTrip() {
        let store = PaneLayoutStore(defaults: defaults)
        store.current.detailPaneVisible = false
        store.current.pdfDarkMode = true
        store.saveCurrent(named: "My Setup")

        store.current = PaneLayoutState()  // reset live state
        XCTAssertTrue(store.current.detailPaneVisible)

        XCTAssertTrue(store.applyLayout(named: "my setup", pushAppearance: false))
        XCTAssertFalse(store.current.detailPaneVisible)
        XCTAssertTrue(store.current.pdfDarkMode)
    }

    func testSaveSameNameReplaces() {
        let store = PaneLayoutStore(defaults: defaults)
        let countBefore = store.layouts.count
        store.current.sidebarVisible = false
        store.saveCurrent(named: "X")
        store.current.sidebarVisible = true
        store.saveCurrent(named: "X")
        XCTAssertEqual(store.layouts.count, countBefore + 1)
        XCTAssertEqual(store.layouts.first(where: { $0.name == "X" })?.state.sidebarVisible, true)
    }

    func testApplyUnknownLayoutReturnsFalse() {
        let store = PaneLayoutStore(defaults: defaults)
        XCTAssertFalse(store.applyLayout(named: "does-not-exist", pushAppearance: false))
    }

    func testDeleteAndPersistLayouts() {
        let store = PaneLayoutStore(defaults: defaults)
        store.saveCurrent(named: "Doomed")
        guard let doomed = store.layouts.first(where: { $0.name == "Doomed" }) else {
            return XCTFail("missing saved layout")
        }
        store.delete(doomed)
        XCTAssertNil(store.layouts.first(where: { $0.name == "Doomed" }))

        let reloaded = PaneLayoutStore(defaults: defaults)
        XCTAssertNil(reloaded.layouts.first(where: { $0.name == "Doomed" }))
    }
}
