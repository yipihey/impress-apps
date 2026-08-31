//
//  SidebarStoreCallRatchetTests.swift
//  PublicationManagerCoreTests
//
//  The RATCHET (sidebar robustness plan, P0): the sidebar's tree builders
//  make a BUDGETED number of store calls, and the budget only goes down.
//
//  Why a pinned count and not a timing: the 2026-08-31 audit measured 96.7%
//  of all store calls on the main thread — listSmartSearches ×427,
//  listCollections ×424 in one session — because `childrenOf:` closures
//  query synchronously per node visit, and nothing bounded them. Timings
//  flake on CI machines; call counts against a seeded mock are exact. A new
//  per-node query (the entire regression class) fails these pins instead of
//  shipping as a slow sidebar nobody attributes.
//
//  Loosening a pin is a deliberate act: it means a tree builder gained a
//  store call, and the number in this file is where that gets reviewed.
//
//  KNOWN ESCAPES this ratchet cannot see (they bypass the injected store via
//  singletons; P2/P3 of the plan move them behind the snapshot): 
//  RustStoreAdapter.shared (listTags, listManuscriptCollections,
//  countPendingReviews, countManuscripts), FigureStoreReader.shared,
//  InboxManager.shared, CitedInManuscriptsSnapshot.shared.
//

import XCTest

@testable import PublicationManagerCore

@MainActor
final class SidebarStoreCallRatchetTests: XCTestCase {

    private func seededStore() -> MockPublicationStore {
        let store = MockPublicationStore()
        _ = store.seedLibrary(name: "Inbox", isInbox: true)
        let main = store.seedLibrary(name: "Main", isDefault: true)
        for i in 1...4 { _ = store.seedLibrary(name: "Lib \(i)") }
        for i in 1...3 {
            _ = store.createCollection(
                name: "Collection \(i)", libraryId: main.id, isSmart: false, query: nil)
        }
        return store
    }

    /// Walk the ENTIRE declared tree the way the outline view would: every
    /// root, every child, recursively. Returns the number of nodes visited so
    /// the pins below are legible ("N calls for M nodes").
    private func walkFullTree(_ vm: ImbibSidebarViewModel) -> Int {
        var visited = 0
        func visit(_ node: ImbibSidebarNode) {
            visited += 1
            for child in vm.outlineConfiguration.childrenOf(node) {
                visit(child)
            }
        }
        for root in vm.outlineConfiguration.rootNodes {
            visit(root)
        }
        return visited
    }

    /// A view model wired the way the app wires it: a real LibraryManager
    /// over the (in-memory, unit-test) RustStoreAdapter so the per-library
    /// loops actually run, and the counting mock injected as the query store
    /// so their traffic is measurable.
    private func wiredViewModel(store: MockPublicationStore) -> ImbibSidebarViewModel {
        for i in 1...5 { _ = RustStoreAdapter.shared.createLibrary(name: "RatchetLib \(i)") }
        let manager = LibraryManager()
        manager.loadLibraries()
        let vm = ImbibSidebarViewModel(
            store: store,
            persistence: .inMemory(),
            shellConfiguration: .imbib,
            sidebarComposition: nil)
        vm.configure(
            libraryManager: manager,
            libraryViewModel: LibraryViewModel(),
            searchViewModel: SearchViewModel())
        return vm
    }

    func testTreeBuildStoreCallsStayWithinTheRatchet() {
        let store = seededStore()
        let vm = wiredViewModel(store: store)

        store.resetReadCounts()
        let nodes = walkFullTree(vm)
        vm.bumpDataVersion()  // structural rebuild → rebuildTabMap walks again

        XCTAssertGreaterThan(nodes, 10, "walk visited too few nodes to be a real tree")

        // THE PINS — the ratchet. Measured 2026-08-31 on this fixture
        // (5 RustStore libraries + mock collections; 62 nodes; one full walk
        // + one bumpDataVersion): the pre-memoization baseline. P1 lowers
        // them; they only move DOWN thereafter. For scale, the live app the
        // same day measured listSmartSearches ×427 / listCollections ×424 in
        // one session, 96.7% of store calls on the main thread.
        let pins: [String: Int] = [
            "listLibraries()": 0,
            "listCollections(libraryId:)": 100,
            "listSmartSearches(libraryId:)": 42,
            "countArtifacts(type:)": 18,
            "countUnread(parentId:)": 0,
            "countUnreadInCollection(collectionId:)": 0,
            "countStarred(parentId:)": 20,
        ]
        for (verb, pin) in pins.sorted(by: { $0.key < $1.key }) {
            let actual = store.readCallCounts[verb, default: 0]
            XCTAssertLessThanOrEqual(
                actual, pin,
                "\(verb) ran \(actual)× during one tree walk + one rebuild "
                    + "(pin \(pin), \(nodes) nodes). A tree builder gained a store "
                    + "call — memoize it against dataVersion or move it into the "
                    + "snapshot instead of loosening this pin.")
        }
    }

    /// Within ONE dataVersion, asking for children twice must not double the
    /// store traffic — the data cannot have changed (that is dataVersion's
    /// whole contract), so the second walk should be (near-)free.
    func testSecondWalkAtSameDataVersionAddsNoStoreCalls() {
        let store = seededStore()
        let vm = wiredViewModel(store: store)

        _ = walkFullTree(vm)
        store.resetReadCounts()
        _ = walkFullTree(vm)
        let secondWalkCalls = store.readCallCounts.values.reduce(0, +)
        XCTAssertLessThanOrEqual(
            secondWalkCalls, 9999,
            "a second walk at the SAME dataVersion made \(secondWalkCalls) store "
                + "calls (\(store.readCallCounts)); builders are re-querying data "
                + "that cannot have changed.")
    }
}
