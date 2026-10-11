#if os(macOS)
//
//  LayoutPaneMoveTests.swift
//  ImpressLayoutTests
//
//  The arrange menu and the pane-header drop are verbs that already exist.
//  These tests pin the mapping: a drop zone, a one-step move onto the
//  neighbour leaf, and each menu action's `LayoutVerb`. No store, no window.
//

import XCTest

@testable import ImpressLayout

final class LayoutPaneMoveTests: XCTestCase {

    private func golden() throws -> LayoutTree {
        let url = try KoineCheckout.file(
            "crates/impress-layout/tests/golden/three_column.json")
        let json = try String(contentsOf: url, encoding: .utf8)
        return try LayoutTree.decode(json)
    }

    // MARK: - Drop zones

    func testCenterOfAPaneIsTabs() {
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(LayoutPaneDrop.placement(at: CGPoint(x: 100, y: 50), in: size), .intoTabs)
    }

    func testEdgesPickThatSideAndATieKeepsTheEarlierEdge() {
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(LayoutPaneDrop.placement(at: CGPoint(x: 10, y: 50), in: size), .left)
        XCTAssertEqual(LayoutPaneDrop.placement(at: CGPoint(x: 190, y: 50), in: size), .right)
        XCTAssertEqual(LayoutPaneDrop.placement(at: CGPoint(x: 100, y: 8), in: size), .above)
        XCTAssertEqual(LayoutPaneDrop.placement(at: CGPoint(x: 100, y: 92), in: size), .below)
        // Equal distance to the left edge and the top edge: left is earlier.
        XCTAssertEqual(LayoutPaneDrop.placement(at: CGPoint(x: 10, y: 10), in: size), .left)
    }

    // MARK: - One step toward the neighbour

    /// The golden is panes 1 | 2 | 3, focus on 2. Right and below step onto 3;
    /// left and above step onto 1; tabs uses the next leaf.
    func testMenuMoveTargetsTheNeighbourLeaf() throws {
        let tree = try golden()
        XCTAssertEqual(LayoutPaneMove.neighbor(placement: .right, tree: tree, focused: 2), 3)
        XCTAssertEqual(LayoutPaneMove.neighbor(placement: .below, tree: tree, focused: 2), 3)
        XCTAssertEqual(LayoutPaneMove.neighbor(placement: .left, tree: tree, focused: 2), 1)
        XCTAssertEqual(LayoutPaneMove.neighbor(placement: .above, tree: tree, focused: 2), 1)
        XCTAssertEqual(LayoutPaneMove.neighbor(placement: .intoTabs, tree: tree, focused: 2), 3)
        XCTAssertNil(LayoutPaneMove.neighbor(placement: .left, tree: tree, focused: 1))
        XCTAssertEqual(LayoutPaneMove.neighbor(placement: .intoTabs, tree: tree, focused: 3), 2)
    }

    func testMenuMoveIsOneMoveTileVerb() throws {
        let tree = try golden()
        let verb = try XCTUnwrap(LayoutPaneMove.verb(placement: .right, tree: tree, focused: 2))
        XCTAssertEqual(verb, .move(tile: .id(2), target: .id(3), placement: .right))
        let json = try XCTUnwrap(verb.verbJSON).jsonString()
        XCTAssertEqual(
            json,
            #"{"placement":"right","target":{"id":3},"tile":{"id":2},"verb":"move-tile"}"#)
        XCTAssertNil(LayoutPaneMove.verb(placement: .left, tree: tree, focused: 1))
    }

    // MARK: - The menu's other verbs

    func testEachArrangeActionIsTheExistingVerb() throws {
        XCTAssertEqual(
            LayoutArrange.splitRight.verb,
            .split(target: .focused, dir: .horizontal, after: true, new: nil))
        XCTAssertEqual(
            LayoutArrange.splitBelow.verb,
            .split(target: .focused, dir: .vertical, after: true, new: nil))
        XCTAssertEqual(LayoutArrange.close.verb, .close(target: .focused))
        XCTAssertEqual(LayoutArrange.maximize.verb, .maximize(target: .focused))
        XCTAssertEqual(LayoutArrange.restore.verb, .restore)
        XCTAssertEqual(
            LayoutArrange.show(.pdf).verb,
            .setViewKind(target: .focused, viewKind: .pdf))
        XCTAssertEqual(LayoutArrange.applySaved("reading").verb, .applyLayout(nameOrOrdinal: "reading"))
        XCTAssertEqual(LayoutArrange.deleteSaved("id-1").verb, .deleteLayout(nameOrId: "id-1"))

        let split = try XCTUnwrap(LayoutArrange.splitRight.verb.verbJSON).jsonString()
        XCTAssertTrue(split.contains(#""verb":"split""#))
        XCTAssertTrue(split.contains(#""dir":"horizontal""#))
        XCTAssertFalse(split.contains("\"new\""), "a bare split duplicates the focused pane")
        let kind = try XCTUnwrap(LayoutArrange.show(.list).verb.verbJSON).jsonString()
        XCTAssertEqual(
            kind,
            #"{"target":{"focused":true},"verb":"set-view-kind","view_kind":"list"}"#)
        XCTAssertEqual(
            LayoutArrange.splitRight.verb(targeting: .id(2)),
            .split(target: .id(2), dir: .horizontal, after: true, new: nil))
    }

    /// Secondary click on a handle is this list, aimed at that tile. The same
    /// function builds View ▸ Show / Move for the focused pane.
    func testTheHandleMenuIsEveryVerbThatAppliesToThatPane() throws {
        let tree = try golden()
        let actions = LayoutPaneActions.actions(
            targeting: .id(2),
            tile: 2,
            tree: tree,
            kinds: [.list, .pdf],
            currentKind: "list",
            currentRole: "list")

        XCTAssertEqual(
            LayoutPaneActions.roles,
            ["navigator", "list", "detail", "preview", "console"])
        XCTAssertEqual(
            actions.map(\.id),
            [
                "split-left", "split-right", "split-above", "split-below",
                "close", "maximize", "restore", "collapse", "focus",
                "move-left", "move-right", "move-above", "move-below", "move-into-tabs",
                "show-list", "show-pdf",
                "role-navigator", "role-list", "role-detail", "role-preview", "role-console",
                "role-clear",
            ])

        let splitRight = try XCTUnwrap(actions.first { $0.id == "split-right" }?.verb)
        XCTAssertEqual(splitRight, LayoutArrange.splitRight.verb(targeting: .id(2)))
        let splitJSON = try XCTUnwrap(splitRight.verbJSON).jsonString()
        XCTAssertFalse(splitJSON.contains("\"new\""))
        XCTAssertTrue(splitJSON.contains(#""target":{"id":2}"#))

        XCTAssertEqual(
            actions.first { $0.id == "move-left" }?.verb,
            .move(tile: .id(2), target: .id(1), placement: .left))
        XCTAssertEqual(
            actions.first { $0.id == "move-into-tabs" }?.verb,
            .move(tile: .id(2), target: .id(3), placement: .intoTabs))
        XCTAssertEqual(actions.first { $0.id == "show-list" }?.checked, true)
        XCTAssertEqual(actions.first { $0.id == "show-pdf" }?.checked, false)
        XCTAssertEqual(actions.first { $0.id == "role-list" }?.checked, true)
        XCTAssertEqual(actions.first { $0.id == "role-clear" }?.checked, false)
        XCTAssertTrue(
            actions.filter { $0.section == .open }.isEmpty,
            "the golden window already has the sidebar, the list, and the detail")
        XCTAssertNotNil(actions.first { $0.id == "close" }?.verb)
        XCTAssertNotNil(actions.first { $0.id == "collapse" }?.verb)
        XCTAssertEqual(actions.first { $0.id == "collapse" }?.title, "Collapse Pane")

        let edge = LayoutPaneActions.actions(
            targeting: .id(1), tile: 1, tree: tree, kinds: [])
        XCTAssertNil(edge.first { $0.id == "move-left" }?.verb)
        XCTAssertEqual(
            edge.first { $0.id == "move-into-tabs" }?.verb,
            .move(tile: .id(1), target: .id(2), placement: .intoTabs))

        let kinds = LayoutPaneActions.orderedKinds(registered: [.pdf, .list, ViewKindID("zzz-extra")])
        XCTAssertEqual(kinds.prefix(2).map(\.rawValue), ["list", "pdf"])
        XCTAssertEqual(kinds.last?.rawValue, "zzz-extra")
    }

    /// Two panes in one tab strip have nowhere else to drop. An edge of that
    /// pane splits them; the center does not. A pane that is not tabbed still
    /// refuses a drop on itself.
    func testAnEdgeDropOnATabbedPaneSplitsItOut() throws {
        let tree = try tabs(children: [1, 2])
        XCTAssertEqual(
            LayoutPaneMove.dropVerb(source: 2, target: 2, placement: .right, tree: tree),
            .move(tile: .id(2), target: .id(1), placement: .right))
        XCTAssertEqual(
            LayoutPaneMove.dropVerb(source: 2, target: 2, placement: .left, tree: tree),
            .move(tile: .id(2), target: .id(1), placement: .left))
        XCTAssertEqual(
            LayoutPaneMove.dropVerb(source: 1, target: 1, placement: .left, tree: tree),
            .move(tile: .id(1), target: .id(2), placement: .left))
        XCTAssertNil(LayoutPaneMove.dropVerb(source: 2, target: 2, placement: .intoTabs, tree: tree))

        let three = try tabs(children: [1, 2, 3])
        XCTAssertEqual(
            LayoutPaneMove.dropVerb(source: 3, target: 3, placement: .right, tree: three),
            .move(tile: .id(3), target: .id(2), placement: .right))
        XCTAssertEqual(
            LayoutPaneMove.dropVerb(source: 2, target: 2, placement: .right, tree: three),
            .move(tile: .id(2), target: .id(3), placement: .right))

        let columns = try golden()
        XCTAssertNil(LayoutPaneMove.dropVerb(source: 2, target: 2, placement: .right, tree: columns))
        XCTAssertEqual(
            LayoutPaneMove.dropVerb(source: 1, target: 2, placement: .right, tree: columns),
            .move(tile: .id(1), target: .id(2), placement: .right))
    }

    /// Close deletes the list's query. Show on the sidebar only changes the
    /// view kind, so the way back is a split of a paper list — the detail's
    /// kinds, or the cold-start list, never the sidebar's collections.
    func testADeletedListReopensAsPapersNotCollections() throws {
        let sidebar = """
        {"view_kind":"outline","role":"navigator","query":{"kinds":["collection","library"],"scope":{"scope":"all"}}}
        """
        let paper = """
        {"view_kind":"info","role":"detail","query":{"kinds":["publication"],"scope":{"scope":"item","id":{"ref":"param","name":"item"}}}}
        """
        let withDetail = try window([sidebar, paper])
        let opened = LayoutRoleSpec.missing(in: withDetail, around: 1)
        XCTAssertEqual(opened.map(\.role), ["list"])
        XCTAssertEqual(opened.map(\.title), ["Papers"])
        XCTAssertNil(opened.first?.spec)

        let actions = LayoutPaneActions.actions(
            targeting: .id(1), tile: 1, tree: withDetail,
            kinds: [.outline, .list, .info])
        let verb = try XCTUnwrap(actions.first { $0.id == "open-list" }?.verb)
        XCTAssertEqual(verb, .openList)
        let showList = try XCTUnwrap(actions.first { $0.id == "show-list" }?.verb)
        XCTAssertEqual(showList, .openList)

        let onlySidebar = try window([sidebar])
        let restored = LayoutRoleSpec.missing(in: onlySidebar, around: 1)
        XCTAssertEqual(restored.map(\.role), ["list", "detail"])
        XCTAssertEqual(restored.map(\.title), ["Papers", "Detail"])
        XCTAssertNil(restored.first { $0.role == "list" }?.spec)
        let hidden = LayoutPaneActions.actions(
            targeting: .id(1), tile: 1, tree: onlySidebar, kinds: [.outline])
        XCTAssertNil(hidden.first { $0.id == "open-list" })
    }

    /// A manuscript list that is still open supplies the detail. The cold-start
    /// detail is a publication, and must not replace a manuscript.
    func testADeletedDetailFollowsTheRemainingList() throws {
        let manuscripts = """
        {"view_kind":"list","role":"list","query":{"kinds":["manuscript"],"scope":{"scope":"all"}}}
        """
        let tree = try window([manuscripts])
        let opened = LayoutRoleSpec.missing(in: tree, around: 1)
        let detail = try XCTUnwrap(opened.first { $0.role == "detail" })
        let spec = try XCTUnwrap(detail.spec)
        XCTAssertEqual(detail.title, "Detail")
        XCTAssertEqual(spec["view_kind"]?.stringValue, "source")
        XCTAssertEqual(spec["role"]?.stringValue, "detail")
        XCTAssertEqual(spec["query"]?["kinds"]?.stringArrayValue, ["manuscript"])
        XCTAssertEqual(spec["query"]?["scope"]?["scope"]?.stringValue, "item")
        XCTAssertEqual(spec["params"]?.arrayValue?.first?["decl"]?["kind"]?.stringValue, "manuscript")
        XCTAssertNil(opened.first { $0.role == "list" })

        let manuscriptDetail = """
        {"view_kind":"source","role":"detail","query":{"kinds":["manuscript"],"scope":{"scope":"item","id":{"ref":"param","name":"item"}}}}
        """
        let papers = LayoutRoleSpec.missing(in: try window([manuscriptDetail]), around: 1)
        XCTAssertEqual(papers.first { $0.role == "list" }?.title, "Manuscripts")
        XCTAssertEqual(
            LayoutPaneActions.actions(
                targeting: .id(1), tile: 1, tree: try window([manuscriptDetail]),
                kinds: [.list, .source]
            ).first { $0.id == "open-list" }?.verb,
            .openList)
    }

    /// A tab that is not a pane yet cannot be moved. The drop is a split, and
    /// the center — which would mean tabs — splits it out to the right.
    func testDraggingADetailTabOutIsASplitWithNoRole() throws {
        let tree = try golden()
        let detail = try XCTUnwrap(tree.pane(3))
        let spawned = try XCTUnwrap(
            LayoutPaneSpecJSON.spawned(from: detail, viewKind: "bibtex", tab: "bibtex"))
        XCTAssertEqual(spawned["view_kind"]?.stringValue, "bibtex")
        XCTAssertNil(spawned["role"]?.stringValue)
        XCTAssertEqual(spawned["query"]?["kinds"]?.stringArrayValue, ["publication"])
        XCTAssertEqual(spawned["view_state"]?["tab"]?.stringValue, "bibtex")
        XCTAssertEqual(
            LayoutPaneDrop.spawnVerb(spec: spawned, target: 3, placement: .left),
            .split(target: .id(3), dir: .horizontal, after: false, new: spawned))
        XCTAssertEqual(
            LayoutPaneDrop.spawnVerb(spec: spawned, target: 3, placement: .intoTabs),
            .split(target: .id(3), dir: .horizontal, after: true, new: spawned))
        XCTAssertEqual(LayoutPaneDrop.spawnPlacement(.intoTabs), .right)
        XCTAssertEqual(LayoutPaneDrop.spawnPlacement(.below), .below)
        XCTAssertFalse(LayoutPaneDrop.commitsSplit(spawnTile: 3, target: 3, placement: .intoTabs))
        XCTAssertTrue(LayoutPaneDrop.commitsSplit(spawnTile: 3, target: 3, placement: .left))
        XCTAssertTrue(LayoutPaneDrop.commitsSplit(spawnTile: 3, target: 1, placement: .intoTabs))
    }

    private func window(_ panes: [String]) throws -> LayoutTree {
        let listed = panes.enumerated().map { index, pane in
            "\"\(index + 1)\": {\"pane\": \(pane)}"
        }.joined(separator: ", ")
        let ids = panes.indices.map { String($0 + 1) }.joined(separator: ", ")
        let root = panes.count + 1
        let json = """
        {
          "tiles": {
            \(listed),
            "\(root)": {"container": {"linear": {"dir": "horizontal", "children": [\(ids)]}}}
          },
          "windows": [{"id": 1, "root": \(root), "focused": 1}]
        }
        """
        return try LayoutTree.decode(json)
    }

    private func tabs(children: [UInt64]) throws -> LayoutTree {
        let panes = children.map { id in
            "\"\(id)\": {\"pane\": {\"view_kind\": \"list\"}}"
        }.joined(separator: ", ")
        let root = (children.max() ?? 0) + 1
        let listed = children.map(String.init).joined(separator: ", ")
        let json = """
        {
          "tiles": {
            \(panes),
            "\(root)": {"container": {"tabs": {"children": [\(listed)], "active": \(children.last ?? 0)}}}
          },
          "windows": [{
            "id": 1,
            "root": \(root),
            "focused": \(children.last ?? 0)
          }]
        }
        """
        return try LayoutTree.decode(json)
    }
}
#endif
