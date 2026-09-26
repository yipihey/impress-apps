#if os(macOS)
//
//  LayoutInfoPaneTests.swift
//  PublicationManagerCoreTests
//
//  The `info` pane against a REAL `SharedLayout` (plan wave 7, T4): its tab
//  is pane state in the tree (PH-M6), Open PDF is a verb on the pane that
//  follows the list (PH-M10), and its kinds come through Rust's manifest,
//  manuscripts included (PH-M8, PH-L7).
//

import ImpressLayout
import ImpressRustCore
import XCTest

@testable import PublicationManagerCore

@MainActor
final class LayoutInfoPaneTests: XCTestCase {

    private var controller: LayoutController!
    private var list: UInt64 = 0
    private var detail: UInt64 = 0

    override func setUp() async throws {
        let store = try SharedStore.openInMemory()
        let layout = SharedLayout.open(store: store, appId: "imbib", device: nil)
        controller = LayoutController(layout: layout, appID: "imbib", store: store)
        list = try XCTUnwrap(controller.paneWithRole("list"))
        detail = try XCTUnwrap(controller.paneWithRole("detail"))
        XCTAssertEqual(controller.tree?.pane(detail)?.viewKind, ViewKindID.info.rawValue)
    }

    override func tearDown() async throws {
        controller.stop()
        controller = nil
    }

    private var detailTab: DetailTab {
        LayoutInfoPaneView.tab(in: controller.tree?.pane(detail)?.viewState)
    }

    // MARK: PH-M6 — the tab is the tree's

    func testTheTabIsPaneStateThatSurvivesASplitAndUndoes() throws {
        XCTAssertEqual(detailTab, .info, "a fresh pane opens on Info")

        XCTAssertTrue(LayoutPaneViewState.merge(
            ["tab": .string("pdf")], into: detail, controller: controller, why: "test"))
        XCTAssertEqual(detailTab, .pdf)
        let raw = try XCTUnwrap(controller.pane(detail)?.specJson)
        XCTAssertEqual(
            try LayoutJSONValue.decode(raw)["view_state"]?["tab"]?.stringValue, "pdf",
            "the tab is not in the spec an agent reads")

        // A split rebuilds the pane's view by structure; the tab is not in it.
        XCTAssertTrue(controller.apply(.split(target: .id(detail), dir: .vertical, after: true, new: nil)))
        XCTAssertEqual(detailTab, .pdf, "the split reset the tab")

        // An ordinary exploration verb: ⌘Z in the pane takes it back.
        XCTAssertTrue(controller.apply(.undo(stack: .exploration, pane: detail)))
        XCTAssertEqual(detailTab, .info)
    }

    func testANoOpWriteIsNotAVerb() {
        let before = controller.version
        XCTAssertTrue(LayoutPaneViewState.merge(
            ["tab": .string("pdf")], into: detail, controller: controller, why: "first"))
        let after = controller.version
        XCTAssertGreaterThan(after, before)
        XCTAssertTrue(LayoutPaneViewState.merge(
            ["tab": .string("pdf")], into: detail, controller: controller, why: "again"))
        XCTAssertEqual(controller.version, after, "writing the same tab made an undo entry for nothing")
    }

    // MARK: PH-M10 — Open PDF is a verb on the pane that follows the list

    func testOpenPDFSetsTheInfoPanesTabWhenNoPDFPaneFollows() {
        let outcome = LayoutOpenPDF.open(from: list, controller: controller)
        XCTAssertEqual(outcome, .infoPaneTab(detail))
        XCTAssertEqual(detailTab, .pdf)
        XCTAssertEqual(controller.focused, detail, "the pane showing the PDF is where the user is now")
    }

    func testOpenPDFFocusesAPDFPaneOnTheListsChannelAndLeavesInfoAlone() throws {
        XCTAssertTrue(controller.apply(.split(target: .id(detail), dir: .vertical, after: true, new: nil)))
        let tree = try XCTUnwrap(controller.tree)
        let copy = try XCTUnwrap(tree.tiles.keys.sorted().last { id in
            id != detail && tree.pane(id)?.viewKind == ViewKindID.info.rawValue
        })
        XCTAssertTrue(controller.apply(.setViewKind(target: .id(copy), viewKind: .pdf)))

        let outcome = LayoutOpenPDF.open(from: list, controller: controller)
        XCTAssertEqual(outcome, .focusedPDFPane(copy))
        XCTAssertEqual(controller.focused, copy)
        XCTAssertEqual(detailTab, .info, "the info pane beside a pdf pane now shows the PDF twice")
    }

    // MARK: PH-M2 — Open PDF from a row is one gesture, one ⌘Z

    private func selection(onChannelOf tile: UInt64) -> Set<String> {
        Set(controller.tree?.selection(onChannelOf: tile, kind: RecordKindID.publication.rawValue) ?? [])
    }

    func testOpenPDFFromARowIsOneStepAndOneUndo() throws {
        let paper = UUID().uuidString.lowercased()
        let before = controller.version
        let outcome = LayoutOpenPDF.open(
            from: list,
            selecting: .init(kind: RecordKindID.publication.rawValue, ids: [paper]),
            controller: controller)
        XCTAssertEqual(outcome, .infoPaneTab(detail))
        XCTAssertEqual(controller.version, before + 1, "select + tab + focus were more than one step")
        XCTAssertEqual(selection(onChannelOf: list), [paper])
        XCTAssertEqual(detailTab, .pdf)
        XCTAssertEqual(controller.focused, detail)

        // ONE ⌘Z, in the pane the click left focus on, takes the whole click back.
        XCTAssertTrue(controller.apply(.undo(stack: .exploration, pane: detail)))
        XCTAssertEqual(detailTab, .info, "the tab survived the click's undo")
        XCTAssertEqual(selection(onChannelOf: list), [], "the row's selection survived the click's undo")
    }

    func testARefusedOpenPDFAppliesNoneOfIt() throws {
        let before = controller.version
        // Not a record id: Rust refuses the `select`, so the tab must not move either.
        let outcome = LayoutOpenPDF.open(
            from: list,
            selecting: .init(kind: RecordKindID.publication.rawValue, ids: ["not-a-uuid"]),
            controller: controller)
        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(controller.version, before)
        XCTAssertEqual(detailTab, .info, "half of a refused click was applied")
    }

    // MARK: PH-M8 / PH-L7 — kinds through the manifest

    func testEveryDetailKindIsAManifestKindTheInfoPaneRenders() {
        let expected: [String: LayoutInfoPaneView.DetailKind] = [
            "publication": .publication,
            "manuscript": .manuscript,
            "figure": .figure,
            "message": .message,
            "task": .task,
            "agent-run": .agentRun,
        ]
        for (kind, detailKind) in expected {
            XCTAssertTrue(LayoutKindID.known.contains(kind), "Rust's manifest has no '\(kind)'")
            XCTAssertEqual(LayoutInfoPaneView.DetailKind(layoutKind: kind), detailKind, kind)
        }
        // The case the raw-value comparison got wrong: the layout's
        // `library` is the chassis' `imbib/library`, not `library`.
        XCTAssertNotEqual(LayoutKindID.recordKind(forLayoutKind: "library"), RecordKindID("library"))
        XCTAssertEqual(LayoutInfoPaneView.DetailKind(layoutKind: "no-such-kind"), .unsupported)
    }

    // MARK: PH-L7 — the legacy view_state keys are Rust's

    func testTheScopedLegacyKeysAreTheOnesRustWrites() throws {
        let listSpec = try XCTUnwrap(controller.pane(list)?.specJson)
        let node = LayoutJSONValue.object(["node": .string("search-form"), "form": .string("arxiv")])
        let raw = try outlineRowVerbsJson(
            appId: "imbib", nodeJson: node.jsonString(), bindingsJson: "",
            listSpecJson: listSpec, detailSpecJson: "", initial: false)
        let verbs = try XCTUnwrap(LayoutJSONValue.decode(raw)["verbs"]?.arrayValue)
        let setPane = try XCTUnwrap(verbs.first { $0["verb"]?.stringValue == "set-pane" })
        let viewState = setPane["spec"]?["view_state"]

        let scope = try XCTUnwrap(
            LayoutLegacyPaneView.scope(of: viewState), "Rust's legacy view_state does not read as a scope")
        XCTAssertEqual(scope.section, "search")
        XCTAssertEqual(scope.node, node)
        XCTAssertNotNil(scope.reason)
    }
}
#endif
