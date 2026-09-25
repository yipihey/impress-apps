#if os(macOS)
//
//  LayoutOutlineRouterTests.swift
//  PublicationManagerCoreTests
//
//  The outline pane's behaviour against a REAL `SharedLayout` on an
//  in-memory store (plan wave 7, T4): the sidebar follows a list an agent
//  retargeted (PH-H5), a click is all-or-nothing (PH-M2), the pane's state
//  outlives a remount (PH-M6), and an Edit Feed… route survives the lossy
//  `feed-form` node (PH-M1).
//

import ImpressLayout
import ImpressRustCore
import XCTest

@testable import PublicationManagerCore

@MainActor
final class LayoutOutlineRouterTests: XCTestCase {

    private var controller: LayoutController!
    private var state: LayoutOutlinePaneState!
    private var router: LayoutOutlineRouter!
    private var navigator: UInt64 = 0

    override func setUp() async throws {
        let store = try SharedStore.openInMemory()
        let layout = SharedLayout.open(store: store, appId: "imbib", device: nil)
        controller = LayoutController(layout: layout, appID: "imbib", store: store)
        navigator = try XCTUnwrap(controller.paneWithRole("navigator"), "imbib's preset has no navigator")
        XCTAssertNotNil(controller.paneWithRole("list"), "imbib's preset has no list pane")
        state = LayoutOutlinePaneState()
        router = LayoutOutlineRouter(
            controller: controller, tile: navigator, shell: .imbib, dismissedLibraryID: nil, state: state)
    }

    override func tearDown() async throws {
        controller.stop()
        controller = nil
        router = nil
        state = nil
    }

    // MARK: Helpers

    private func listSpecJSON() throws -> String {
        try XCTUnwrap(controller.pane(XCTUnwrap(controller.paneWithRole("list")))?.specJson)
    }

    private func detailSpecJSON() -> String {
        controller.paneWithRole("detail").flatMap { controller.pane($0)?.specJson } ?? ""
    }

    /// What an agent does: ask Rust for a row's verbs and apply them as
    /// `agent`, never through the outline.
    private func agentRoutes(toNode node: LayoutJSONValue) throws {
        let raw = try outlineRowVerbsJson(
            appId: "imbib", nodeJson: node.jsonString(), bindingsJson: "",
            listSpecJson: listSpecJSON(), detailSpecJson: detailSpecJSON(), initial: false)
        let verbs = try XCTUnwrap(LayoutJSONValue.decode(raw)["verbs"]?.arrayValue)
        XCTAssertFalse(verbs.isEmpty, "the agent's route changed nothing")
        for verb in verbs {
            _ = try controller.applyVerbJSON(verb.jsonString(), actor: "agent")
        }
    }

    // MARK: PH-H5 — the sidebar follows the list

    func testTheSidebarFollowsAListAnAgentRetargeted() throws {
        router.route(.inbox, initial: false)
        XCTAssertEqual(state.routedTab, .inbox)

        let library = UUID()
        try agentRoutes(toNode: .object([
            "node": .string("library"), "id": .string(library.uuidString.lowercased()),
        ]))
        router.listMayHaveMoved(at: controller.version)

        XCTAssertEqual(state.routedTab, .library(library), "the outline still thinks it routed the Inbox")
        XCTAssertEqual(state.viewModel.selectedTab, .library(library), "the sidebar still shows the Inbox")
    }

    func testAListNoRowMatchesDeselectsAndTheSameRowRoutesAgain() throws {
        // A library row: a real query (the test store has no Inbox library,
        // so the Inbox row would be a scoped legacy pane, whose query nobody
        // sees).
        let library = UUID()
        router.route(.library(library), initial: false)
        XCTAssertEqual(state.routedTab, .library(library))
        let libraryQuery = try XCTUnwrap(router.currentListSpec?.query)

        // An agent narrows the list to something no sidebar row is.
        var query = try XCTUnwrap(libraryQuery.objectValue)
        var filters = query["filters"]?.arrayValue ?? []
        filters.append(.object(["filter": .string("starred"), "starred": .bool(true)]))
        query["filters"] = .array(filters)
        let setQuery = LayoutJSONValue.object([
            "verb": .string("set-query"),
            "target": LayoutPaneRef.role("list").json,
            "query": .object(query),
        ])
        _ = try controller.applyVerbJSON(setQuery.jsonString(), actor: "agent")
        router.listMayHaveMoved(at: controller.version)

        XCTAssertNil(state.routedTab, "the dedupe still claims the library, so clicking it would do nothing")
        XCTAssertNil(state.viewModel.selectedTab, "the sidebar still highlights a row the list is not on")

        // One click on the row the user wants back.
        router.route(.library(library), initial: false)
        XCTAssertEqual(state.routedTab, .library(library))
        XCTAssertEqual(router.currentListSpec?.query, libraryQuery, "the click did not put the list back")
    }

    /// The Inbox's query is its library's too; the row that comes back is
    /// the one a person would pick, Inbox — not the library by id (seen live
    /// in impress, 2026-09-25).
    func testAListBackOnTheInboxQuerySelectsTheInboxRow() throws {
        _ = UndoCoordinator.performAutomatic("test setup") { InboxManager.shared.getOrCreateInbox() }
        router.route(.inbox, initial: false)
        try XCTSkipIf(state.routedTab != .inbox, "the Inbox did not route in this environment")
        let inboxQuery = try XCTUnwrap(router.currentListSpec?.query)

        var query = try XCTUnwrap(inboxQuery.objectValue)
        query["filters"] = .array((query["filters"]?.arrayValue ?? []) + [
            .object(["filter": .string("starred"), "starred": .bool(true)]),
        ])
        for next in [LayoutJSONValue.object(query), inboxQuery] {
            let verb = LayoutJSONValue.object([
                "verb": .string("set-query"), "target": LayoutPaneRef.role("list").json, "query": next,
            ])
            _ = try controller.applyVerbJSON(verb.jsonString(), actor: "agent")
            router.listMayHaveMoved(at: controller.version)
        }
        XCTAssertEqual(state.routedTab, .inbox)
    }

    func testTheOutlinesOwnRoutingIsNotMistakenForSomeoneElses() throws {
        router.route(.inbox, initial: false)
        let seen = state.lastListSpec
        XCTAssertNotNil(seen)
        router.listMayHaveMoved(at: controller.version)
        XCTAssertEqual(state.routedTab, .inbox)
        XCTAssertEqual(state.lastListSpec, seen)
    }

    // MARK: PH-M2 — a click is all or nothing

    func testARefusedVerbRollsBackTheOnesBeforeIt() throws {
        let tree = try XCTUnwrap(controller.tree)
        let before = tree.selection(onChannelOf: navigator, kind: "library")
        let library = UUID().uuidString.lowercased()
        let verbs: [LayoutJSONValue] = [
            .object([
                "verb": .string("select"),
                "target": LayoutPaneRef.role("navigator").json,
                "kind": .string("library"),
                "ids": .array([.string(library)]),
            ]),
            // Refused: no pane carries this role.
            .object([
                "verb": .string("set-view-kind"),
                "target": LayoutPaneRef.role("no-such-role").json,
                "view_kind": .string("list"),
            ]),
        ]

        XCTAssertFalse(router.applyAtomically(verbs, for: "test"))
        let after = try XCTUnwrap(controller.tree).selection(onChannelOf: navigator, kind: "library")
        XCTAssertEqual(after, before, "the first verb of a refused click stayed applied")
        XCTAssertFalse(after.contains(library))
    }

    // MARK: PH-M6 — state outlives the view

    func testAPaneKeepsItsStateAcrossARemount() throws {
        let pane = try XCTUnwrap(controller.pane(navigator))
        let context = PaneContext(tile: navigator, pane: pane, spec: nil, controller: controller)
        let first = LayoutOutlinePaneState.state(for: context)
        first.routedTab = .inbox
        let again = LayoutOutlinePaneState.state(for: context)
        XCTAssertTrue(first === again, "a remount built a new sidebar view model")
        XCTAssertTrue(first.viewModel === again.viewModel)
        XCTAssertEqual(again.routedTab, .inbox)
    }

    // MARK: PH-M1 — Edit Feed… opens the feed's form

    func testTheFeedFormNodeIsLossyAndTheRecordedRouteIsNot() throws {
        let feed = UUID()
        let (node, _) = LayoutOutlineNode.node(for: .editFeed(feed), shell: .imbib, dismissedLibraryID: nil)
        // The wire loss the review found; it stays until Rust's node carries
        // the ids.
        XCTAssertEqual(LayoutOutlineNode.tab(from: node), .addFeed)

        let routes = LayoutFeedFormRoutes.shared
        let list = try XCTUnwrap(controller.paneWithRole("list"))
        routes.record(.editFeed(feed), into: list, of: controller)
        XCTAssertEqual(routes.resolved(.addFeed, tile: list, controller: controller), .editFeed(feed))

        let library = UUID()
        routes.record(.addLibraryFeed(library), into: list, of: controller)
        XCTAssertEqual(routes.resolved(.addFeed, tile: list, controller: controller), .addLibraryFeed(library))

        // Any other route clears it; a node that is not the feed form is
        // never rewritten.
        routes.record(.inbox, into: list, of: controller)
        XCTAssertEqual(routes.resolved(.addFeed, tile: list, controller: controller), .addFeed)
        XCTAssertEqual(routes.resolved(.inbox, tile: list, controller: controller), .inbox)
    }
}
#endif
