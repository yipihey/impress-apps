//
//  ImpressShellUITests.swift
//  impress-iOSUITests
//
//  The regression oracle for impress-iOS: the sidebar built from
//  `AppShellConfiguration.impress` narrowed by `presenting([.message, .figure,
//  .task, .publication, .manuscript])`, five lists over `RecordListHost`, five
//  CHASSIS detail panes, and the settings screen rendered from
//  `AppSettingsConfiguration.impress`.
//
//  Two of the panes were `#if os(macOS)` until this shell wanted them (D9); the
//  publication pane was imbib-APP-PRIVATE until I2 lifted it into PMC, and the
//  read-only manuscript pane is I2's new one. The two tests at the bottom are
//  the proof that the user's report — "it recognizes very few types, none of
//  the ones we have multiple entries" — no longer describes the app.
//
//  PORTRAIT on iPhone, and that is an I2 change with a reason. The suite used to
//  pin `.landscapeLeft` (copied from imprint-iOSUITests and impart-iOSUITests,
//  where it keeps an iPad from hiding the sidebar behind a toggle). On a phone
//  the split view is a STACK in both orientations — the sidebar is the whole
//  screen either way — so landscape bought nothing and cost the thing this wave
//  made scarce: HEIGHT. Landscape gives a 402-point list; the sidebar grew from
//  three sections to eight in I2, and a lazy `List` only instantiates what fits,
//  so half the contract was unreachable at that height. Portrait doubles it.
//

import XCTest

final class ImpressShellUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = IOSTestApp.launchSeeded()
    }

    override func tearDown() {
        app?.terminate()
        app = nil
    }

    // MARK: - Sidebar: what the preset permits AND this host can present

    func testSidebarShowsExactlyTheSectionsThisHostCanPresent() {
        // ONE pass over the whole sidebar, collecting every section header it
        // renders. I2 took this sidebar from three sections to eight, and a
        // SwiftUI `List` releases off-screen rows — so `exists` on a section
        // below the fold is false for a reason that has nothing to do with the
        // contract under test, and a per-identifier scroll would leave the list
        // at the bottom before the next check. Collecting once and asserting
        // against the SET is the only form of this test that cannot pass or
        // fail for a scroll-position reason.
        let sidebar = allSidebarIdentifiers()
        capture("sidebar")

        // The POSITIVES are asserted on the section's selectable NODE, not on
        // its header. Two reasons, and the second is the load-bearing one:
        // a node is what a user can actually reach (a section whose rows are
        // all gone is invisible whatever its header does), and a header is a
        // 20-point label that a scroll can park behind the navigation bar
        // between two collections — `sidebar.section.manuscripts` went missing
        // from a twenty-step sweep while every row of that section was found.
        for present in [
            ImpressA11y.allMessagesNode,
            ImpressA11y.allFiguresNode,
            ImpressA11y.allTasksNode,
            // I2: the five the two new chassis surfaces unlocked. Every one of
            // these sections was in `declaredAbsentSections` before this wave.
            ImpressA11y.inboxNode,
            ImpressA11y.allManuscriptsNode,
            ImpressA11y.redFlaggedPapersNode,
            ImpressA11y.dismissedNode,
        ] {
            XCTAssertTrue(
                sidebar.contains(present),
                "\(present) is permitted by the preset, its kind is presentable "
                    + "and this host has rows for it")
        }

        // DECLARED ABSENT, not empty — two different gates (kind, content),
        // asserted together because the user-visible promise is the same.
        for absent in ImpressA11y.declaredAbsentSections {
            XCTAssertFalse(
                sidebar.contains(absent),
                "\(absent) is gated off for this host and must be absent, "
                    + "never an empty section")
        }

        // The LIBRARY row IS host-supplied — libraries sit above the collection
        // tree, which is the case `RecordSidebarSectionContent` exists for.
        XCTAssertTrue(
            sidebar.contains { $0.hasPrefix(ImpressA11y.libraryNodePrefix) },
            "the seeded library should render as a host node")
    }

    // MARK: - Mail: list + the shared chassis detail pane

    func testSelectingAMailMessageShowsTheChassisDetailPane() {
        let any = app.descendants(matching: .any)
        XCTAssertTrue(
            select(ImpressA11y.allMessagesNode, expecting: ImpressA11y.messageList),
            "RecordListHost should render the mail list")
        let rows = any.matching(NSPredicate(format: "identifier BEGINSWITH %@", "messageRow."))
        XCTAssertGreaterThan(rows.count, 0, "seeded inbox messages should render as rows")
        capture("mail-list")

        let starred = app.staticTexts[ImpressSeed.starredSubject]
        XCTAssertTrue(starred.waitForExistence(timeout: 15))
        starred.tap()

        XCTAssertTrue(
            any[ImpressA11y.messageDetail].waitForExistence(timeout: 20),
            "MessageDetailPane — the SHARED pane, unchanged — should fill the detail column")
        // The Info tab's rows come from the descriptor's declared tabs.
        XCTAssertTrue(app.staticTexts["From"].waitForExistence(timeout: 15))
        capture("mail-detail")
    }

    // MARK: - The mixed-kind claim: three kinds, one shell

    func testFiguresAndTasksRenderThroughTheirNewlyCrossPlatformChassisPanes() {
        let any = app.descendants(matching: .any)

        XCTAssertTrue(
            select(ImpressA11y.allFiguresNode, expecting: ImpressA11y.figureList),
            "the Figures list should render")
        capture("figure-list")
        let figure = app.staticTexts[ImpressSeed.figureTitle]
        XCTAssertTrue(figure.waitForExistence(timeout: 15))
        figure.tap()
        XCTAssertTrue(
            any[ImpressA11y.figureDetail].waitForExistence(timeout: 20),
            "FigureDetailPane was macOS-only until D9 un-gated it; this is the proof it runs")
        capture("figure-detail")

        // Back to the sidebar before the next kind. On a phone the split view
        // is a STACK: tapping a row PUSHED the figure detail, so the sidebar is
        // two pops away and its rows are not in the accessibility tree until
        // they are back on screen.
        returnToSidebar()
        XCTAssertTrue(
            select(ImpressA11y.allTasksNode, expecting: ImpressA11y.taskList),
            "the Agents (Tasks) list should render")
        let task = app.staticTexts[ImpressSeed.taskTitle]
        XCTAssertTrue(task.waitForExistence(timeout: 15))
        task.tap()
        XCTAssertTrue(
            any[ImpressA11y.taskDetail].waitForExistence(timeout: 20),
            "AgentRecordDetailPane, likewise")
        capture("task-detail")
    }

    // MARK: - Publications: the LIFTED pane (I2 gap 1)

    /// The user's report, as a test: "none of the ones we have multiple entries
    /// like publications and manuscripts". This walks a library → a paper →
    /// every tab the publication descriptor declares.
    func testSelectingAPaperShowsTheLiftedChassisDetailPaneWithEveryDescriptorTab() {
        let any = app.descendants(matching: .any)
        let library = revealLibraryNode()
        XCTAssertTrue(library.exists, "the seeded library row")
        library.tap()
        if !any[ImpressA11y.publicationList].waitForExistence(timeout: 15) {
            library.tap()
        }
        XCTAssertTrue(
            any[ImpressA11y.publicationList].waitForExistence(timeout: 15),
            "IOSPublicationListPane — RecordListHost over PublicationListCore")
        let rows = any.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "publicationRow."))
        XCTAssertGreaterThan(rows.count, 0, "the two imported BibTeX entries should be rows")
        capture("publication-list")

        let paper = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", ImpressSeed.publicationTitleFragment)
        ).firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 15))
        paper.tap()

        XCTAssertTrue(
            any[ImpressA11y.publicationDetail].waitForExistence(timeout: 20),
            "IOSPublicationDetailPane should fill the detail column")

        // Info / PDF / Notes / BibTeX — the tab set comes from
        // `PublicationRecordKind.descriptor`, so this asserts the DECLARATION
        // renders, not four hardcoded tabs.
        XCTAssertTrue(
            any[ImpressA11y.DetailTabs.info].waitForExistence(timeout: 15),
            "the Info tab pane should render")
        capture("publication-info")

        selectTab("PDF")
        XCTAssertTrue(
            any[ImpressA11y.DetailTabs.pdf].waitForExistence(timeout: 15),
            "the PDF tab should render its honest offline state, not a blank pane")
        capture("publication-pdf")

        // BibTeX is PMC's `BibTeXTab` — the very same view macOS renders. It is
        // asserted by CONTENT rather than by the tab identifier: the tab wraps a
        // syntax-highlighted editor that publishes its own accessibility
        // container, so the wrapper's identifier is not reliably queryable
        // (imbib's detail-tab suite anchors on the entry text for the same
        // reason). The `@` and the Copy button are what a user sees.
        selectTab("BibTeX")
        // Capture BEFORE asserting: when this fails, the screenshot is the only
        // thing that says whether the pane rendered the wrong state or nothing
        // (imbib's detail-tab suite's rule, and `continueAfterFailure` is off).
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "@"))
            .firstMatch.waitForExistence(timeout: 15)
        capture("publication-bibtex")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "@"))
                .firstMatch.exists
                || app.buttons["Copy"].exists
                || app.buttons["Edit"].exists,
            "the shared BibTeXTab should show the imported entry")

        // Notes binds the shared `PublicationNotesDocument`'s freeform half
        // through `IOSNotesEditorView`, a UITextView wrapper.
        selectTab("Notes")
        XCTAssertTrue(
            app.textViews.firstMatch.waitForExistence(timeout: 15),
            "the Notes tab should show an editor")
        capture("publication-notes")

        // The Explore row is gated on a `LibraryManager` this shell does not
        // inject — DECLARED absent, and the assertion is what keeps it declared
        // rather than accidentally working against imbib's exploration library.
        selectTab("Info")
        XCTAssertFalse(
            app.staticTexts["Explore"].exists,
            "impress injects no LibraryManager, so the Explore row must not render")
    }

    // MARK: - Manuscripts: the read-only pane (I2 gap 2)

    func testSelectingAManuscriptShowsTheReadOnlyChassisPane() {
        let any = app.descendants(matching: .any)
        XCTAssertTrue(
            select(ImpressA11y.allManuscriptsNode, expecting: ImpressA11y.manuscriptList),
            "the Manuscripts list should render over ManuscriptRowData")
        let rows = any.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "manuscriptRow."))
        XCTAssertGreaterThan(rows.count, 0, "the seeded manuscript should render as a row")
        capture("manuscript-list")

        let manuscript = app.staticTexts[ImpressSeed.manuscriptTitle]
        XCTAssertTrue(manuscript.waitForExistence(timeout: 15))
        manuscript.tap()

        XCTAssertTrue(
            any[ImpressA11y.manuscriptDetail].waitForExistence(timeout: 20),
            "IOSManuscriptReadOnlyPane should fill the detail column")
        XCTAssertTrue(
            any[ImpressA11y.DetailTabs.info].waitForExistence(timeout: 15),
            "the Info tab should render title/status/authors")
        capture("manuscript-info")

        // The Source tab is READ-ONLY — a selectable monospaced body, and no
        // text view to type into. `textViews` is what an editor exposes; its
        // absence is the assertion.
        selectTab("Source")
        XCTAssertTrue(
            any[ImpressA11y.DetailTabs.source].waitForExistence(timeout: 15),
            "the Source tab should render the body")
        XCTAssertEqual(
            app.textViews.count, 0,
            "the read-only pane must expose no editor: that is imprint's job")
        capture("manuscript-source")

        // The seed's manuscript is MARKDOWN, whose preview is free (no compile
        // step) — so the Preview tab renders rather than handing off.
        selectTab("Preview")
        XCTAssertTrue(
            any[ImpressA11y.DetailTabs.pdf].waitForExistence(timeout: 15),
            "markdown renders through MarkdownSourcePreview with no compiler")
        capture("manuscript-preview")

        // The handoff affordance, which is what a typst manuscript would get
        // INSTEAD of a preview.
        XCTAssertTrue(
            any[ImpressA11y.openInImprintButton].exists,
            "the pane offers the imprint handoff rather than pretending to compile")
    }

    // MARK: - Settings

    func testSettingsRendersTheAvailabilityFilteredPreset() {
        let gear = app.buttons[ImpressA11y.settingsButton]
        XCTAssertTrue(gear.waitForExistence(timeout: 30))
        gear.tap()

        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 15),
            "IOSSettingsScreen should present over `AppSettingsConfiguration.impress`")

        let any = app.descendants(matching: .any)
        XCTAssertTrue(any[ImpressA11y.settingsAppearanceRow].exists,
                      "Appearance is `.everywhere` and comes from the chassis builtin")

        // Asserted BEFORE any scrolling: a lazy List releases off-screen rows,
        // so a negative after a scroll would pass for the wrong reason.
        for macOnly in ImpressA11y.settingsMacOnlyRows {
            XCTAssertFalse(
                any[macOnly].exists,
                "\(macOnly) requires a capability iOS never grants")
        }
        capture("settings")

        any[ImpressA11y.settingsAppearanceRow].tap()
        XCTAssertTrue(
            app.navigationBars.element.waitForExistence(timeout: 15))
        capture("settings-appearance")
    }

    // MARK: - Revealing a sidebar row

    /// Wait for `identifier`, scrolling the sidebar DOWN until it appears.
    ///
    /// `swipeUp` and never `swipeDown`: a downward swipe at the top of the list
    /// is PULL-TO-REFRESH, not scrolling, and a bidirectional search fires a
    /// refresh per attempt (imbib's list suite's finding). The sidebar is the
    /// leading column, so the swipe is aimed at the app rather than a column
    /// query — on a compact-width device the split view is a stack and the
    /// sidebar IS the screen.
    @discardableResult
    private func reveal(_ identifier: String, attempts: Int = 10) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        if element.waitForExistence(timeout: 30) { return element }
        for _ in 0..<attempts {
            scrollSidebarDown()
            if element.exists { return element }
        }
        return element
    }

    /// Scroll the sidebar list one screen down.
    ///
    /// Aimed at the LIST, not at the application element: a swipe on the app
    /// starts at the window's centre, and on this shell that point can sit on a
    /// row whose leading/trailing swipe actions consume the gesture. Always
    /// `swipeUp` — a downward swipe at the top of the list is PULL-TO-REFRESH,
    /// not scrolling, and a bidirectional search fires one refresh per attempt
    /// (imbib's list suite's finding).
    private func scrollSidebarDown(velocity: XCUIGestureVelocity = .default) {
        let list = app.collectionViews.firstMatch
        if list.exists {
            list.swipeUp(velocity: velocity)
        } else {
            app.swipeUp(velocity: velocity)
        }
    }

    /// The seeded library's row, whose UUID `createLibrary` chooses.
    @discardableResult
    private func revealLibraryNode(attempts: Int = 10) -> XCUIElement {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", ImpressA11y.libraryNodePrefix))
        if query.firstMatch.waitForExistence(timeout: 30) { return query.firstMatch }
        for _ in 0..<attempts {
            scrollSidebarDown()
            if query.count > 0 { return query.firstMatch }
        }
        return query.firstMatch
    }

    /// Every `sidebar.*` identifier the sidebar renders, collected in one
    /// downward sweep. "Not on screen" is not "not present", and a lazy list
    /// makes the two look identical — so both the positive and the negative
    /// assertions read this SET rather than asking `exists` at whatever scroll
    /// offset they inherit.
    ///
    /// `.slow` and twenty steps rather than ten full-page swipes: a page-sized
    /// jump can carry a section header from below the fold to above the
    /// navigation bar between two collections, and the row is then never seen
    /// even though it rendered. (That is exactly how `sidebar.section
    /// .manuscripts` went missing from this sweep while the Figures section
    /// BELOW it was found.)
    private func allSidebarIdentifiers(attempts: Int = 20) -> Set<String> {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "sidebar."))
        _ = query.firstMatch.waitForExistence(timeout: 30)
        var seen = Set<String>()
        for step in 0...attempts {
            seen.formUnion(query.allElementsBoundByIndex.map(\.identifier))
            if step < attempts { scrollSidebarDown(velocity: .slow) }
        }
        return seen
    }

    /// Pop back to the sidebar column.
    ///
    /// Compact width collapses `NavigationSplitView` into a stack, so a test
    /// that walks two kinds has to unwind the pushes between them.
    private func returnToSidebar(maxPops: Int = 3) {
        for _ in 0..<maxPops {
            if app.descendants(matching: .any)[ImpressA11y.allMessagesNode].exists { return }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists, back.isHittable else { return }
            back.tap()
        }
    }

    // MARK: - Selection

    /// Tap a tab-bar button by its label.
    ///
    /// The tab BAR is tried first: a SwiftUI `TabView` with
    /// `.tabBarMinimizeBehavior` puts more than one element with the tab's
    /// label in the tree, so `app.buttons[label]` raises "Multiple matching
    /// elements found" instead of tapping (imbib's detail-tab suite's finding).
    private func selectTab(_ label: String) {
        let barButton = app.tabBars.buttons[label].firstMatch
        if barButton.waitForExistence(timeout: 5), barButton.isHittable {
            barButton.tap()
            return
        }
        let fallback = app.buttons.matching(
            NSPredicate(format: "label == %@", label)
        ).allElementsBoundByIndex.first { $0.isHittable }
        fallback?.tap()
    }

    /// Tap a sidebar node and wait for its list.
    ///
    /// Retries the tap ONCE: the seed posts a structural store mutation, which
    /// bumps `dataVersion` and makes `RecordSidebarView` rebuild its rows, and a
    /// tap landing during that rebuild can hit a row that is being replaced.
    /// (It is NOT what made the first cold-install run fail — that was the seed
    /// silently failing to open a store whose directory did not exist yet. The
    /// retry stayed because the race it covers is real and one extra tap is
    /// cheaper than a flaky lane.)
    private func select(_ nodeID: String, expecting listID: String) -> Bool {
        let any = app.descendants(matching: .any)
        let node = reveal(nodeID)
        guard node.exists else { return false }
        node.tap()
        if any[listID].waitForExistence(timeout: 15) { return true }
        node.tap()
        return any[listID].waitForExistence(timeout: 15)
    }

    // MARK: - Screenshots

    /// Attach to the result bundle AND write a PNG to the runner's temp dir, so
    /// evidence can be opened without unpacking an `.xcresult`. `.keepAlways`
    /// because the default discards attachments from PASSING tests.
    @discardableResult
    private func capture(_ name: String) -> XCUIScreenshot {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "impress-ios-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("impress-ios-\(name).png")
        try? shot.pngRepresentation.write(to: url)
        return shot
    }
}
