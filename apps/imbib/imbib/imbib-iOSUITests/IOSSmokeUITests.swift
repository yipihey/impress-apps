//
//  IOSSmokeUITests.swift
//  imbib-iOSUITests
//
//  A small, real XCUITest guard for the revived imbib-iOS views. These run
//  against a seeded in-memory store (launch args `--ui-testing
//  --uitesting-seed`, see imbibApp.seedUITestDataIfNeeded) so they are fully
//  deterministic and offline. Each test exercises a distinct revived surface:
//
//   1. launch + sidebar render (IOSContentView + the shared RecordSidebarView)
//   2. settings navigation (IOSSettingsView sheet)
//   3. list -> detail navigation (IOSUnifiedPublicationListWrapper -> DetailView)
//

import XCTest

final class IOSSmokeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Terminate the app between cases.
    ///
    /// Each case in this class calls `IOSTestApp.launchSeeded()`, and the
    /// settings-persistence case launches TWICE. Leaving a live instance behind
    /// means the next `launch()` races a still-terminating process; on a loaded
    /// host that surfaced as the *second and third* case in a session dying with
    /// "crashed with signal kill" while each passed in isolation — a failure mode
    /// that looks like a product bug and is really session hygiene.
    override func tearDown() {
        XCUIApplication().terminate()
        super.tearDown()
    }

    /// Keep a screenshot in the result bundle.
    ///
    /// `.keepAlways` on purpose: the default discards attachments from PASSING
    /// tests, which makes them useless as evidence that a surface renders
    /// correctly — the case where you most want to look is the one that passed.
    private func attach(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The app launches into the split view and the sidebar (with its
    /// Settings toolbar button) renders. Guards IOSContentView + IOSSidebarHost.
    func test_appLaunches_showsSidebar() {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)

        XCTAssertTrue(
            sidebar.waitUntilLoaded(),
            "Sidebar (settings button) should appear after launch"
        )
    }

    /// Tapping the sidebar gear opens the Settings sheet (IOSSettingsView),
    /// which can then be dismissed. Guards the revived settings surface + sheet
    /// navigation.
    func test_openSettings_showsSettingsSheet() {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)
        let settings = IOSSettingsPage(app: app)

        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")
        sidebar.openSettings()

        XCTAssertTrue(
            settings.waitForSheet(),
            "Settings sheet should present with the API Keys row"
        )

        settings.dismiss()
    }

    // MARK: - Stage 6 phase 2: the settings sheet is a renderer over a declaration

    /// The sheet renders the sections `AppSettingsConfiguration.imbib` declares
    /// for iOS, and does NOT render the four it declares as macOS-only.
    ///
    /// This is the assertion that makes the migration checkable ON DEVICE rather
    /// than only in `swift test`. The preset claims eleven shared panes plus seven
    /// iOS-shaped ones, and that four panes (General, Flags & Tags, Search & AI,
    /// E-Ink Devices) must not appear because iOS grants none of the capabilities
    /// they require. A unit test can only assert what the DECLARATION says; only a
    /// booted simulator can show that the renderer agrees with it — which is
    /// exactly the gap that let imbib-iOS's hand-written list drift from macOS's
    /// tabs in the first place.
    func test_settings_rendersDeclaredSectionsAndOmitsMacOnlyOnes() {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)
        let settings = IOSSettingsPage(app: app)

        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")
        sidebar.openSettings()
        XCTAssertTrue(settings.waitForSheet(), "Settings sheet should present")

        attach(app, named: "settings-root-declared-sections-top")

        // The macOS-only four are checked FIRST, at the top of an unscrolled list.
        // Order matters: `row(_:).exists` is a sound negative only while the list
        // is lazily built from the top — after scrolling to the bottom the early
        // rows get released and every `exists` reads false, which would make the
        // absence assertions pass for the wrong reason. Each of these four
        // requires a capability `SettingsHostCapabilities.iOS` does not grant.
        for section in ["general", "flagsAndTags", "searchAI", "eink"] {
            XCTAssertFalse(
                settings.row(section).exists,
                "`\(section)` is macOS-only; a row for it would be a dead affordance")
        }

        // Now sweep the whole screen once and compare the RENDERED inventory
        // against what `AppSettingsConfiguration.imbib` declares for iOS. Asserting
        // the full set rather than a sample is the point: a sample cannot catch a
        // row that appears but should not.
        let rendered = settings.renderedSectionIDs()
        attach(app, named: "settings-root-declared-sections-bottom")

        let expected: Set<String> = [
            "appearance", "viewing", "smartSearch",
            "notes", "pdf", "pdfStorage", "sources", "enrichment",
            "inbox", "recommendations",
            "sync", "backup",
            "importExport",
            "shortcuts", "automation", "advanced",
            "console", "help", "about",
        ]

        XCTAssertEqual(
            rendered, expected,
            """
            The rows imbib-iOS renders disagree with the sections \
            `AppSettingsConfiguration.imbib` declares for iOS. Missing: \
            \(expected.subtracting(rendered).sorted()); unexpected: \
            \(rendered.subtracting(expected).sorted()).
            """)

        // The four macOS-only panes must not have slipped in anywhere.
        XCTAssertTrue(
            rendered.isDisjoint(with: ["general", "flagsAndTags", "searchAI", "eink"]),
            "a macOS-only pane rendered a row on iOS")

        settings.dismiss()
    }

    /// A pane's toggle persists across a terminate + launch.
    ///
    /// The three-point trace, as a UI test: mutate (tap the toggle), save
    /// (`@AppStorage` writes `helixModeEnabled`), display (relaunch and read it
    /// back). Persistence is the one thing a settings reframe can break silently —
    /// a renamed key reads the code default and looks exactly like "my settings
    /// were reset" — so the frozen key inventories in
    /// `Phase2SettingsPersistenceTests` are checked here end to end, through the
    /// real renderer, the real factory and the real pane.
    ///
    /// Note the toggle survives even though `--ui-testing` routes the STORE to an
    /// in-memory database: `@AppStorage` is `UserDefaults`, a separate lane from
    /// the item store, and that distinction is the point of testing it.
    func test_settings_toggleSurvivesRelaunch() {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)
        var settings = IOSSettingsPage(app: app)

        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")
        sidebar.openSettings()
        XCTAssertTrue(settings.waitForSheet(), "Settings sheet should present")

        XCTAssertTrue(
            settings.openSection("notes"), "the Notes pane should push from its row")

        let toggle = settings.helixModeToggle
        XCTAssertTrue(
            toggle.waitForExistence(timeout: 10),
            "the Notes pane should render its modal-editing toggle")

        let after = settings.toggleAndAwaitChange(toggle)
        XCTAssertNotNil(
            after,
            "tapping the modal-editing toggle should change its value — a nil here "
                + "means the tap never landed (the control was not hittable) or the "
                + "binding is not wired to a store")
        attach(app, named: "notes-pane-toggle-after-tap")

        app.terminate()

        // Relaunched WITHOUT `IOSTestApp.launchSeeded()`, deliberately: that helper
        // ends in `dismissPendingSystemAlert()`, which waits up to 4s on each of
        // three springboard button labels. Paying that twice in one case pushed this
        // test past its time budget and got it killed as the third case in a session
        // (it passed in isolation, which is the tell). The first launch above already
        // cleared any pending alert, so the second one does not need to look again.
        let relaunched = XCUIApplication()
        relaunched.launchArguments = [IOSTestApp.uiTestingArg, IOSTestApp.seedArg]
        relaunched.launch()

        let sidebarAgain = IOSSidebarPage(app: relaunched)
        settings = IOSSettingsPage(app: relaunched)

        XCTAssertTrue(sidebarAgain.waitUntilLoaded(), "Sidebar should load after relaunch")
        sidebarAgain.openSettings()
        XCTAssertTrue(settings.waitForSheet(), "Settings sheet should present after relaunch")
        XCTAssertTrue(settings.openSection("notes"), "the Notes pane should push again")

        let persisted = settings.helixModeToggle
        XCTAssertTrue(persisted.waitForExistence(timeout: 10))
        XCTAssertTrue(settings.scrollUntilVisible(persisted))
        attach(relaunched, named: "notes-pane-toggle-after-relaunch")
        XCTAssertEqual(
            persisted.value as? String, after,
            """
            `helixModeEnabled` did not survive relaunch. Either the key was \
            renamed (which silently resets every user's preference) or the Notes \
            factory is building a different pane than the one that owns it.
            """)

        // Leave the simulator's defaults as we found them.
        _ = settings.toggleAndAwaitChange(persisted)
        settings.dismiss()
    }

    /// Selecting the seeded library shows its publications; tapping the first
    /// publication pushes the DetailView with its Info tab. Guards the
    /// list + detail cluster revival (IOSUnifiedPublicationListWrapper ->
    /// DetailView / IOSInfoTab).
    func test_selectPublication_showsDetail() {
        let app = IOSTestApp.launchSeeded()
        let sidebar = IOSSidebarPage(app: app)
        let list = IOSPublicationListPage(app: app)

        XCTAssertTrue(sidebar.waitUntilLoaded(), "Sidebar should load")
        sidebar.openSeededLibrary()

        XCTAssertTrue(
            list.waitForFirstPublication(),
            "Seeded publication row should appear in the list"
        )
        list.openFirstPublication()

        XCTAssertTrue(
            list.waitForDetail(),
            "Detail view (Info tab) should appear after selecting a publication"
        )
    }
}
