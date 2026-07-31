//
//  PaneLayoutCommandsTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0022 D9 finding 4: ⌘0 / ⌥⌘0 / ⌃⌘S were hand-written in four apps over
//  chassis state with a published chassis-wide keyboard grammar
//  (docs/keyboard-grammar.md), and nothing compared the four copies to each
//  other or to the doc. They had already drifted in four cosmetic axes by the
//  time the fourth was written.
//
//  SwiftUI offers no way to enumerate a built `Commands` body, which is exactly
//  why the drift was invisible. `ImpressPaneLayoutButtons.chords()` publishes
//  the same three bindings AS DATA — same titles, same keys, same modifiers,
//  and a closure that performs the same `PaneLayoutState` mutation the button
//  performs — so this suite can check the grammar and the effect without a
//  running scene. The data and the buttons sit ten lines apart in one file; a
//  change to one that skips the other is a diff a reviewer sees.
//
//  The migration half is checked by source scan, in the shape
//  `ImprintSettingsPersistenceTests` established: the four apps must not
//  re-grow a private copy. A `PaneLayoutStore.shared.current.<field>.toggle()`
//  in an app file is the finding, verbatim.
//

import SwiftUI
import XCTest

@testable import PublicationManagerCore

@MainActor
final class PaneLayoutCommandsTests: XCTestCase {

    // MARK: - The published grammar

    /// docs/keyboard-grammar.md is the contract. These three rows are it.
    func testChordsMatchTheKeyboardGrammar() {
        let chords = ImpressPaneLayoutButtons.chords()
        XCTAssertEqual(chords.count, 3)

        XCTAssertEqual(chords[0].title, "Toggle Detail Pane")
        XCTAssertEqual(chords[0].key, "0")
        XCTAssertEqual(chords[0].modifiers, .command)

        XCTAssertEqual(chords[1].title, "Toggle List")
        XCTAssertEqual(chords[1].key, "0")
        XCTAssertEqual(chords[1].modifiers, [.command, .option])

        XCTAssertEqual(chords[2].title, "Toggle Sidebar")
        XCTAssertEqual(chords[2].key, "s")
        XCTAssertEqual(chords[2].modifiers, [.control, .command])
    }

    /// The `listTitle` seam exists for imprint and for nothing else. If a second
    /// caller ever passes it, that is the moment to make the label a decision
    /// instead of a parameter.
    func testOnlyTheListTitleIsHostConfigurable() {
        let imprint = ImpressPaneLayoutButtons.chords(listTitle: "Toggle Manuscript List")
        XCTAssertEqual(imprint[1].title, "Toggle Manuscript List")
        // Everything else is identical to the default set.
        XCTAssertEqual(imprint[0], ImpressPaneLayoutButtons.chords()[0])
        XCTAssertEqual(imprint[2], ImpressPaneLayoutButtons.chords()[2])
        XCTAssertEqual(imprint[1].key, "0")
        XCTAssertEqual(imprint[1].modifiers, [.command, .option])
    }

    /// No two chords may collide — grammar rule 5 ("per-app chords must not
    /// collide with the universal layer") applied to the universal layer's own
    /// three. ⌘0 and ⌥⌘0 share a KEY and differ by modifier, which is the whole
    /// design and the thing a careless edit breaks.
    func testNoTwoTogglesShareAChord() {
        let chords = ImpressPaneLayoutButtons.chords()
        let bindings = chords.map { "\($0.key)-\($0.modifiers.rawValue)" }
        XCTAssertEqual(Set(bindings).count, chords.count)
    }

    // MARK: - What each chord actually does

    /// Each chord flips ITS field and no other. The four hand-written copies
    /// each wired three buttons to three fields by hand; a transposed pair
    /// (⌘0 flipping the list) is a one-character error no compiler catches.
    func testEachChordTogglesExactlyItsOwnField() {
        let chords = ImpressPaneLayoutButtons.chords()

        var state = PaneLayoutState()
        chords[0].toggle(&state)
        XCTAssertFalse(state.detailPaneVisible)
        XCTAssertTrue(state.listPaneVisible)
        XCTAssertTrue(state.sidebarVisible)

        state = PaneLayoutState()
        chords[1].toggle(&state)
        XCTAssertTrue(state.detailPaneVisible)
        XCTAssertFalse(state.listPaneVisible)
        XCTAssertTrue(state.sidebarVisible)

        state = PaneLayoutState()
        chords[2].toggle(&state)
        XCTAssertTrue(state.detailPaneVisible)
        XCTAssertTrue(state.listPaneVisible)
        XCTAssertFalse(state.sidebarVisible)
    }

    /// A toggle is its own inverse. `PaneLayoutState` persists through
    /// `PaneLayoutStore.current`'s `didSet`, so a non-involutive toggle would
    /// leave a saved layout the user cannot get back to.
    func testTogglingTwiceRestoresTheStartingLayout() {
        let start = PaneLayoutState()
        for chord in ImpressPaneLayoutButtons.chords() {
            var state = start
            chord.toggle(&state)
            chord.toggle(&state)
            XCTAssertEqual(state, start, "\(chord.title) is not its own inverse")
        }
    }

    // MARK: - Migration: no app may re-grow a private copy

    /// Every app file that hand-wrote these buttons. All four.
    ///
    /// implore and impel are absent because they never bound the chords at all
    /// — they take `ImpressStoreSearchCommands` and no pane toggles. Adding
    /// them is a product decision (their windows have panes), not a migration.
    private static let migratedAppFiles = [
        "apps/imbib/imbib/imbib/imbibApp.swift",
        "apps/imprint/Shared/ImprintApp.swift",
        "apps/impart/macOS/ImpartApp.swift",
        "apps/impress/macOS/ImpressApp.swift",
    ]

    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)          // …/Tests/PublicationManagerCoreTests/<this>
            .deletingLastPathComponent()          // …/Tests/PublicationManagerCoreTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/PublicationManagerCore
            .deletingLastPathComponent()          // …/imbib
            .deletingLastPathComponent()          // …/apps
            .deletingLastPathComponent()          // repo root
    }()

    private static func source(of relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testMigratedAppsUseTheSharedValueAndNotAPrivateCopy() throws {
        for path in Self.migratedAppFiles {
            let source = try Self.source(of: path)
            XCTAssertTrue(
                source.contains("ImpressPaneLayoutButtons("),
                "\(path) must use the shared pane-layout buttons")
            for field in ["detailPaneVisible", "listPaneVisible", "sidebarVisible"] {
                XCTAssertFalse(
                    source.contains("PaneLayoutStore.shared.current.\(field).toggle()"),
                    """
                    \(path) hand-toggles `\(field)` again. That is D9 finding 4 \
                    verbatim: the chord grammar is the chassis's, and a private \
                    copy of it drifts silently. Use `ImpressPaneLayoutButtons`.
                    """)
            }
        }
    }

    /// The repo root really is seven levels up from this file — assert it, or a
    /// moved test file turns every source scan above into a silent skip.
    func testTheSourceScanFindsTheRepositoryRoot() throws {
        XCTAssertTrue(try Self.source(of: "docs/keyboard-grammar.md").contains("⌃⌘S"))
    }

    /// docs/keyboard-grammar.md must document every chord this value binds.
    /// ⌥⌘0 was missing from the table for four apps' worth of adoption — the
    /// doc's own rule 2 says a universal action goes into the catalog AND the
    /// doc, and nothing enforced the second half.
    func testTheKeyboardGrammarDocumentsAllThreeChords() throws {
        let grammar = try Self.source(of: "docs/keyboard-grammar.md")
        for chord in ["⌃⌘S", "⌥⌘0", "⌘0"] {
            XCTAssertTrue(
                grammar.contains(chord),
                "docs/keyboard-grammar.md must carry a row for \(chord)")
        }
    }
}
