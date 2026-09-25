#if os(macOS)
//
//  LayoutControllerFFITests.swift
//  ImpressLayoutTests
//
//  The SEAM, not the pure parts (review SK-K20): `LayoutController` driving a
//  real `SharedLayout` on `SharedStore.openInMemory()`, so every verb is
//  parsed and applied by Rust, and every assertion is about what the
//  controller did with Rust's answer.
//
//  What these pin, by review id:
//  - PH-H1 = SK-K6: a verb makes stale exactly the panes Rust names — a
//    focus or a resize none, a set-query one;
//  - SK-K7 / PH-M3: errors are scoped (a refusal is not a pane's error);
//  - SK-K8: a tree that does not decode is not adopted and the version
//    stays put;
//  - SK-K13: ⌘Z routing, including the fall-through to the responder chain;
//  - SK-K10 + PH-H3: several windows, each registered by identity;
//  - SK-K23: the sessions a verb closes are named.
//

import ImpressRustCore
import XCTest

@testable import ImpressLayout

@MainActor
final class LayoutControllerFFITests: XCTestCase {

    private var controllers: [LayoutController] = []

    override func tearDown() async throws {
        for controller in controllers { controller.stop() }
        controllers = []
        try await super.tearDown()
    }

    /// A controller over impress's cold-start tree (navigator + list +
    /// detail) in a store of its own.
    private func makeController(appID: String = "impress") throws -> LayoutController {
        let store = try SharedStore.openInMemory()
        let layout = SharedLayout.open(store: store, appId: appID, device: nil)
        let controller = LayoutController(
            layout: layout, appID: appID, store: store, startupGraceSecs: 0)
        controllers.append(controller)
        return controller
    }

    private func tile(_ controller: LayoutController, role: String) throws -> UInt64 {
        try XCTUnwrap(controller.paneWithRole(role), "the impress preset has a \(role) pane")
    }

    private func tokens(_ controller: LayoutController) -> [UInt64: UInt64] {
        guard let tree = controller.tree, let window = tree.firstWindow else { return [:] }
        var out: [UInt64: UInt64] = [:]
        for leaf in tree.leaves(of: window.root) { out[leaf] = controller.refreshToken(for: leaf) }
        return out
    }

    private func stale(_ before: [UInt64: UInt64], _ after: [UInt64: UInt64]) -> Set<UInt64> {
        Set(after.keys.filter { before[$0] != after[$0] })
    }

    // MARK: PH-H1 = SK-K6 — only the panes Rust names redraw

    func testTheColdStartTreeDecodesWithThreeRoledPanes() throws {
        let controller = try makeController()
        XCTAssertNotNil(controller.tree)
        XCTAssertNil(controller.treeError)
        for role in ["navigator", "list", "detail"] {
            XCTAssertNotNil(controller.paneWithRole(role), role)
        }
    }

    func testAFocusMakesNoPaneStale() throws {
        let controller = try makeController()
        let list = try tile(controller, role: "list")
        let detail = try tile(controller, role: "detail")
        XCTAssertTrue(controller.apply(.focus(target: .id(list))))
        let before = tokens(controller)
        let globalBefore = controller.refreshToken
        let versionBefore = controller.version

        XCTAssertTrue(controller.apply(.focus(target: .id(detail))))

        XCTAssertGreaterThan(controller.version, versionBefore, "the verb applied")
        XCTAssertEqual(controller.focused, detail)
        XCTAssertEqual(stale(before, tokens(controller)), [], "a focus redraws no pane")
        XCTAssertEqual(controller.refreshToken, globalBefore, "nor moves the compatibility token")
    }

    func testAFocusDirectionMakesNoPaneStale() throws {
        let controller = try makeController()
        let before = tokens(controller)
        XCTAssertTrue(controller.apply(.focusDirection(.right)))
        XCTAssertEqual(stale(before, tokens(controller)), [])
    }

    func testAResizeMakesNoPaneStale() throws {
        let controller = try makeController()
        let list = try tile(controller, role: "list")
        let before = tokens(controller)
        let globalBefore = controller.refreshToken
        XCTAssertTrue(controller.apply(.resizeShare(pane: list, share: 2.5)))
        XCTAssertEqual(stale(before, tokens(controller)), [], "a divider drag redraws no pane")
        XCTAssertEqual(controller.refreshToken, globalBefore)
        XCTAssertEqual(try XCTUnwrap(controller.tree?.share(of: list)), 2.5, accuracy: 1e-4)
    }

    func testASetQueryMakesExactlyThatPaneStale() throws {
        let controller = try makeController()
        let list = try tile(controller, role: "list")
        var query = try XCTUnwrap(controller.tree?.pane(list)?.query.objectValue)
        query["limit"] = .int(7)
        let verb = LayoutJSONValue.object([
            "verb": .string("set-query"),
            "target": LayoutPaneRef.id(list).json,
            "query": .object(query),
        ])
        let before = tokens(controller)
        let globalBefore = controller.refreshToken

        _ = try controller.applyVerbJSON(verb.jsonString(), actor: LayoutController.guiActor)

        XCTAssertEqual(stale(before, tokens(controller)), [list], "one pane's query changed")
        XCTAssertEqual(controller.refreshToken, globalBefore &+ 1)
        XCTAssertTrue(controller.invalidatedPanes.contains(list))
        controller.didRefresh(list)
        XCTAssertFalse(controller.invalidatedPanes.contains(list))
    }

    func testASelectMakesThePublisherAndItsListenersStale() throws {
        let controller = try makeController()
        let list = try tile(controller, role: "list")
        let navigator = try tile(controller, role: "navigator")
        let kind = try XCTUnwrap(controller.tree?.pane(list)?.queryKinds.first)
        let before = tokens(controller)

        XCTAssertTrue(
            controller.apply(.select(pane: list, kind: kind, ids: [UUID().uuidString.lowercased()])))

        let redrawn = stale(before, tokens(controller))
        XCTAssertTrue(redrawn.contains(list), "the publishing pane")
        XCTAssertFalse(redrawn.contains(navigator), "a pane that does not listen is untouched")
    }

    func testAnExternalReloadMakesEveryPaneStale() throws {
        let controller = try makeController()
        let before = tokens(controller)
        controller.reload()
        XCTAssertEqual(stale(before, tokens(controller)), Set(before.keys))
    }

    // MARK: SK-K7 / PH-M3 — errors are scoped

    func testARefusedVerbIsARefusalNotAPaneError() throws {
        let controller = try makeController()
        let list = try tile(controller, role: "list")
        let versionBefore = controller.version

        XCTAssertFalse(controller.apply(.close(target: .id(987_654))))

        XCTAssertEqual(controller.version, versionBefore, "a refusal changes nothing")
        let refusal = try XCTUnwrap(controller.lastRefusal)
        XCTAssertTrue(refusal.hasPrefix("close refused:"), refusal)
        XCTAssertFalse(refusal.contains("Layout(message:"), "the message, not the enum dump")
        XCTAssertNil(controller.paneError(for: list), "another pane's state is not an error")
        XCTAssertNil(controller.treeError)

        // An empty result after an unrelated refusal is still just empty.
        let rows = try controller.loadRows(for: list)
        XCTAssertTrue(rows.isEmpty, "a fresh store has no rows")
        XCTAssertNil(controller.paneError(for: list))
        XCTAssertNil(controller.lastError, "the last call succeeded")

        // And the next applied verb clears the refusal.
        XCTAssertTrue(controller.apply(.focus(target: .id(list))))
        XCTAssertNil(controller.lastRefusal)
    }

    /// A page says how many rows the query has in all (review PH-H4,
    /// SK-K9): an empty store is a page of 0 of 0, not truncated.
    func testAPageSaysItsTotal() throws {
        let controller = try makeController()
        let list = try tile(controller, role: "list")
        let page = try controller.loadPage(for: list)
        XCTAssertEqual(page.rows.count, 0)
        XCTAssertEqual(page.total, 0)
        XCTAssertFalse(page.truncated)
        XCTAssertEqual(LayoutController.pageSize, 500)
    }

    /// Several verbs are ONE gesture (review PH-M2): one version, one ⌘Z,
    /// and a refused verb applies none of them.
    func testApplyAllIsOneGesture() throws {
        let controller = try makeController()
        let list = try tile(controller, role: "list")
        let detail = try tile(controller, role: "detail")
        let before = controller.version
        let verbs = LayoutJSONValue.array([
            LayoutVerb.focus(target: .id(list)).verbJSON!,
            LayoutVerb.setViewKind(target: .id(detail), viewKind: .notes).verbJSON!,
        ])
        try controller.applyAll(verbs.jsonString(), label: "test")
        XCTAssertEqual(controller.version, before + 1, "one gesture, one version")
        XCTAssertEqual(controller.tree?.pane(detail)?.viewKind, "notes")

        let refused = LayoutJSONValue.array([
            LayoutVerb.setViewKind(target: .id(detail), viewKind: .bibtex).verbJSON!,
            LayoutVerb.close(target: .id(987_654)).verbJSON!,
        ])
        XCTAssertThrowsError(try controller.applyAll(refused.jsonString(), label: "refused"))
        XCTAssertEqual(controller.tree?.pane(detail)?.viewKind, "notes", "nothing applied")
    }

    func testAPaneThatDoesNotResolveKeepsItsOwnError() throws {
        let controller = try makeController()
        let list = try tile(controller, role: "list")
        XCTAssertNil(controller.pane(987_654))
        XCTAssertNotNil(controller.paneError(for: 987_654))
        XCTAssertNil(controller.paneError(for: list))
        XCTAssertThrowsError(try controller.loadRows(for: 987_654))
        // A success clears only that pane's error.
        XCTAssertNotNil(controller.pane(list))
        XCTAssertNotNil(controller.paneError(for: 987_654))
    }

    // MARK: SK-K8 — decode failure is not adopted

    func testATreeThatDoesNotDecodeIsNotAdoptedAndKeepsTheVersion() throws {
        let controller = try makeController()
        let tree = controller.tree
        let version = controller.version

        XCTAssertFalse(controller.adopt(layoutJSON: #"{"windows": 7}"#, version: version + 5, focused: nil))

        XCTAssertEqual(controller.version, version, "the version of a tree not on screen is not claimed")
        XCTAssertEqual(controller.tree, tree, "the last good tree stays")
        XCTAssertNotNil(controller.treeError)
        XCTAssertTrue(LayoutController.isNewer(version + 5, than: controller.version),
            "so the feed's report of that version still reloads")

        controller.reload()
        XCTAssertNil(controller.treeError, "a tree that decodes clears it")
    }

    // MARK: Every verb the controller spells reaches Rust's parser

    func testEveryTreeVerbIsAcceptedByRust() throws {
        let controller = try makeController()
        let list = try tile(controller, role: "list")
        let detail = try tile(controller, role: "detail")

        XCTAssertTrue(controller.apply(.split(target: .id(detail), dir: .vertical, after: true, new: nil)))
        let added = try XCTUnwrap(controller.tree?.firstWindow.map { controller.tree!.leaves(of: $0.root) }?
            .first { ![list, detail].contains($0) && controller.tree?.pane($0)?.role == nil })
        XCTAssertTrue(controller.apply(.setViewKind(target: .id(added), viewKind: .console)))
        XCTAssertTrue(controller.apply(.setRole(target: .id(added), role: "preview")))
        XCTAssertTrue(controller.apply(.setRole(target: .id(added), role: nil)))
        XCTAssertTrue(controller.apply(.maximize(target: .id(added))))
        XCTAssertTrue(controller.apply(.restore))
        XCTAssertTrue(controller.apply(.move(tile: .id(added), target: .id(list), placement: .below)))
        XCTAssertTrue(controller.apply(.focus(target: .role("detail"))))
        XCTAssertTrue(controller.apply(.close(target: .id(added))))
        XCTAssertNil(controller.lastRefusal)
    }

    // MARK: Roles (⌃⌘S / ⌥⌘0 / ⌘0)

    /// ⌃⌘S restores EXACTLY the share the pane had — Rust remembers it on
    /// the pane's spec (review RL-L13) — not the siblings' average.
    func testToggleRoleCollapsesAndRestoresTheExactShare() throws {
        let controller = try makeController()
        let list = try tile(controller, role: "list")
        let expected = try XCTUnwrap(controller.tree?.share(of: list))

        controller.toggleRole("list")
        XCTAssertTrue(controller.roleIsCollapsed("list"))

        controller.toggleRole("list")
        XCTAssertFalse(controller.roleIsCollapsed("list"))
        XCTAssertEqual(try XCTUnwrap(controller.tree?.share(of: list)), expected, accuracy: 1e-4)
    }

    // MARK: SK-K13 — ⌘Z routing

    func testUndoChordPassesToTheChainWhileTyping() throws {
        let controller = try makeController()
        let version = controller.version
        XCTAssertFalse(controller.routeUndoChord(redo: false, textIsFirstResponder: true))
        XCTAssertEqual(controller.version, version, "the tree did not act")
    }

    func testUndoChordFallsThroughWhenTheRingIsEmpty() throws {
        let controller = try makeController()
        let before = tokens(controller)
        XCTAssertFalse(
            controller.routeUndoChord(redo: false, textIsFirstResponder: false),
            "an empty exploration ring hands ⌘Z to the window's undo manager")
        // Rust names every pane for an empty-ring undo; nothing changed, so
        // nothing is redrawn.
        XCTAssertEqual(stale(before, tokens(controller)), [])
    }

    func testUndoChordUndoesTheFocusedPanesSelection() throws {
        let controller = try makeController()
        let list = try tile(controller, role: "list")
        let kind = try XCTUnwrap(controller.tree?.pane(list)?.queryKinds.first)
        let id = UUID().uuidString.lowercased()
        XCTAssertTrue(controller.apply(.focus(target: .id(list))))
        XCTAssertTrue(controller.apply(.select(pane: list, kind: kind, ids: [id])))
        XCTAssertEqual(controller.tree?.selection(onChannelOf: list, kind: kind), [id])

        XCTAssertTrue(controller.routeUndoChord(redo: false, textIsFirstResponder: false))
        XCTAssertEqual(controller.tree?.selection(onChannelOf: list, kind: kind) ?? [], [])

        XCTAssertTrue(controller.routeUndoChord(redo: true, textIsFirstResponder: false))
        XCTAssertEqual(controller.tree?.selection(onChannelOf: list, kind: kind), [id])
    }

    // MARK: SK-K14 — the root's keys reach the focused pane

    func testKeysReachOnlyTheFocusedPanesHandler() throws {
        let controller = try makeController()
        let list = try tile(controller, role: "list")
        let detail = try tile(controller, role: "detail")
        let owner = NSObject()
        var heard: [PaneKey] = []
        controller.setKeyHandler(for: detail, owner: owner) { key in
            heard.append(key)
            return true
        }
        XCTAssertTrue(controller.apply(.focus(target: .id(list))))
        XCTAssertFalse(controller.routeKeyToFocusedPane(.down), "the list registered nothing")
        XCTAssertTrue(controller.apply(.focus(target: .id(detail))))
        XCTAssertTrue(controller.routeKeyToFocusedPane(.down))
        XCTAssertEqual(heard, [.down])

        // A late teardown by someone else does not remove it.
        controller.removeKeyHandler(for: detail, owner: NSObject())
        XCTAssertTrue(controller.routeKeyToFocusedPane(.up))
        controller.removeKeyHandler(for: detail, owner: owner)
        XCTAssertFalse(controller.routeKeyToFocusedPane(.up))
    }

    // MARK: SK-K23 — closed panes' sessions

    func testClosedSessionsAreThoseNoPaneCarriesAnyMore() throws {
        func tree(_ sessions: [UInt64: String?]) throws -> LayoutTree {
            var tiles: [String: LayoutJSONValue] = [:]
            for (tile, session) in sessions {
                var pane: [String: LayoutJSONValue] = ["view_kind": .string("source")]
                if let session { pane["session"] = .string(session) }
                tiles[String(tile)] = .object(["pane": .object(pane)])
            }
            let json = try LayoutJSONValue.object(["windows": .array([]), "tiles": .object(tiles)])
                .jsonString()
            return try LayoutTree.decode(json)
        }
        let before = try tree([1: "s-a", 2: "s-b", 3: nil])
        let moved = try tree([4: "s-a", 2: "s-b"])
        XCTAssertEqual(LayoutController.closedSessions(from: before, to: moved), [], "a moved session is not closed")
        let closed = try tree([2: "s-b"])
        XCTAssertEqual(LayoutController.closedSessions(from: before, to: closed), ["s-a"])
    }

    // MARK: SK-K10 + PH-H3 — several windows

    /// PublicationManagerCore's hooks, verbatim in shape: `didOpen` sets the
    /// one automation host, `didClose` clears it unconditionally.
    private final class HostSlot {
        var host: LayoutController?
        var opened: [ObjectIdentifier] = []
        var closed: [ObjectIdentifier] = []
    }

    private func services(_ slot: HostSlot) -> LayoutHostServices {
        LayoutHostServices(
            openStore: { nil },
            didOpen: { controller in
                slot.host = controller
                slot.opened.append(ObjectIdentifier(controller))
            },
            didClose: { controller in
                slot.host = nil
                slot.closed.append(ObjectIdentifier(controller))
            })
    }

    func testClosingOneWindowLeavesTheOtherRegistered() throws {
        let runtime = LayoutTreeRuntime()
        let slot = HostSlot()
        let first = try makeController()
        let second = try makeController()

        runtime.register(first, services: services(slot))
        runtime.register(second, services: services(slot))
        XCTAssertTrue(runtime.controller === second, "the newest window is current")
        XCTAssertTrue(slot.host === second)
        XCTAssertEqual(runtime.controllers.count, 2)

        // ⌘N, then close the new window: the first is current AND still the
        // automation host, although the host's didClose cleared the slot.
        runtime.unregister(second)
        XCTAssertTrue(runtime.controller === first)
        XCTAssertTrue(slot.host === first)
        XCTAssertEqual(slot.closed, [ObjectIdentifier(second)])
    }

    func testClosingABackgroundWindowKeepsTheKeyWindowTheHost() throws {
        let runtime = LayoutTreeRuntime()
        let slot = HostSlot()
        let first = try makeController()
        let second = try makeController()
        runtime.register(first, services: services(slot))
        runtime.register(second, services: services(slot))
        runtime.makeCurrent(first)
        XCTAssertTrue(slot.host === first, "a window becoming key takes the host")

        runtime.unregister(second)
        XCTAssertTrue(runtime.controller === first)
        XCTAssertTrue(slot.host === first, "closing another window does not unregister this one")

        runtime.unregister(first)
        XCTAssertNil(runtime.controller)
        XCTAssertNil(slot.host, "the last window closing leaves no host")
    }

    func testRegisteringTwiceDoesNotDuplicateAWindow() throws {
        let runtime = LayoutTreeRuntime()
        let slot = HostSlot()
        let controller = try makeController()
        runtime.register(controller, services: services(slot))
        runtime.register(controller, services: services(slot))
        XCTAssertEqual(runtime.controllers.count, 1)
        runtime.unregister(controller)
        runtime.unregister(controller)
        XCTAssertEqual(slot.closed.count, 1)
    }

    func testTheStartupGraceIsWhatIsLeftOfTheLaunchWindow() {
        let launched = Date(timeIntervalSince1970: 1_000)
        let runtime = LayoutTreeRuntime(launchedAt: launched)
        XCTAssertEqual(runtime.remainingStartupGrace(now: launched), 90)
        XCTAssertEqual(runtime.remainingStartupGrace(now: launched.addingTimeInterval(60)), 30)
        XCTAssertEqual(runtime.remainingStartupGrace(now: launched.addingTimeInterval(600)), 0)
    }
}
#endif
