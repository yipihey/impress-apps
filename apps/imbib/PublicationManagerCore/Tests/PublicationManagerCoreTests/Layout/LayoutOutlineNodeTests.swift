#if os(macOS)
//
//  LayoutOutlineNodeTests.swift
//  PublicationManagerCoreTests
//
//  Plan wave 6, W3. The outline pane spells a selected sidebar row as
//  `impress_layout_service::OutlineNode` and hands it to Rust
//  (`outline_row_verbs_json`). The wire form is a contract between two
//  languages, and its failure mode is silent: a node Rust cannot parse is a
//  logged warning and a row that navigates nowhere. So every tab shape the
//  sidebar produces is sent through the REAL FFI here, and the answer is
//  checked — not a Swift fixture of what Rust would say.
//

import ImpressRustCore
import XCTest

@testable import PublicationManagerCore

@MainActor
final class LayoutOutlineNodeTests: XCTestCase {

    private let collection = UUID()
    private let library = UUID()

    /// Every `ImbibTab` shape → the target Rust gives it in impress.
    private var cases: [(ImbibTab, String)] {
        [
            (.library(library), "query"),
            (.collection(collection), "query"),
            (.inboxCollection(collection), "query"),
            (.explorationCollection(collection), "query"),
            (.flagged("red"), "query"),
            (.flagged(nil), "query"),
            (.tag(path: "methods/nbody"), "query"),
            (.watchedFolder(WatchedFolderID(UUID()), tagPath: "watched/Papers"), "query"),
            (.allArtifacts, "query"),
            (.record(.all(.figure)), "query"),
            (.record(.folder(.figure, UUID())), "query"),
            (.record(.flagged(.manuscript, nil)), "query"),
            (.record(.status(.manuscript, "submitted")), "query"),
            // Not values in the algebra: hosted, scoped, with a reason.
            (.searchForm(.adsModern), "legacy"),
            (.addFeed, "legacy"),
            (.scixLibrary(library), "legacy"),
            (.sharedLibrary(library), "legacy"),
            (.reviewQueue, "legacy"),
            (.inboxFeed(UUID()), "legacy"),
            (.libraryFeed(UUID()), "legacy"),
            (.exploration(UUID()), "legacy"),
            (.recent, "legacy"),
            (.artifactType("webpage"), "legacy"),
            (.citedInManuscripts, "legacy"),
            (.record(.status(.task, "failed")), "legacy"),
            (.customSurface("dashboard"), "legacy"),
            (.recordDetail(.manuscript, UUID().uuidString), "legacy"),
            (.auxiliary(.submissionsInbox), "legacy"),
        ]
    }

    private func answer(for tab: ImbibTab) throws -> [String: LayoutJSONValue] {
        let (node, bindings) = LayoutOutlineNode.node(
            for: tab, shell: .impress, dismissedLibraryID: nil)
        let raw = try outlineRowVerbsJson(
            appId: "impress",
            nodeJson: node.jsonString(),
            bindingsJson: LayoutJSONValue.object(bindings.mapValues { .string($0) }).jsonString(),
            listSpecJson: "", detailSpecJson: "", initial: false)
        return try XCTUnwrap(LayoutJSONValue.decode(raw).objectValue, raw)
    }

    func testEveryTabShapeIsANodeRustParsesAndTargetsAsExpected() throws {
        for (tab, expected) in cases {
            let answer = try answer(for: tab)
            let target = answer["target"]?.objectValue?["target"]?.stringValue
            XCTAssertEqual(target, expected, "\(tab)")
        }
    }

    /// A hosted route's pane rebuilds its tab from the node in `view_state`,
    /// so the node must carry the whole route back.
    func testLegacyNodesRoundTripToTheSameRoute() throws {
        for (tab, expected) in cases where expected == "legacy" {
            let (node, _) = LayoutOutlineNode.node(for: tab, shell: .impress, dismissedLibraryID: nil)
            switch tab {
            case .addFeed:
                XCTAssertEqual(LayoutOutlineNode.tab(from: node), .addFeed)
            default:
                XCTAssertEqual(LayoutOutlineNode.tab(from: node), tab, "\(tab)")
            }
        }
    }

    /// Rust's section names are the `SidebarSectionType` CASE names. The one
    /// whose raw value differs is the trap.
    func testSectionNamesAreCaseNamesNotRawValues() {
        XCTAssertEqual(SidebarSectionType.manuscripts.rawValue, "journal")
        XCTAssertEqual(LayoutOutlineNode.sectionName(.manuscripts), "manuscripts")
        XCTAssertEqual(LayoutOutlineNode.section(named: "manuscripts"), .manuscripts)
        for section in SidebarSectionType.allCases {
            XCTAssertEqual(
                LayoutOutlineNode.section(named: LayoutOutlineNode.sectionName(section)), section)
        }
    }

    /// Every section Rust names for an app is one this build can draw.
    func testRustSectionTablesNameOnlyKnownSections() throws {
        for app in ["imbib", "imprint", "implore", "impel", "impart", "impress"] {
            let rows = try XCTUnwrap(LayoutJSONValue.decode(outlineSectionsJson(appId: app)).arrayValue)
            XCTAssertFalse(rows.isEmpty, app)
            for row in rows {
                let name = try XCTUnwrap(row.objectValue?["section"]?.stringValue)
                XCTAssertNotNil(LayoutOutlineNode.section(named: name), "\(app): \(name)")
            }
        }
    }
}
#endif
