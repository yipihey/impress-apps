//
//  SidebarMenuCommandsTests.swift
//  PublicationManagerCoreTests
//
//  The sidebar's side of three menu commands that posted to nobody until
//  2026-09-25: Go ▸ Back / Forward (⌘[ / ⌘]) and View ▸ Show Search (⌘2).
//

#if os(macOS)
import XCTest

@testable import PublicationManagerCore

@MainActor
final class SidebarMenuCommandsTests: XCTestCase {

    private func wiredViewModel(
        persistence: SidebarPersistenceScope? = nil
    ) -> ImbibSidebarViewModel {
        let manager = LibraryManager()
        manager.loadLibraries()
        let vm = ImbibSidebarViewModel(
            store: MockPublicationStore(),
            persistence: persistence ?? .inMemory(),
            shellConfiguration: .imbib,
            sidebarComposition: nil)
        vm.configure(
            libraryManager: manager,
            libraryViewModel: LibraryViewModel(),
            searchViewModel: SearchViewModel())
        return vm
    }

    // MARK: - NavigationHistory

    func testHistoryPushBackForwardAndTruncation() {
        let history = NavigationHistory<Int>()
        XCTAssertFalse(history.canGoBack)
        history.push(1); history.push(2); history.push(2); history.push(3)
        XCTAssertEqual(history.historyCount, 3, "a repeated state is one entry")
        XCTAssertEqual(history.goBack(), 2)
        XCTAssertEqual(history.goBack(), 1)
        XCTAssertNil(history.goBack())
        XCTAssertEqual(history.goForward(), 2)
        history.push(9)
        XCTAssertFalse(history.canGoForward, "a new navigation drops the forward entries")
        XCTAssertEqual(history.goBack(), 2)
    }

    func testHistoryPruneKeepsThePositionOnTheSameEntry() {
        let history = NavigationHistory<Int>()
        [1, 2, 3, 4].forEach(history.push)
        _ = history.goBack()  // at 3
        history.removeAll { $0 == 2 }
        XCTAssertEqual(history.current, 3)
        XCTAssertEqual(history.goBack(), 1)
    }

    func testHistoryIsBounded() {
        let history = NavigationHistory<Int>(maxHistorySize: 3)
        (1...5).forEach(history.push)
        XCTAssertEqual(history.historyCount, 3)
        XCTAssertEqual(history.goBack(), 4)
        XCTAssertEqual(history.goBack(), 3)
        XCTAssertNil(history.goBack())
    }

    // MARK: - Go ▸ Back / Forward

    /// Selection changes are recorded (with the launch selection first) and
    /// Back / Forward walk them without recording themselves.
    func testSidebarSelectionIsRecordedAndBackForwardNavigate() {
        let vm = wiredViewModel()
        XCTAssertEqual(vm.selectedTab, .inbox)
        vm.navigateToTab(.searchForm(.adsModern))
        vm.navigateToTab(.searchForm(.arxivAdvanced))
        XCTAssertEqual(vm.navigationHistory.historyCount, 3, "inbox → ADS → arXiv")
        XCTAssertTrue(vm.navigationHistory.canGoBack)
        XCTAssertFalse(vm.navigationHistory.canGoForward)

        XCTAssertEqual(vm.navigateBack(), .searchForm(.adsModern))
        XCTAssertEqual(vm.selectedTab, .searchForm(.adsModern))
        XCTAssertEqual(vm.navigationHistory.historyCount, 3, "going back records nothing")
        XCTAssertEqual(vm.navigateBack(), .inbox)
        XCTAssertEqual(vm.selectedTab, .inbox)
        XCTAssertNil(vm.navigateBack(), "nothing before the launch selection")
        XCTAssertFalse(vm.navigationHistory.canGoBack)

        XCTAssertEqual(vm.navigateForward(), .searchForm(.adsModern))
        XCTAssertEqual(vm.navigateForward(), .searchForm(.arxivAdvanced))
        XCTAssertFalse(vm.navigationHistory.canGoForward)
    }

    /// A tab the sidebar has no node for (a deleted collection) is neither
    /// recorded nor navigated to.
    func testAPlaceWithNoNodeIsNotRecorded() {
        let vm = wiredViewModel()
        vm.navigateToTab(.searchForm(.adsModern))
        let before = vm.navigationHistory.historyCount
        vm.navigateToTab(.collection(UUID()))
        XCTAssertEqual(vm.navigationHistory.historyCount, before)
    }

    func testTheMenuPostIsForTheSidebarWhoseHistoryItNames() {
        let vm = wiredViewModel()
        let other = wiredViewModel()
        XCTAssertTrue(ImbibSidebarLifecycle.isAddressed(
            Notification(name: .navigateBack, object: vm.navigationHistory), to: vm))
        XCTAssertFalse(ImbibSidebarLifecycle.isAddressed(
            Notification(name: .navigateBack, object: other.navigationHistory), to: vm))
        XCTAssertTrue(ImbibSidebarLifecycle.isAddressed(
            Notification(name: .navigateBack, object: nil), to: vm),
            "the command palette posts with no object")
    }

    // MARK: - View ▸ Show Search (⌘2)

    func testShowSearchOpensTheLastUsedFormElseTheFirst() {
        let scope = SidebarPersistenceScope.inMemory()
        let vm = wiredViewModel(persistence: scope)
        XCTAssertEqual(vm.showSearchTarget, vm.searchForms.first, "nothing used yet: the section's first form")

        vm.navigateToTab(.searchForm(.arxivFeed))
        XCTAssertEqual(scope.loadLastSearchForm(), .arxivFeed, "opening a form records it")
        vm.navigateToTab(.inbox)
        XCTAssertEqual(vm.showSearchTarget, .arxivFeed)

        // Persisted: a new sidebar over the same state goes to the same form.
        let relaunched = wiredViewModel(persistence: scope)
        XCTAssertEqual(relaunched.showSearchTarget, .arxivFeed)
    }

    func testAHiddenLastUsedFormFallsBackToTheFirstVisible() {
        let vm = wiredViewModel(persistence: .inMemory(lastSearchForm: .openalex))
        vm.searchForms = [.adsClassic, .nlSearch]
        XCTAssertEqual(vm.showSearchTarget, .adsClassic)
    }
}
#endif
