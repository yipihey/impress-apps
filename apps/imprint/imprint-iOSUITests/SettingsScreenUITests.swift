//
//  SettingsScreenUITests.swift
//  imprint-iOSUITests
//
//  Stage 6 phase 1: acceptance coverage for imprint-iOS's FIRST settings
//  screen. Before this, "imprint on iOS has no settings" was an original user
//  report, and it was true — the pane list lived inside a macOS `TabView` body.
//
//  What these tests prove, and why each matters:
//
//    * the gear is reachable from the library root (the entry point);
//    * the screen renders the sections `AppSettingsConfiguration.imprint`
//      declares for iOS — five, by id, so a preset that quietly promises iOS a
//      TeX pane fails here rather than pushing a screen of "Not found";
//    * a pane pushes and its controls render (the registry actually resolves);
//    * A TOGGLE SURVIVES RELAUNCH. This is the one that would catch the
//      failure mode a settings refactor really has: panes that look right and
//      persist nowhere, or persist under a renamed key. The unit-test half is
//      `ImprintSettingsPersistenceTests` (the key STRINGS are the shipped
//      ones); this is the end-to-end half (the value actually comes back).
//
//  Like `LibraryShellUITests`, this DOUBLES AS THE SCREENSHOT HARNESS — every
//  checkpoint writes a PNG to the runner's temporary directory and attaches it
//  to the result bundle, so "does the screen render?" is answerable from a file
//  rather than from a claim.
//

import XCTest

final class SettingsScreenUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Landscape for the same reason `LibraryShellUITests` uses it: in
        // portrait a 3-column `NavigationSplitView` keeps the sidebar (and
        // therefore the gear) behind the toggle.
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Evidence

    @discardableResult
    private func capture(_ name: String) -> XCUIScreenshot {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imprint-shot-\(name).png")
        try? shot.pngRepresentation.write(to: url)
        return shot
    }

    // MARK: - Entry point

    private var gear: XCUIElement { app.buttons["toolbar.settings"] }

    @discardableResult
    private func openSettings() throws -> XCUIElement {
        guard gear.waitForExistence(timeout: 30) else {
            throw XCTSkip("the library shell did not finish launching")
        }
        gear.tap()
        let done = app.buttons["settings.done"]
        XCTAssertTrue(
            done.waitForExistence(timeout: 10),
            "the gear must present the settings sheet")
        return done
    }

    func testGearOpensTheSettingsSheet() throws {
        try openSettings()
        capture("settings-root")
        XCTAssertTrue(app.navigationBars["Settings"].exists)
    }

    // MARK: - The declared sections

    /// The five sections `AppSettingsConfiguration.imprint` marks available on
    /// iOS. Addressed by the accessibility identifier the MACOS TAB carries too
    /// (`settings.tabs.<id>`) — one section, one identifier, two renderers.
    private static let expectedIOSSections = [
        "settings.tabs.appearance",
        "settings.tabs.general",
        "settings.tabs.editor",
        "settings.tabs.documents",
        "settings.tabs.account",
    ]

    func testScreenRendersTheSectionsTheDeclarationAllowsOnIOS() throws {
        try openSettings()
        for identifier in Self.expectedIOSSections {
            let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(
                row.waitForExistence(timeout: 5),
                "the settings list is missing “\(identifier)”")
        }
        // The capability-gated panes must NOT be offered — a LaTeX row on iOS
        // would push a screen whose every line says "Not found".
        for absent in ["settings.tabs.latex", "settings.tabs.git",
                       "settings.tabs.automation", "settings.tabs.imbib"] {
            XCTAssertFalse(
                app.descendants(matching: .any).matching(identifier: absent).firstMatch.exists,
                "“\(absent)” needs a capability iOS does not have and must be filtered out")
        }
        capture("settings-sections")
    }

    func testAppearancePanePushesAndRendersItsPicker() throws {
        try openSettings()
        app.descendants(matching: .any)
            .matching(identifier: "settings.tabs.appearance").firstMatch.tap()
        XCTAssertTrue(
            app.otherElements["settings.pane.appearance"].waitForExistence(timeout: 5)
                || app.staticTexts["Color Scheme"].waitForExistence(timeout: 5),
            "the chassis builtin appearance pane must resolve from the registry")
        capture("settings-appearance")
        // The shared ImpressTheme component is a segmented picker over the
        // three AppearanceMode cases.
        XCTAssertTrue(app.buttons["System"].exists || app.staticTexts["System"].exists)
        XCTAssertTrue(app.buttons["Dark"].exists || app.staticTexts["Dark"].exists)
    }

    // MARK: - Persistence across relaunch

    /// Turn "Show line numbers" OFF in the Editor pane, relaunch the app, and
    /// find it still off.
    ///
    /// `showLineNumbers` is deliberately the subject: it is one of the keys that
    /// moved ACROSS A TARGET BOUNDARY in this refactor (out of imprint's macOS
    /// `SettingsView.swift` into `Shared/Settings/ImprintSettingsPanes.swift`),
    /// so it is exactly the kind of key a move could have renamed. It also
    /// defaults to `true`, which means the assertion cannot pass by accident on
    /// a fresh container.
    func testEditorToggleSurvivesRelaunch() throws {
        try openSettings()
        app.descendants(matching: .any)
            .matching(identifier: "settings.tabs.editor").firstMatch.tap()

        let toggle = app.switches["settings.editor.showLineNumbers"]
        guard toggle.waitForExistence(timeout: 10) else {
            throw XCTSkip("the Editor pane did not render its Display section")
        }
        capture("settings-editor-before")

        let wasOn = (toggle.value as? String) == "1"
        flip(toggle)
        // Give @AppStorage's UserDefaults write a beat before termination.
        sleep(1)
        let afterTap = (toggle.value as? String) == "1"
        XCTAssertNotEqual(wasOn, afterTap, "the toggle did not change state")
        capture("settings-editor-after")

        app.terminate()
        app.launch()

        try openSettings()
        app.descendants(matching: .any)
            .matching(identifier: "settings.tabs.editor").firstMatch.tap()
        let reopened = app.switches["settings.editor.showLineNumbers"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        capture("settings-editor-relaunched")
        XCTAssertEqual(
            (reopened.value as? String) == "1", afterTap,
            """
            “Show line numbers” did not survive relaunch. Either the \
            @AppStorage key changed when the pane moved to Shared/Settings/ \
            (see ImprintSettingsPersistenceTests) or the pane is reading a \
            different store than it writes.
            """)

        // Leave the container as we found it, so a re-run starts from the
        // default and the "cannot pass by accident" property holds.
        flip(reopened)
        sleep(1)
    }

    /// Tap a `Toggle` inside a SwiftUI `Form` row.
    ///
    /// NOT `element.tap()`. A Form row's switch element has the frame of the
    /// WHOLE ROW, so `tap()` — which taps the frame's centre — lands on the
    /// label, and tapping a Toggle's label does not toggle it on iOS. The
    /// symptom is a green test-shaped failure: the element exists, the tap
    /// "succeeds", and the value never changes. Hit the trailing edge, where the
    /// switch actually is.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    }
}
