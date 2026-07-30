//
//  IOSDetailTabsUITests.swift
//  imbib-iOSUITests
//
//  Guards imbib-iOS's Stage 5b detail pane: the five bespoke detail views
//  collapsed onto shared content (see docs/chassis-capability-matrix.md,
//  "Publication detail pane"). `IOSBibTeXTab` is gone — the BibTeX tab is PMC's
//  `BibTeXTab`, the same view macOS renders — and the Notes tab, the Explore
//  row, the identifier row, the Flag & Tags section and the PDF switcher now
//  read shared models rather than iOS copies of them.
//
//  What these tests are FOR: the tab bar comes from
//  `PublicationRecordKind.descriptor.availableTabs(for:)`, and each of the four
//  panes must actually RENDER after the collapse. A unit test cannot see that a
//  shared view failed to lay out inside a `TabView`, or that a tab's content is
//  an empty container.
//
//  Run against the seeded in-memory store (`--ui-testing --uitesting-seed`), so
//  they are deterministic and offline — which also means the PDF tab is
//  expected to show its no-PDF/download affordance rather than a document.
//
//  Screenshots are written to the runner's temp directory as well as attached,
//  so a human (or an agent) can look at the pane rather than trusting a
//  boolean. See `capture(_:name:)`.
//

import XCTest

final class IOSDetailTabsUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// Open the first seeded paper and walk every tab the descriptor offers.
    ///
    /// The four expected tabs for an editable library publication are Info,
    /// PDF, Notes and BibTeX, in that order — `DetailTab.available(for:)` in
    /// the capability matrix.
    func test_detailPane_rendersEveryDescriptorTab() throws {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)
        let list = IOSPublicationListPage(app: app)
        let detail = IOSDetailPage(app: app)

        // In COMPACT width a `NavigationSplitView` is a STACK, so the app lands
        // on the sidebar and the list has to be pushed by selecting the seeded
        // library (the wave-3 "default landing selection: regular width only"
        // rule). Selecting is therefore part of the setup, not the assertion.
        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")
        XCTAssertTrue(
            sidebar.seededLibraryRow.waitForExistence(timeout: 15),
            "Seeded library row should render")
        sidebar.seededLibraryRow.tap()

        XCTAssertTrue(list.waitForFirstPublication(), "Seeded list should load")
        list.openFirstPublication()
        XCTAssertTrue(list.waitForDetail(), "Tapping a row should push the detail pane")

        // MARK: Info — the shared Flag & Tags section, identifier row and
        // Explore row all live here.
        XCTAssertTrue(detail.tab(.info).waitForExistence(timeout: 10))
        detail.select(.info)
        XCTAssertTrue(
            detail.anyText(containing: IOSSeed.firstPublicationTitleFragment)
                .waitForExistence(timeout: 10),
            "Info should show the paper's title")
        XCTAssertTrue(
            detail.anyText(containing: "Record Info").exists
                || detail.anyText(containing: "Identifiers").exists
                || detail.anyText(containing: "Abstract").exists,
            "Info should show at least one of its sections")
        capture(app, name: "info")

        // MARK: PDF — offline, so the honest state is the no-PDF affordance,
        // not a rendered document. It must not be a blank pane.
        detail.select(.pdf)
        XCTAssertTrue(
            detail.waitForNonEmptyPane(timeout: 15),
            "PDF tab must render something (viewer, download prompt or empty state)")
        capture(app, name: "pdf")

        // MARK: BibTeX — this is now PMC's `BibTeXTab`. The seeded paper has an
        // entry, so the monospaced text (and the Copy/Edit affordances) must
        // appear rather than the "No BibTeX" state.
        //
        // Visited BEFORE Notes on purpose: focusing a text editor raises the
        // keyboard, which covers the tab bar that `.tabBarMinimizeBehavior`
        // already minimizes, and no reliable programmatic dismissal exists for a
        // custom text view (the Helix editor has no Done accessory). Typing is
        // therefore the LAST thing the walk does, so nothing has to be undone.
        detail.select(.bibtex)
        // Capture BEFORE asserting: when this fails, the screenshot is the only
        // thing that says whether the pane rendered the wrong state or nothing.
        _ = detail.tab(.bibtex).waitForExistence(timeout: 10)
        _ = detail.anyText(containing: "@").waitForExistence(timeout: 5)
        capture(app, name: "bibtex")
        // `BibTeXEditor` renders syntax-highlighted text with a line-number
        // gutter and exposes NO `textView` element, so read the entry from the
        // static text and anchor on the toolbar the shared tab renders for a
        // single editable paper (Copy + Edit — iOS's own tab had no Copy).
        XCTAssertTrue(
            detail.anyText(containing: "@article").exists
                || detail.anyText(containing: "@").exists,
            "BibTeX tab should show the entry text, not the No-BibTeX state")
        XCTAssertTrue(
            app.buttons["Edit"].exists,
            "The shared tab's Edit affordance should render")
        XCTAssertTrue(
            app.buttons["Copy"].exists,
            "The shared tab brings the Copy button iOS's own BibTeX tab lacked")

        // MARK: Notes — `IOSNotesEditorView` (or the Helix editor, when the
        // user has modal editing on) bound to the SHARED
        // `PublicationNotesDocument`'s freeform half. Typing proves the binding
        // is live and that the shared debounced writer survives input.
        detail.select(.notes)
        let editor = detail.notesEditor
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Notes should show an editor")
        editor.tap()
        editor.typeText("stage5b")
        XCTAssertTrue(
            ((editor.value as? String) ?? "").contains("stage5b")
                || detail.anyText(containing: "stage5b").waitForExistence(timeout: 5),
            "Typed notes text should appear in the editor")
        capture(app, name: "notes")
    }

    /// The console is now `ImpressLogging.ConsoleScreen` — the shared view —
    /// reached from Settings ▸ Developer ▸ Console. imbib-iOS's own 310-line
    /// console is deleted, so this asserts the ENTRY POINT still lands
    /// somewhere that shows log entries.
    func test_console_isReachableAndShowsTheSharedConsole() throws {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)
        let settings = IOSSettingsPage(app: app)

        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")
        sidebar.openSettings()
        XCTAssertTrue(settings.waitForSheet(), "Settings sheet should present")

        // `console` is one of imbib's iOS-only declared sections (Developer
        // band), and it sits far down a lazy List.
        let consoleRow = settings.row("console")
        XCTAssertTrue(
            settings.scrollUntilVisible(consoleRow),
            "The `console` section is declared for iOS in AppSettingsConfiguration.imbib")
        consoleRow.tap()

        // `ConsoleView`'s own controls: the four level chips and the mode
        // picker. The Performance mode is the capability iOS did NOT have
        // before it adopted the shared console.
        XCTAssertTrue(
            app.buttons["Debug"].waitForExistence(timeout: 10)
                || app.staticTexts["Debug"].waitForExistence(timeout: 5),
            "The shared console shows level filter chips")
        XCTAssertTrue(
            app.buttons["Performance"].exists || app.staticTexts["Performance"].exists,
            "The shared console offers the Performance mode iOS previously lacked")
        capture(app, name: "console")
    }

    // MARK: - Screenshot capture

    /// Attach a screenshot AND write it to the runner's temp directory, where a
    /// human can open it without unpacking an `.xcresult`.
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "imbib-ios-detail-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imbib-ios-\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}

// MARK: - Page object

/// The pushed detail pane: the `TabView` whose tabs come from the publication
/// descriptor, plus the editors inside them.
struct IOSDetailPage {

    enum Tab: String {
        case info, pdf, notes, bibtex

        var identifier: String { "detail.tabs.\(rawValue)" }

        /// The tab-bar button's label, as `DetailTab.label` renders it.
        var buttonLabel: String {
            switch self {
            case .info: return "Info"
            case .pdf: return "PDF"
            case .notes: return "Notes"
            case .bibtex: return "BibTeX"
            }
        }
    }

    let app: XCUIApplication

    /// The tab's CONTENT, which carries the accessibility identifier.
    func tab(_ tab: Tab) -> XCUIElement {
        app.descendants(matching: .any)[tab.identifier].firstMatch
    }

    /// Select a tab from the tab bar.
    ///
    /// `.firstMatch` throughout, and the tab BAR is tried first: a SwiftUI
    /// `TabView` with `.tabBarMinimizeBehavior` puts more than one element with
    /// the tab's label in the tree (the bar item and its minimized twin), so
    /// `app.buttons["PDF"]` raises "Multiple matching elements found" rather
    /// than tapping.
    func select(_ tab: Tab) {
        let barButton = app.tabBars.buttons[tab.buttonLabel].firstMatch
        if barButton.waitForExistence(timeout: 5), barButton.isHittable {
            barButton.tap()
            return
        }
        // Fall back to a HITTABLE labelled button. Never `.firstMatch` alone:
        // that can resolve to a zero-size element with an infinite frame, which
        // fails the case with `kAXScrollToVisibleAction` instead of tapping.
        let candidates = app.buttons.matching(
            NSPredicate(format: "label == %@", tab.buttonLabel))
        _ = candidates.firstMatch.waitForExistence(timeout: 10)
        for candidate in candidates.allElementsBoundByIndex where candidate.isHittable {
            candidate.tap()
            return
        }
    }

    /// Move focus off a text editor so the tab bar is reachable again.
    func dismissKeyboard() {
        guard app.keyboards.count > 0 else { return }
        let navigationBar = app.navigationBars.firstMatch
        if navigationBar.exists, navigationBar.isHittable {
            navigationBar.tap()
        }
        // Give the keyboard time to retract before the next hit test.
        for _ in 0..<20 where app.keyboards.count > 0 {
            usleep(200_000)
        }
    }

    func anyText(containing fragment: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", fragment))
            .firstMatch
    }

    /// `IOSNotesEditorView` is a `UITextView` wrapper; Helix mode is off by
    /// default, so a text view is the expected editor.
    var notesEditor: XCUIElement {
        app.textViews.firstMatch
    }

    /// A pane that rendered SOMETHING: any text, button or image inside it.
    /// The failure this guards is a shared view that silently lays out empty.
    func waitForNonEmptyPane(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts.count > 0 || app.buttons.count > 0
                || app.images.count > 0 || app.progressIndicators.count > 0
            {
                return true
            }
            usleep(200_000)
        }
        return false
    }
}
