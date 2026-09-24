//
//  PublicationTagRemovalTests.swift
//  PublicationManagerCoreTests
//
//  The publication row menu had Add Tag and no way back: `onRemoveTag` took a
//  tag UUID the store could not resolve, and every host's handler was an empty
//  TODO (the legacy list, the tree's list pane, the row's chip menu, the
//  tag-delete mode and iOS). Remove Tag is `PublicationTagRemoval` now, over
//  `RustStoreAdapter.removeTag` — the verb `addTag` pairs with — and both are
//  undoable through `UndoCoordinator`, which a chassis window must wire
//  (it did not, so in impress Edit ▸ Undo never saw Add Tag).
//

import ImpressFTUI
import XCTest

@testable import PublicationManagerCore

@MainActor
final class PublicationTagRemovalTests: XCTestCase {

    // MARK: - What the menu offers

    func testTheMenuOffersEachTagTheTargetsCarryOnce() {
        let a = UUID(), b = UUID(), c = UUID()
        let rows: [UUID: PublicationRowData] = [
            a: row(a, tags: ["reading/queue", "ai/field/cosmology"]),
            b: row(b, tags: ["reading/queue"]),
            c: row(c, tags: []),
        ]
        let tags = PublicationTagRemoval.removableTags(ids: [a, b, c], row: { rows[$0] })
        XCTAssertEqual(tags.map(\.path), ["ai/field/cosmology", "reading/queue"])

        XCTAssertTrue(
            PublicationTagRemoval.removableTags(ids: [c], row: { rows[$0] }).isEmpty,
            "no tag on any target → no Remove Tag submenu")
    }

    /// A removal names only the rows that carry the tag, so its undo entry
    /// re-adds it to exactly those and never tags a row that had none.
    func testARemovalTouchesOnlyTheRowsThatCarryTheTag() {
        let a = UUID(), b = UUID()
        let rows: [UUID: PublicationRowData] = [
            a: row(a, tags: ["reading/queue"]),
            b: row(b, tags: ["other"]),
        ]
        XCTAssertEqual(
            PublicationTagRemoval.carriers(of: "reading/queue", in: [a, b], row: { rows[$0] }),
            [a])
    }

    // MARK: - The store round trip, with undo

    func testRemoveTagIsUndoableAndRedoable() throws {
        let adapter = RustStoreAdapter.shared
        let path = "tests/remove-\(UUID().uuidString.prefix(8))"
        guard let library = adapter.createLibrary(name: "Remove tag \(UUID().uuidString.prefix(6))")
        else { throw XCTSkip("no writable store in this environment") }
        let ids = adapter.importBibTeX(
            """
            @article{RemoveTag2026Test,
              author = {Tester, T.},
              title = {A paper that loses a tag},
              year = {2026}
            }
            """,
            libraryId: library.id)
        try XCTSkipIf(ids.isEmpty, "import produced nothing in this environment")

        let manager = UndoManager()
        manager.groupsByEvent = false
        UndoCoordinator.shared.undoManager = manager
        defer { UndoCoordinator.shared.undoManager = nil }

        func carries() -> Bool {
            adapter.getPublication(id: ids[0])?.tagDisplays.contains { $0.path == path } ?? false
        }

        manager.beginUndoGrouping()
        adapter.addTag(ids: ids, tagPath: path)
        manager.endUndoGrouping()
        XCTAssertTrue(carries())
        XCTAssertTrue(manager.canUndo, "Add Tag registered no undo")

        manager.beginUndoGrouping()
        PublicationTagRemoval.remove(path, from: Set(ids))
        manager.endUndoGrouping()
        XCTAssertFalse(carries(), "Remove Tag left the tag on the paper")
        XCTAssertEqual(manager.undoActionName.isEmpty, false)

        manager.undo()
        XCTAssertTrue(carries(), "Undo of Remove Tag did not put the tag back")
        XCTAssertTrue(manager.canRedo)

        manager.redo()
        XCTAssertFalse(carries(), "Redo of Remove Tag did not take it off again")

        manager.undo()  // back to tagged
        manager.undo()  // undo Add Tag
        XCTAssertFalse(carries(), "Undo of Add Tag did not remove the tag")
    }

    // MARK: - Every chassis window hands UndoCoordinator its undo manager

    /// Without this line `UndoCoordinator.registerUndo` returns before
    /// registering anything, in every chassis app — Add Tag in impress was
    /// the case W4 caught.
    func testTheChassisRootWiresTheUndoCoordinator() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/PublicationManagerCore/Chassis/ChassisRootView.swift")
        let source = try String(contentsOf: root, encoding: .utf8)
        XCTAssertTrue(source.contains(".wireUndo(to: UndoCoordinator.shared)"))
    }

    // MARK: - Helpers

    private func row(_ id: UUID, tags: [String]) -> PublicationRowData {
        PublicationRowData(
            id: id,
            tagDisplays: tags.map {
                TagDisplayData(id: UUID(), path: $0, leaf: String($0.split(separator: "/").last ?? ""))
            })
    }
}
