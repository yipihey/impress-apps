import XCTest
@testable import ImpressKeyboard

// MARK: - Triage Key Grammar

final class TriageKeyGrammarTests: XCTestCase {

    func testEveryCommandHasExactlyOneCharacterBinding() {
        // A command with no key is unreachable; a command with two keys is a
        // silent conflict. Both are the class of bug this catalog exists to kill.
        for command in TriageCommand.allCases {
            let keys = TriageKeyGrammar.characterBindings
                .filter { $0.value == command }
                .map(\.key)
            XCTAssertEqual(keys.count, 1, "\(command.rawValue) has \(keys.count) keys: \(keys)")
        }
        XCTAssertEqual(
            TriageKeyGrammar.characterBindings.count,
            TriageCommand.allCases.count,
            "characterBindings and TriageCommand must stay in bijection"
        )
    }

    func testCanonicalKeyAssignments() {
        XCTAssertEqual(TriageKeyGrammar.command(forCharacters: "j"), .navigateDown)
        XCTAssertEqual(TriageKeyGrammar.command(forCharacters: "k"), .navigateUp)
        XCTAssertEqual(TriageKeyGrammar.command(forCharacters: "n"), .create)
        XCTAssertEqual(TriageKeyGrammar.command(forCharacters: "s"), .toggleStar)
        XCTAssertEqual(TriageKeyGrammar.command(forCharacters: "d"), .dismissOrRestore)
        XCTAssertEqual(TriageKeyGrammar.command(forCharacters: "o"), .open)
        XCTAssertEqual(TriageKeyGrammar.command(forCharacters: "/"), .focusFilter)
    }

    /// Stage 1b: pane focus joins the catalog. `h`/`l` were hand-hardcoded in
    /// imbib's DetailView and in impart/impel's window key handlers — the one
    /// binding that appeared in no catalog and no shortcuts-help list.
    func testPaneFocusIsInTheCatalog() {
        XCTAssertEqual(TriageKeyGrammar.command(forCharacters: "h"), .focusPaneLeft)
        XCTAssertEqual(TriageKeyGrammar.command(forCharacters: "l"), .focusPaneRight)
    }

    func testUnknownAndMultiCharacterInputIsIgnored() {
        XCTAssertNil(TriageKeyGrammar.command(forCharacters: "z"))
        XCTAssertNil(TriageKeyGrammar.command(forCharacters: ""))
        XCTAssertNil(TriageKeyGrammar.command(forCharacters: "jk"))
    }

    /// The single-key layer must agree with the settings catalog: `h`/`l`
    /// resolve to the same pane-cycling actions the settings UI advertises.
    func testGrammarAgreesWithSharedShortcutCatalog() {
        let byKey = Dictionary(
            uniqueKeysWithValues: ShortcutCatalog.shared
                .filter { $0.modifiers == .none }
                .compactMap { binding -> (String, String)? in
                    guard case .character(let c) = binding.key else { return nil }
                    return (c, binding.id)
                }
                .filter { ["h", "l"].contains($0.0) }
        )
        XCTAssertEqual(byKey["h"], "cycleFocusLeft")
        XCTAssertEqual(byKey["l"], "cycleFocusRight")
    }
}

// MARK: - Shared Shortcut Catalog

final class ShortcutCatalogTests: XCTestCase {

    func testSharedIDsAreUnique() {
        let ids = ShortcutCatalog.shared.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate shared catalog id")
    }

    func testNotificationDefaultsToID() {
        // The convention the suite already follows; only deliberate exceptions
        // (the flag/tag "enter…" notifications, the Vim unread aliases) differ.
        let exceptions: Set<String> = [
            "flagMode", "tagMode", "tagDeleteMode", "filterMode",
            "navigateNextUnreadVim", "navigatePreviousUnreadVim",
        ]
        for entry in ShortcutCatalog.shared where !exceptions.contains(entry.id) {
            XCTAssertEqual(entry.notificationName, entry.id, "\(entry.id)")
        }
    }

    func testResolveAdoptsEntryVerbatim() {
        let resolved = ShortcutCatalog.resolve([.shared("navigateDown")])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].id, "navigateDown")
        XCTAssertEqual(resolved[0].key, .character("j"))
        XCTAssertEqual(resolved[0].displayName, "Down (Vim)")
        XCTAssertEqual(resolved[0].notificationName, "navigateDown")
    }

    func testResolveRefinesIDLabelAndNotification() {
        let resolved = ShortcutCatalog.resolve([
            .shared("navigateNextItem", as: "navigateNextPaper", displayName: "Next Paper")
        ])
        XCTAssertEqual(resolved[0].id, "navigateNextPaper")
        XCTAssertEqual(resolved[0].displayName, "Next Paper")
        // Renaming the id renames the notification with it, unless overridden.
        XCTAssertEqual(resolved[0].notificationName, "navigateNextPaper")
        // Key and modifiers still come from the shared catalog — the whole point.
        XCTAssertEqual(resolved[0].key, .special(.downArrow))
        XCTAssertEqual(resolved[0].modifiers, .none)
    }

    func testResolveHonoursExplicitNotificationOverride() {
        let resolved = ShortcutCatalog.resolve([
            .shared("navigateDown", notificationName: "navigateNextPaper")
        ])
        XCTAssertEqual(resolved[0].id, "navigateDown")
        XCTAssertEqual(resolved[0].notificationName, "navigateNextPaper")
    }

    func testResolvePreservesProfileOrderAndOwnEntries() {
        let own = KeyboardShortcutBinding(
            id: "importBibTeX",
            displayName: "Import BibTeX",
            category: .fileOperations,
            key: .character("i"),
            modifiers: .command,
            notificationName: "importBibTeX"
        )
        let resolved = ShortcutCatalog.resolve([
            .shared("navigateUp"),
            .own(own),
            .shared("navigateDown"),
        ])
        XCTAssertEqual(resolved.map(\.id), ["navigateUp", "importBibTeX", "navigateDown"])
    }

    func testSharedEntryLookup() {
        XCTAssertEqual(ShortcutCatalog.sharedEntry("toggleSidebar")?.modifiers,
                       [.control, .command])
        XCTAssertNil(ShortcutCatalog.sharedEntry("noSuchEntry"))
    }

    func testDisplayShortcutFormatting() {
        XCTAssertEqual(ShortcutCatalog.sharedEntry("toggleSidebar")?.displayShortcut, "⌃⌘s")
        XCTAssertEqual(ShortcutCatalog.sharedEntry("triageSaveAndStar")?.displayShortcut, "Shift+s")
        XCTAssertEqual(ShortcutCatalog.sharedEntry("navigateFirstItem")?.displayShortcut, "⌘↑")
        XCTAssertEqual(ShortcutCatalog.sharedEntry("triageSave")?.displayShortcut, "*")
    }
}
