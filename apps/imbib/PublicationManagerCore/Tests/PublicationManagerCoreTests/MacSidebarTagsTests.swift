#if os(macOS)
//
//  MacSidebarTagsTests.swift
//  PublicationManagerCoreTests
//
//  The macOS half of the Tags section, HEADLESSLY — the same instrument
//  `MacComposedSidebarTests` established, and for the same reason: the only
//  other way to see what `ImbibSidebarViewModel` builds is to launch a macOS
//  app, and XCUITest cannot start a macOS runner on every machine (this one
//  refuses with "Authentication canceled. System authentication is running").
//
//  The iOS half is covered end-to-end by `ImpressTagsUITests` in the
//  simulator. What is asserted HERE is everything macOS does differently:
//
//    * rows are built one LEVEL at a time (`tagChildren(under:)`), so a
//      vocabulary of thousands is never walked whole on a rebuild, and
//    * the filter REVEALS its matches by expanding their ancestors, which a
//      lazily-built `NSOutlineView` needs and the iOS renderer does not.
//
//  The vocabulary comes from `RustStoreAdapter.shared`, which in a unit-test
//  process opens a per-PID temp workspace (`SharedWorkspace.rootDirectory`),
//  so these tests seed real tag definitions without going near a real library.
//

import XCTest

@testable import PublicationManagerCore

@MainActor
final class MacSidebarTagsTests: XCTestCase {

    private let parent = "reading"
    private let queue = "reading/queue"
    private let done = "reading/done"
    private let grants = "grants"

    override func setUp() async throws {
        for path in [queue, done, grants] where !RustStoreAdapter.shared.listTags()
            .contains(where: { $0.path == path }) {
            RustStoreAdapter.shared.createTag(path: path)
        }
    }

    // MARK: - Helpers

    private func viewModel() -> ImbibSidebarViewModel {
        ImbibSidebarViewModel(
            store: MockPublicationStore(),
            persistence: .inMemory(),
            shellConfiguration: .imbib,
            sidebarComposition: nil)
    }

    private func tagsSection(_ viewModel: ImbibSidebarViewModel) -> ImbibSidebarNode? {
        viewModel.outlineConfiguration.rootNodes.first {
            if case .section(let type) = $0.nodeType { return type == .tags }
            return false
        }
    }

    /// The tag paths at one level, in the order the outline would draw them.
    private func paths(_ viewModel: ImbibSidebarViewModel, under node: ImbibSidebarNode?)
        -> [String] {
        guard let node else { return [] }
        return viewModel.children(of: node).compactMap {
            if case .tag(let path) = $0.nodeType { return path }
            return nil
        }
    }

    // MARK: - The tree

    func testTagsSectionRendersOneLevelAtATimeWithMaterialisedAncestors() {
        let model = viewModel()
        let section = tagsSection(model)
        XCTAssertNotNil(
            section,
            "the section is gated on the VOCABULARY, and `SidebarSectionType.defaultOrder` "
                + "has to list `.tags` for it to render at all — it did not, and nothing "
                + "drew a single row on either platform")

        XCTAssertEqual(
            paths(model, under: section), [grants, parent],
            "roots only: a level-at-a-time builder is what keeps thousands of tags from "
                + "being walked on every rebuild. `reading` is materialised — nothing "
                + "carries it exactly")

        let readingRow = model.children(of: section!).first {
            $0.nodeType == .tag(path: parent)
        }
        XCTAssertEqual(paths(model, under: readingRow), [done, queue])
    }

    func testATagRowResolvesToTheSameScopeAWatchedFolderRowDoes() {
        let model = viewModel()
        let readingRow = model.children(of: tagsSection(model)!).first {
            $0.nodeType == .tag(path: parent)
        }
        XCTAssertEqual(readingRow?.imbibTab, .tag(path: parent))
    }

    // MARK: - The filter

    func testFilterNarrowsTheVocabularyAndKeepsTheParentsOfMatches() {
        let model = viewModel()
        model.tagFilter = "queue"

        XCTAssertEqual(
            paths(model, under: tagsSection(model)), [parent],
            "`grants` goes; `reading` STAYS, because a descendant matched — without it the "
                + "match is unreachable, which is the difference between filtering a tree "
                + "and filtering a list")
        let readingRow = model.children(of: tagsSection(model)!).first {
            $0.nodeType == .tag(path: parent)
        }
        XCTAssertEqual(paths(model, under: readingRow), [queue], "the sibling that does not match goes")

        model.tagFilter = "  "
        XCTAssertEqual(
            paths(model, under: tagsSection(model)), [grants, parent],
            "a blank filter is no filter")
    }

    func testFilterRevealsItsMatchesByExpandingTheirAncestors() {
        let model = viewModel()
        XCTAssertFalse(
            model.expansionState.isExpanded(ImbibSidebarNodeID.tag(parent)),
            "nothing is expanded to begin with")

        model.tagFilter = "queue"

        XCTAssertTrue(
            model.expansionState.isExpanded(ImbibSidebarNodeID.tag(parent)),
            "the rows that survive a filter are mostly LEAVES — their parents survive only "
                + "because a descendant matched. Leaving the user's collapse state in force "
                + "would answer their question and then hide the answer")
    }

    func testSectionSurvivesAFilterThatMatchesNothing() {
        let model = viewModel()
        model.tagFilter = "zzzz-no-such-tag"
        XCTAssertNotNil(
            tagsSection(model),
            "the section's gate is the WHOLE vocabulary, never the filtered one: a section "
                + "that vanished on the first non-matching keystroke would take the filter "
                + "field off screen mid-sentence")
        XCTAssertEqual(paths(model, under: tagsSection(model)), [])
    }
}
#endif
