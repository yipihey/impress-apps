//
//  WatchedManuscriptSidebarSeamTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 W3 — the two CHASSIS seams imprint's watched folders ride, pinned
//  here rather than in imprint because the chassis is what has to keep them.
//
//    1. `RecordSidebarSectionContent.additionalNodes` — a host CONTRIBUTES
//       rows without taking the section over. Before W3 the only seam was
//       `nodes`, which REPLACES; using it for imprint's Manuscripts section
//       would have meant re-implementing All + six declared statuses + the
//       folder tree inside the host, i.e. a second copy of the descriptor.
//    2. `ManuscriptListScope.tag` — the scope a watched folder's row resolves
//       to. W2 settled that a folder's records are its provenance tag; this is
//       the manuscript-side spelling of that answer.
//

import XCTest

@testable import PublicationManagerCore

@MainActor
final class WatchedManuscriptSidebarSeamTests: XCTestCase {

    private func node(_ title: String, key: String) -> RecordSidebarNode {
        RecordSidebarNode(
            scope: .host(.manuscript, key: key), title: title, systemImage: "folder")
    }

    // MARK: - additionalNodes

    /// The contributed row is APPENDED — the descriptor's rows all survive, and
    /// the new one comes last so adding a watched folder never reshuffles rows
    /// a user has learned the position of.
    func testAdditionalNodesAppendToTheDerivedRowsRatherThanReplacingThem() {
        let derived = RecordSidebarBuilder.sections(
            configuration: .imprint,
            dataSource: RecordSidebarDataSource()
        ).first { $0.section == .manuscripts }
        let derivedTitles = derived?.nodes.map(\.title) ?? []
        XCTAssertFalse(derivedTitles.isEmpty, "the preset must derive rows to append to")

        let withExtra = RecordSidebarBuilder.sections(
            configuration: .imprint,
            dataSource: RecordSidebarDataSource(
                sectionContent: { section, kind in
                    guard section == .manuscripts, kind == .manuscript else { return nil }
                    return RecordSidebarSectionContent(
                        additionalNodes: [self.node("drafts", key: "watched-folder.abc")])
                })
        ).first { $0.section == .manuscripts }

        let titles = withExtra?.nodes.map(\.title) ?? []
        XCTAssertEqual(
            titles, derivedTitles + ["drafts"],
            "every derived row survives and the contributed row lands last")
    }

    /// `nodes` still wins outright, so W2's Libraries behaviour is untouched:
    /// a host that TOOK the section over owns all of it.
    func testSuppliedNodesStillReplaceAndIgnoreAdditionalNodes() {
        let section = RecordSidebarBuilder.sections(
            configuration: .imprint,
            dataSource: RecordSidebarDataSource(
                sectionContent: { section, _ in
                    guard section == .manuscripts else { return nil }
                    return RecordSidebarSectionContent(
                        nodes: [self.node("only", key: "watched-folder.a")],
                        additionalNodes: [self.node("ignored", key: "watched-folder.b")])
                })
        ).first { $0.section == .manuscripts }

        XCTAssertEqual(section?.nodes.map(\.title), ["only"])
    }

    // MARK: - The tag scope

    /// A tag scope is a first-class `ManuscriptListScope`: it has a stable key
    /// (so `.id(scope)` on the list view is honest across rebuilds) and it
    /// names itself with the tag's LEAF, since the sidebar row above it already
    /// says which folder this is.
    func testTagScopeHasAStableKeyAndNamesItselfByLeaf() {
        let scope = ManuscriptListScope.tag("watched/drafts")
        XCTAssertEqual(scope.scopeKey, "manuscripts-tag-watched/drafts")
        XCTAssertEqual(scope.title, "drafts")
        XCTAssertEqual(scope.stableViewID, ManuscriptListScope.tag("watched/drafts").stableViewID)
        XCTAssertNotEqual(scope.stableViewID, ManuscriptListScope.all.stableViewID)
        // It is not a folder and not a status — the two things a list surface
        // asks a scope before it queries anything.
        XCTAssertNil(scope.folderID)
        XCTAssertNil(scope.statusString)
        XCTAssertEqual(scope.tagPath, "watched/drafts")
    }

    /// A watched-folder host key that no RUNNING coordinator can name resolves
    /// to nil rather than to a silently empty list.
    ///
    /// The distinction matters: nil renders "viewer unavailable", while an
    /// empty `.tag("")` would render an empty manuscript list, which reads as
    /// "this folder found nothing" — the exact class of lie D6 exists to
    /// prevent one layer up.
    func testAnUnknownWatchedFolderKeyResolvesToNilNotAnEmptyList() {
        let unknown = WatchedFolderRoute.folder(WatchedFolderID()).scope(kind: .manuscript)
        XCTAssertNil(ManuscriptListScope(routeScope: unknown))
    }
}
