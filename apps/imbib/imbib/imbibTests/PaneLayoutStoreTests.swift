//
//  PaneLayoutStoreTests.swift
//  Headless coverage for the declarative pane-layout system: persistence
//  round-trips, named save/apply/delete, and built-in starter layouts.
//  The model is imbib's own window's (this app target) since plan wave 6
//  W5 pass B; these tests moved from PublicationManagerCore with it.
//

import PublicationManagerCore
import XCTest
@testable import imbib

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

    // MARK: - The hooks the shared views and the router reach it through

    /// `HostWindowPanes` is the same state as `current`: the shared views and
    /// the chords write through it, and saved layouts read `current`.
    func testHostWindowPanesForwardToCurrent() {
        let store = PaneLayoutStore(defaults: defaults)
        let panes: any HostWindowPanes = store
        panes.listPaneVisible = false
        panes.detailTab = "pdf"
        XCTAssertFalse(store.current.listPaneVisible)
        XCTAssertEqual(store.current.detailTab, "pdf")
        store.current.sidebarVisible = false
        XCTAssertFalse(panes.sidebarVisible)
    }

    private func route(
        _ store: PaneLayoutStore, _ method: String, _ path: String, _ body: [String: Any]? = nil
    ) -> (Int, [String: Any]) {
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let reply = store.layoutRoute(path: path, method: method, body: data)
        let object = (try? JSONSerialization.jsonObject(with: reply.json)) as? [String: Any] ?? [:]
        return (reply.status, object)
    }

    /// The three routes answer as PublicationManagerCore's router did before
    /// the move, and every success names the model.
    func testLayoutRoutesDriveThisWindowsModel() {
        let store = PaneLayoutStore(defaults: defaults)

        let (getStatus, got) = route(store, "GET", "/api/layout")
        XCTAssertEqual(getStatus, 200)
        XCTAssertEqual(got["model"] as? String, "pane-layout-state")
        XCTAssertEqual((got["layouts"] as? [[String: Any]])?.count, 3)

        let (setStatus, set) = route(store, "POST", "/api/layout", ["detailPaneVisible": false])
        XCTAssertEqual(setStatus, 200)
        XCTAssertEqual((set["current"] as? [String: Any])?["detailPaneVisible"] as? Bool, false)
        XCTAssertFalse(store.current.detailPaneVisible)

        XCTAssertEqual(route(store, "POST", "/api/layout").0, 400)

        let (saveStatus, saved) = route(store, "POST", "/api/layout/save", ["name": "Mine"])
        XCTAssertEqual(saveStatus, 200)
        XCTAssertEqual((saved["layouts"] as? [String])?.last, "Mine")

        // A successful apply pushes the layout's appearance into the app's real
        // theme stores, so it is covered by `applyLayout(pushAppearance: false)`
        // above rather than through the route.
        XCTAssertEqual(route(store, "POST", "/api/layout/apply", ["name": "Nope"]).0, 404)
    }

    /// `/api/appearance` writes the authoritative stores, then mirrors here.
    func testAppearanceMirrorsIntoCurrent() {
        let store = PaneLayoutStore(defaults: defaults)
        store.appearanceDidChange(appAppearance: "dark", pdfDarkMode: nil)
        XCTAssertEqual(store.current.appAppearance, "dark")
        XCTAssertFalse(store.current.pdfDarkMode)
        store.appearanceDidChange(appAppearance: nil, pdfDarkMode: true)
        XCTAssertTrue(store.current.pdfDarkMode)
    }
}
