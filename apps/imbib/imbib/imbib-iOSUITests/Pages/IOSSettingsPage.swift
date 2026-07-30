//
//  IOSSettingsPage.swift
//  imbib-iOSUITests
//
//  Page object for the IOSSettingsView sheet.
//

import XCTest

struct IOSSettingsPage {

    let app: XCUIApplication

    /// The "API Keys" row (carries the `settings.tabs.sources` id) — a stable
    /// marker that the settings sheet rendered.
    var sourcesRow: XCUIElement {
        app.descendants(matching: .any)[IOSA11y.Settings.sourcesTab].firstMatch
    }

    var doneButton: XCUIElement {
        app.buttons[IOSA11y.Settings.doneButton].firstMatch
    }

    @discardableResult
    func waitForSheet(timeout: TimeInterval = 10) -> Bool {
        sourcesRow.waitForExistence(timeout: timeout)
    }

    func dismiss() {
        if doneButton.exists {
            doneButton.tap()
        }
    }

    // MARK: - Declarative sections (Stage 6 phase 2)

    /// A settings row addressed by its chassis identifier, `settings.tabs.<id>`.
    ///
    /// The same string the macOS tab carries — to a test an iOS row and a macOS
    /// tab are the same section, which is the property that lets one preset be
    /// asserted from either platform.
    func row(_ sectionID: String) -> XCUIElement {
        app.descendants(matching: .any)["settings.tabs.\(sectionID)"].firstMatch
    }

    /// The pushed pane for a section, addressed by `settings.pane.<id>`.
    func pane(_ sectionID: String) -> XCUIElement {
        app.descendants(matching: .any)["settings.pane.\(sectionID)"].firstMatch
    }

    /// Scroll the settings list until `element` is present AND hittable.
    ///
    /// Necessary rather than fussy: a SwiftUI `List` is LAZY, so a row far down a
    /// long screen is not in the accessibility tree at all until it scrolls near
    /// the viewport — `exists` is false, not merely off-screen. And an element that
    /// exists but is not `hittable` swallows `tap()` silently, which is how a
    /// toggle test can "pass" the tap and then read an unchanged value. imbib's iOS
    /// settings screen is 19 rows tall and its Notes pane puts the modal-editing
    /// toggle below three other sections, so both cases are live here.
    @discardableResult
    func scrollUntilVisible(_ element: XCUIElement, maxSwipes: Int = 10) -> Bool {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    /// Every `settings.tabs.<id>` row the screen renders, collected in ONE pass
    /// from top to bottom.
    ///
    /// One pass, rather than `scrollUntilVisible` per section, because a lazy
    /// `List` only builds rows near the viewport: searching for six sections
    /// independently means scrolling the full screen up to six times, and a row
    /// already passed is gone from the tree by the time the next search starts. The
    /// per-section version burned ~60 swipes and got the test killed on time.
    /// Sweeping once and recording what appears is both faster and a stronger
    /// assertion — it yields the WHOLE rendered inventory, which is what should be
    /// compared against the declaration.
    func renderedSectionIDs(maxSwipes: Int = 14) -> Set<String> {
        let prefix = "settings.tabs."
        var found: Set<String> = []

        // `.cell` and `.button`, NOT `.any`: a settings row is a List cell (with a
        // button inside), and `descendants(matching: .any)` walks EVERY node in the
        // hierarchy on every collect — with ~19 rows swept over a dozen swipes that
        // is slow enough to blow the test's time budget and get the whole case
        // killed by the watchdog, which reports as "crashed with signal kill"
        // rather than as a timeout. Two typed queries are bounded and fast.
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        func collect() {
            for type in [XCUIElement.ElementType.cell, .button] {
                for element in app.descendants(matching: type)
                    .matching(predicate).allElementsBoundByIndex {
                    let identifier = element.identifier
                    if identifier.hasPrefix(prefix) {
                        found.insert(String(identifier.dropFirst(prefix.count)))
                    }
                }
            }
        }

        collect()
        for _ in 0..<maxSwipes {
            let before = found.count
            app.swipeUp()
            collect()
            // Two consecutive swipes that reveal nothing new ⇒ at the bottom.
            if found.count == before, !found.isEmpty {
                app.swipeUp()
                collect()
                if found.count == before { break }
            }
        }
        return found
    }

    /// Tap a section row and wait for its pane to push.
    @discardableResult
    func openSection(_ sectionID: String, timeout: TimeInterval = 10) -> Bool {
        let row = row(sectionID)
        guard scrollUntilVisible(row) else { return false }
        row.tap()
        return pane(sectionID).waitForExistence(timeout: timeout)
    }

    /// Tap a switch and wait for its reported value to actually change.
    ///
    /// Returns the new value, or nil if it never changed — which is a real
    /// failure, not a flake: it means the tap did not land or the binding is not
    /// wired to a store.
    /// Tapped by COORDINATE, at the trailing edge, not by `element.tap()`.
    ///
    /// `app.switches["<label>"]` in a SwiftUI `Form` resolves to the whole ROW —
    /// label and control together — and its centre is over the text. Tapping there
    /// is a no-op for a `Toggle`: the tap is delivered, nothing throws, and the
    /// value comes back unchanged, which reads exactly like "the preference is not
    /// wired to a store". The switch itself lives at the trailing edge, so that is
    /// where the tap has to land.
    func toggleAndAwaitChange(
        _ element: XCUIElement, timeout: TimeInterval = 5
    ) -> String? {
        guard scrollUntilVisible(element) else { return nil }
        let before = element.value as? String
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let now = element.value as? String, now != before { return now }
            usleep(150_000)
        }
        return nil
    }

    /// Walk back to the settings root from a pushed pane.
    func popToRoot() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
    }

    /// The "Helix-style modal editing" toggle in the Notes pane — an
    /// `@AppStorage("helixModeEnabled")` control, i.e. one whose value must
    /// survive a terminate + launch.
    var helixModeToggle: XCUIElement {
        app.switches["Helix-style modal editing"].firstMatch
    }
}
