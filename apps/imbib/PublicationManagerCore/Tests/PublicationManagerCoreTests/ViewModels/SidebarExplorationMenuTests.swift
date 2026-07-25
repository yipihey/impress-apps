//
//  SidebarExplorationMenuTests.swift
//  PublicationManagerCoreTests
//
//  Regression guard for the Exploration section's sidebar context menus.
//  Exploration smart searches ("lightbulb" rows) had no branch in
//  `buildContextMenu`, so right-clicking one produced no menu at all and the
//  search could not be deleted from the GUI. Multi-selection of those rows had
//  the same gap in `buildMultiSelectionContextMenu`.
//

#if os(macOS)
import Testing
import Foundation
@testable import PublicationManagerCore

@MainActor
@Suite("Sidebar Exploration context menus")
struct SidebarExplorationMenuTests {

    private func makeViewModel() -> ImbibSidebarViewModel {
        ImbibSidebarViewModel(store: MockPublicationStore())
    }

    private func searchNode(_ name: String = "probe") -> ImbibSidebarNode {
        ImbibSidebarNode(
            id: UUID(),
            nodeType: .explorationSearch(searchID: UUID()),
            displayName: name,
            iconName: "lightbulb"
        )
    }

    private func explorationCollectionNode(_ name: String = "Refs: probe") -> ImbibSidebarNode {
        ImbibSidebarNode(
            id: UUID(),
            nodeType: .explorationCollection(collectionID: UUID()),
            displayName: name,
            iconName: "doc.text.magnifyingglass"
        )
    }

    @Test("Right-clicking an Exploration search yields a Delete item")
    func singleExplorationSearchMenu() {
        let viewModel = makeViewModel()
        let menu = viewModel.outlineConfiguration.contextMenu?(searchNode())
        #expect(menu != nil)
        #expect(menu?.items.contains(where: { $0.title == "Delete Search" }) == true)
    }

    @Test("Multi-selected Exploration searches yield one bulk Delete item")
    func multipleExplorationSearchMenu() {
        let viewModel = makeViewModel()
        let nodes = [searchNode("a"), searchNode("b"), searchNode("c")]
        let menu = viewModel.outlineConfiguration.contextMenuForMultiple?(nodes)
        #expect(menu != nil)
        #expect(menu?.items.first?.title == "Delete 3 Searches")
    }

    @Test("Searches mixed with Exploration collections still get a bulk Delete")
    func mixedExplorationSelectionMenu() {
        let viewModel = makeViewModel()
        let nodes = [searchNode("a"), explorationCollectionNode()]
        let menu = viewModel.outlineConfiguration.contextMenuForMultiple?(nodes)
        #expect(menu != nil)
        #expect(menu?.items.first?.title == "Delete 2 Items")
    }

    @Test("Exploration collections keep their existing bulk Delete wording")
    func explorationCollectionsOnlyMenu() {
        let viewModel = makeViewModel()
        let nodes = [explorationCollectionNode("Refs: a"), explorationCollectionNode("Cites: b")]
        let menu = viewModel.outlineConfiguration.contextMenuForMultiple?(nodes)
        #expect(menu?.items.first?.title == "Delete 2 Collections")
    }

    @Test("Unrelated kinds still fall back to the single-row menu")
    func mixedKindsFallThrough() {
        let nodes = [
            searchNode("a"),
            ImbibSidebarNode(
                id: UUID(),
                nodeType: .flagColor(.red),
                displayName: "Red",
                iconName: "flag.fill"
            ),
        ]
        let viewModel = makeViewModel()
        let menu = viewModel.outlineConfiguration.contextMenuForMultiple?(nodes)
        #expect(menu == nil)
    }

    @Test("Deleting Exploration searches routes to the store")
    func deleteRoutesToStore() {
        let store = MockPublicationStore()
        let viewModel = ImbibSidebarViewModel(store: store)
        viewModel.deleteExplorationSearches([UUID(), UUID()])
        #expect(store.deleteSmartSearchCallCount == 2)
    }
}
#endif
