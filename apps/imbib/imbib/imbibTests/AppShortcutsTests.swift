//
//  AppShortcutsTests.swift
//  imbib's App Shortcuts provider, which lives in the app target: App Intents
//  metadata extraction reads an AppShortcutsProvider only from the app's own
//  sources (in PublicationManagerCore it registered no shortcut for any app).
//

import AppIntents
import XCTest
@testable import imbib

final class AppShortcutsTests: XCTestCase {
    func testImbibShortcuts_hasShortcuts() {
        let shortcuts = ImbibShortcuts.appShortcuts
        XCTAssertFalse(shortcuts.isEmpty, "Should have at least one shortcut")
    }
}
