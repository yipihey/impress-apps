#if os(macOS)
//
//  LayoutModelTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0031 L6. The Swift mirror of the layout wire value decodes THE SAME
//  GOLDEN the Rust side asserts against — `crates/impress-layout/tests/
//  golden/three_column.json`, whose own module header calls the wire shape "a
//  compatibility surface, pinned by this file".
//
//  Why the golden and not a hand-written fixture: a fixture in this directory
//  would be a SECOND statement of the wire form, maintained by whoever last
//  touched Swift, and the failure mode of a drifted mirror is not a crash —
//  it is a decode error swallowed into "the window has no tiles", which looks
//  exactly like "the user has no layout yet". (The same shape as the
//  schema-ref class of bug: silent, empty, five times shipped.)
//
//  FFI-FREE on purpose: nothing here constructs a `SharedLayout`, so the
//  suite runs under a plain `swift test` without the xcframework rebuilt.
//

import XCTest

@testable import PublicationManagerCore

final class LayoutModelTests: XCTestCase {

    // MARK: - The golden

    /// The repo root, eight directories up from this file:
    /// `…/apps/imbib/PublicationManagerCore/Tests/PublicationManagerCoreTests/Layout/<this>`.
    /// `PaneLayoutCommandsTests` does the same from one level shallower.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Layout
            .deletingLastPathComponent()   // …/PublicationManagerCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/PublicationManagerCore
            .deletingLastPathComponent()   // …/imbib
            .deletingLastPathComponent()   // …/apps
            .deletingLastPathComponent()   // repo root
    }()

    private static let goldenPath = "crates/impress-layout/tests/golden/three_column.json"

    private func goldenJSON() throws -> String {
        try String(
            contentsOf: Self.repoRoot.appendingPathComponent(Self.goldenPath), encoding: .utf8)
    }

    /// A moved test file turns every read above into a silent skip.
    func testTheGoldenIsWhereThisSuiteThinksItIs() throws {
        let json = try goldenJSON()
        XCTAssertTrue(
            json.contains("\"view_kind\"") && json.contains("\"tiles\""),
            "the file at \(Self.goldenPath) is not the layout golden")
    }

    // MARK: - Shape

    func testGoldenDecodesIntoTheMirror() throws {
        let tree = try LayoutTree.decode(goldenJSON())

        XCTAssertEqual(tree.tiles.count, 4)
        XCTAssertEqual(tree.windows.count, 1)
        XCTAssertEqual(tree.nextTile, 4)
        XCTAssertEqual(tree.nextWindow, 2)

        let window = try XCTUnwrap(tree.firstWindow)
        XCTAssertEqual(window.id, 1)
        XCTAssertEqual(window.root, 4)
        // Focus starts on the LIST: it is the pane the triage grammar acts on.
        XCTAssertEqual(window.focused, 2)
        XCTAssertNil(window.maximized)
        XCTAssertEqual(window.defaultChannel, .number(1))
    }

    func testTheRootIsAThreeWayHorizontalSplitWithOneTwoThreeShares() throws {
        let tree = try LayoutTree.decode(goldenJSON())
        let root = try XCTUnwrap(tree.container(4))

        guard case .linear(let dir, let children, let shares) = root else {
            return XCTFail("the root is not a linear container: \(root)")
        }
        XCTAssertEqual(dir, .horizontal)
        XCTAssertEqual(children, [1, 2, 3])
        XCTAssertEqual(shares, [1, 2, 3])
        XCTAssertEqual(root.kind, .horizontal)
    }

    func testEachPaneKeepsItsViewKindRoleAndChannel() throws {
        let tree = try LayoutTree.decode(goldenJSON())

        let navigator = try XCTUnwrap(tree.pane(1))
        XCTAssertEqual(navigator.viewKind, "outline")
        XCTAssertEqual(navigator.role, "navigator")
        XCTAssertEqual(navigator.channel, .number(1))
        // The sidebar is a pane whose query returns navigable kinds (D1).
        XCTAssertEqual(navigator.queryKinds, ["collection", "library"])
        XCTAssertTrue(navigator.params.isEmpty)
        XCTAssertNil(navigator.session)

        let list = try XCTUnwrap(tree.pane(2))
        XCTAssertEqual(list.viewKind, "list")
        XCTAssertEqual(list.role, "list")
        XCTAssertEqual(list.queryKinds, ["publication"])

        let detail = try XCTUnwrap(tree.pane(3))
        XCTAssertEqual(detail.viewKind, "info")
        XCTAssertEqual(detail.role, "detail")
    }

    /// "Selecting in the list drives the detail pane" is now entirely this
    /// binding: one parameter, of the list's kind, following channel 1.
    func testTheDetailPaneBindsItsItemParameterToChannelOne() throws {
        let tree = try LayoutTree.decode(goldenJSON())
        let detail = try XCTUnwrap(tree.pane(3))

        XCTAssertEqual(detail.params.count, 1)
        let param = try XCTUnwrap(detail.params.first)
        XCTAssertEqual(param.name, "item")
        XCTAssertEqual(param.kind, "publication")
        XCTAssertEqual(param.source, .channel(.number(1)))

        // The query itself stays opaque — the algebra is Rust's — but the
        // scope must still be readable as "one item, named by a parameter".
        XCTAssertEqual(detail.query["scope"]?["scope"]?.stringValue, "item")
        XCTAssertEqual(detail.query["scope"]?["id"]?["name"]?.stringValue, "item")
    }

    // MARK: - Walks

    func testLeavesAreInTreeOrder() throws {
        let tree = try LayoutTree.decode(goldenJSON())
        XCTAssertEqual(tree.leaves(of: 4), [1, 2, 3])
        XCTAssertEqual(tree.leaves(of: 2), [2])
    }

    func testParentAndShareLookups() throws {
        let tree = try LayoutTree.decode(goldenJSON())
        XCTAssertEqual(tree.parent(of: 2), 4)
        XCTAssertNil(tree.parent(of: 4))
        XCTAssertEqual(tree.share(of: 1), 1)
        XCTAssertEqual(tree.share(of: 3), 3)
    }

    /// Un-collapsing restores to the SIBLING AVERAGE — the remembered width
    /// lives in the tree, never in a Swift value (ADR-0031 invariant 1).
    func testSiblingAverageIsWhatAnUncollapseRestoresTo() throws {
        let tree = try LayoutTree.decode(goldenJSON())
        XCTAssertEqual(try XCTUnwrap(tree.siblingAverageShare(of: 1)), 2.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tree.siblingAverageShare(of: 2)), 2.0, accuracy: 1e-9)
    }

    func testRoleLookupFindsThePaneTheChordsActOn() throws {
        let tree = try LayoutTree.decode(goldenJSON())
        XCTAssertEqual(tree.paneWithRole("navigator"), 1)
        XCTAssertEqual(tree.paneWithRole("list"), 2)
        XCTAssertEqual(tree.paneWithRole("detail"), 3)
        XCTAssertNil(tree.paneWithRole("console"))
    }

    func testWindowContainmentAndSubtree() throws {
        let tree = try LayoutTree.decode(goldenJSON())
        XCTAssertEqual(tree.window(containing: 3)?.id, 1)
        XCTAssertTrue(tree.subtree(4, contains: 2))
        XCTAssertFalse(tree.subtree(2, contains: 3))
    }

    // MARK: - The collapsed threshold

    func testCollapseThresholdMatchesTheRustMinimumShare() {
        // `impress_store_ffi::layout::MIN_SHARE` is 1e-4: the tree refuses a
        // share of exactly zero, so "hidden" is the smallest weight it takes.
        XCTAssertTrue(LayoutShare.isCollapsed(LayoutShare.collapsed))
        XCTAssertTrue(LayoutShare.isCollapsed(0))
        XCTAssertFalse(LayoutShare.isCollapsed(0.01))
        XCTAssertFalse(LayoutShare.isCollapsed(1))
        XCTAssertTrue(LayoutShare.collapsed <= LayoutShare.collapsedThreshold)
    }

    // MARK: - Tolerances

    /// Rust skips `role`, `session`, `active`, `columns`, `geometry` and
    /// `maximized` when they are absent, so the mirror must survive a tile
    /// that carries none of them.
    func testAMinimalTileDecodes() throws {
        let json = """
            {
              "windows": [{"id": 1, "root": 1, "default_channel": {"number": 2}}],
              "tiles": {
                "1": {"pane": {"view_kind": "legacy", "channel": "follow"}}
              },
              "next_tile": 1
            }
            """
        let tree = try LayoutTree.decode(json)
        let pane = try XCTUnwrap(tree.pane(1))
        XCTAssertEqual(pane.viewKind, "legacy")
        XCTAssertNil(pane.role)
        XCTAssertNil(pane.session)
        XCTAssertTrue(pane.query.isNull)
        XCTAssertEqual(pane.channel, .follow)
        // `follow` resolves against the window default, exactly as Rust does.
        XCTAssertEqual(
            pane.channel.resolved(
                windowDefault: try XCTUnwrap(tree.firstWindow).defaultChannel), 2)
        // The window allocator floor: `next_window` is above every window id.
        XCTAssertEqual(tree.nextWindow, 1)
    }

    func testTabsAndGridContainersDecode() throws {
        let json = """
            {
              "windows": [{"id": 1, "root": 3, "default_channel": {"number": 1}}],
              "tiles": {
                "1": {"pane": {"view_kind": "list"}},
                "2": {"pane": {"view_kind": "info"}},
                "3": {"container": {"tabs": {"children": [1, 2], "active": 2}}},
                "4": {"container": {"grid": {"children": [1, 2], "columns": 2}}}
              },
              "next_tile": 4
            }
            """
        let tree = try LayoutTree.decode(json)

        guard case .tabs(let children, let active) = try XCTUnwrap(tree.container(3)) else {
            return XCTFail("tile 3 is not a tabs container")
        }
        XCTAssertEqual(children, [1, 2])
        XCTAssertEqual(active, 2)

        guard case .grid(let gridChildren, let columns) = try XCTUnwrap(tree.container(4)) else {
            return XCTFail("tile 4 is not a grid container")
        }
        XCTAssertEqual(gridChildren, [1, 2])
        XCTAssertEqual(columns, 2)
    }

    func testChannelStateDecodesAsSelectionPerKind() throws {
        let json = """
            {
              "windows": [{"id": 1, "root": 1, "default_channel": {"number": 1}}],
              "tiles": {"1": {"pane": {"view_kind": "list", "channel": {"number": 1}}}},
              "channels": {"1": {"publication": ["abc", "def"]}},
              "next_tile": 1
            }
            """
        let tree = try LayoutTree.decode(json)
        XCTAssertEqual(tree.selection(onChannelOf: 1, kind: "publication"), ["abc", "def"])
        XCTAssertEqual(tree.selection(onChannelOf: 1, kind: "manuscript"), [])
    }
}
#endif
