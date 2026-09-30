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
//  the same three bindings AS DATA — same titles, same keys, same modifiers
//  and the tree role each resizes, which `PaneLayoutChordRouter` maps to a
//  host window's pane — so this suite can check the grammar and the effect
//  without a running scene. The data and the buttons sit ten lines apart in one file; a
//  change to one that skips the other is a diff a reviewer sees.
//
//  The migration half is checked by source scan, in the shape
//  `ImprintSettingsPersistenceTests` established: the four apps must not
//  re-grow a private copy. A hand-written `.current.<field>.toggle()` of a
//  pane field in an app file is the finding, verbatim.
//

import SwiftUI
import XCTest
import ImpressKeyboard

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

    /// Imprint supplies its own registry command ids and retains its existing
    /// list title. The seeded entries must exist; universal fallback chords
    /// alone would otherwise hide an omitted imprint registration.
    func testImprintPaneChordsUseItsSeededAppContext() {
        for id in ["imprint.pane.toggle_detail", "imprint.pane.toggle_list", "imprint.pane.toggle_sidebar"] {
            XCTAssertNotNil(KeymapRegistry.shared.entry(for: id), "missing \(id)")
        }
        let imprint = ImpressPaneLayoutButtons.chords(
            listTitle: "Toggle Manuscript List", appID: "imprint")
        XCTAssertEqual(imprint[1].title, "Toggle Manuscript List")
        // The pane roles and keys retain the universal grammar.
        XCTAssertEqual(imprint[0], ImpressPaneLayoutButtons.chords()[0])
        XCTAssertEqual(imprint[2], ImpressPaneLayoutButtons.chords()[2])
        XCTAssertEqual(imprint[1].key, "0")
        XCTAssertEqual(imprint[1].modifiers, [.command, .option])
        XCTAssertEqual(imprint.map(\.role), ["detail", "list", "navigator"])
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

    // MARK: - Where each chord lands (plan wave 6 W5)

    /// In a chassis window a chord resizes a ROLE in the layout tree
    /// (ADR-0031 D5) — the tree is the only chassis root since W5. A
    /// transposed role (⌘0 collapsing the navigator) is the same one-character
    /// error `testEachChordTogglesExactlyItsOwnField` guards on the other side.
    func testEachChordNamesItsTreeRole() {
        let chords = ImpressPaneLayoutButtons.chords()
        XCTAssertEqual(chords.map(\.role), ["detail", "list", "navigator"])
        XCTAssertEqual(chords.map(\.role), [
            PaneLayoutChordRouter.detailRole,
            PaneLayoutChordRouter.listRole,
            PaneLayoutChordRouter.navigatorRole,
        ])
    }

    /// Every app window, imbib included, routes the chords to the layout tree.
    /// `.imbibPreChassisWindow` remains on the router for the pane-model unit
    /// test below; no app target passes it.
    func testNoAppWindowRoutesToItsOwnPanes() throws {
        for path in Self.migratedAppFiles {
            let source = try Self.source(of: path)
            XCTAssertFalse(
                source.contains("target: .imbibPreChassisWindow"),
                "\(path): the window is the layout tree")
        }
    }

    // MARK: - What each chord actually does

    /// Each chord flips ITS pane of a host window and no other. The four
    /// hand-written copies each wired three buttons to three fields by hand; a
    /// transposed pair (⌘0 flipping the list) is a one-character error no
    /// compiler catches.
    func testEachChordTogglesExactlyItsOwnPane() {
        let chords = ImpressPaneLayoutButtons.chords()

        var panes = OwnWindowPanes()
        PaneLayoutChordRouter.toggle(role: chords[0].role, target: .imbibPreChassisWindow(panes))
        XCTAssertFalse(panes.detailPaneVisible)
        XCTAssertTrue(panes.listPaneVisible)
        XCTAssertTrue(panes.sidebarVisible)

        panes = OwnWindowPanes()
        PaneLayoutChordRouter.toggle(role: chords[1].role, target: .imbibPreChassisWindow(panes))
        XCTAssertTrue(panes.detailPaneVisible)
        XCTAssertFalse(panes.listPaneVisible)
        XCTAssertTrue(panes.sidebarVisible)

        panes = OwnWindowPanes()
        PaneLayoutChordRouter.toggle(role: chords[2].role, target: .imbibPreChassisWindow(panes))
        XCTAssertTrue(panes.detailPaneVisible)
        XCTAssertTrue(panes.listPaneVisible)
        XCTAssertFalse(panes.sidebarVisible)
    }

    /// A toggle is its own inverse: imbib's window persists every change, so a
    /// non-involutive toggle would leave a saved layout the user cannot get
    /// back to.
    func testTogglingTwiceRestoresTheStartingPanes() {
        for chord in ImpressPaneLayoutButtons.chords() {
            let panes = OwnWindowPanes()
            PaneLayoutChordRouter.toggle(role: chord.role, in: panes)
            PaneLayoutChordRouter.toggle(role: chord.role, in: panes)
            XCTAssertTrue(
                panes.detailPaneVisible && panes.listPaneVisible && panes.sidebarVisible,
                "\(chord.title) is not its own inverse")
        }
    }

    // MARK: - Migration: no app may re-grow a private copy

    /// Every app that binds these buttons: the four that once hand-wrote
    /// them, plus impel and implore.
    ///
    /// impel and implore were absent until 2026-09-24 — they never bound the
    /// chords at all, and this comment called adding them a product decision
    /// (their windows have panes). Tom made it: the grammar is "same chord,
    /// same meaning, in every app", and both windows are the layout tree, so
    /// they mount the same chassis buttons and route only through
    /// `LayoutController`. They never had a private copy to migrate, so the
    /// no-private-copy scan below simply holds for them too.
    private static let migratedAppFiles = [
        "apps/imbib/imbib/imbib/imbibApp.swift",
        "apps/imprint/Shared/ImprintApp.swift",
        "apps/impart/macOS/ImpartApp.swift",
        "apps/impress/macOS/ImpressApp.swift",
        "apps/impel/Shared/ImpelApp.swift",
        "apps/implore/Implore/Sources/App/ImploreApp.swift",
    ]

    /// Where each app mounts ⌃⌘1–9 (`ImpressLayoutOrdinalButtons`).
    /// imprint's sits in its Layouts menu; imbib's is View ▸ Layouts with
    /// its app id; everyone else's is in the app file. impart mounted the
    /// pane toggles and not these until 2026-09-24. imbib joined when its
    /// window became a chassis root.
    private static let ordinalButtonFiles = [
        "apps/imprint/Shared/Layout/PaneLayout.swift",
        "apps/imbib/imbib/imbib/imbibApp.swift",
        "apps/impart/macOS/ImpartApp.swift",
        "apps/impress/macOS/ImpressApp.swift",
        "apps/impel/Shared/ImpelApp.swift",
        "apps/implore/Implore/Sources/App/ImploreApp.swift",
    ]

    func testEveryChassisAppMountsTheLayoutOrdinals() throws {
        for path in Self.ordinalButtonFiles {
            let expected: String
            if path == "apps/imprint/Shared/Layout/PaneLayout.swift" {
                expected = "ImpressLayoutOrdinalButtons(appID: \"imprint\")"
            } else if path == "apps/imbib/imbib/imbib/imbibApp.swift" {
                expected = "ImpressLayoutOrdinalButtons(appID: \"imbib\")"
            } else {
                expected = "ImpressLayoutOrdinalButtons()"
            }
            XCTAssertTrue(
                try Self.source(of: path).contains(expected),
                "\(path) must mount the chassis's ⌃⌘1–9 (ImpressLayoutOrdinalButtons)")
        }
    }

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
                    source.contains(".current.\(field).toggle()"),
                    """
                    \(path) hand-toggles `\(field)` again. That is D9 finding 4 \
                    verbatim: the chord grammar is the chassis's, and a private \
                    copy of it drifts silently. Use `ImpressPaneLayoutButtons`.
                    """)
            }
        }
    }

    /// The window toolbar's top-left group holds the LIST toggle, and the
    /// manuscript editor's pane toggles join it (`TabContentView`). The group
    /// sits over the sidebar column; when it gets wider than a narrow sidebar
    /// leaves, macOS moves it — list toggle included — into the overflow
    /// chevron. That is what happened when a Papers ACTION button was added to
    /// `ManuscriptEditorPaneToggles` (2026-09-12): a hidden manuscript list lost
    /// its visible way back. The cluster is for pane toggles; actions go in the
    /// editor's own footer.
    func testTheEditorPaneClusterHoldsTogglesOnly() throws {
        let source = try Self.source(
            of: "apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/"
                + "Manuscript/Editor/ManuscriptSourceTab.swift")
        guard let start = source.range(of: "public struct ManuscriptEditorPaneToggles"),
              let bodyStart = source.range(of: "public var body: some View {", range: start.upperBound..<source.endIndex),
              let end = source.range(of: "\n}\n", range: bodyStart.upperBound..<source.endIndex)
        else { return XCTFail("ManuscriptEditorPaneToggles moved; update this guard") }
        let body = String(source[bodyStart.upperBound..<end.lowerBound])
        XCTAssertFalse(
            body.contains("Button {") || body.contains("Button("),
            "an action button in the pane-toggle cluster widens the list toggle's toolbar group")
        XCTAssertTrue(body.contains("Toggle(isOn:"), "the cluster should still hold the pane toggles")
    }

    // MARK: - imbib's menu: no two commands share a chord

    /// Every chord imbib's menu bar registers, and none twice. Paper ▸ Save to
    /// Library carried ⌃⌘S from January 2026 (cdca0b23) — the Toggle Sidebar
    /// chord — and a key equivalent that two menu items claim does NEITHER
    /// reliably, so ⌃⌘S stopped toggling the sidebar in imbib's own window and
    /// nothing noticed, because each binding looked right on its own.
    ///
    /// Source scan of `imbibApp.swift` (SwiftUI cannot enumerate a built
    /// `Commands` body), plus the three chords `ImpressPaneLayoutButtons`
    /// contributes as data, plus View ▸ Layouts' ⌃⌘1–9.
    ///
    /// R2b (2026-09) moved most of these sites off literals: they now read
    /// `KeymapRegistry.shared.shortcut(for: "imbib.…")` instead of writing
    /// `.keyboardShortcut("k", modifiers: …)`. Both forms are scanned here —
    /// a literal survivor (the dev-mode export, Quit, and the dynamic
    /// per-index Layouts loop, none seeded into the registry) resolves
    /// directly; a registry call resolves through `KeymapRegistry.shared` so
    /// this test still checks the CHORD each site is actually bound to, not
    /// the id string, and would still fail on a real collision.
    func testNoTwoImbibMenuCommandsShareAChord() throws {
        let source = try Self.source(of: "apps/imbib/imbib/imbib/imbibApp.swift")
        var seen: [String: Int] = [:]
        var chords: [String] = []

        // `.keyboardShortcut("k")`, `.keyboardShortcut("k", modifiers: X)`,
        // `.keyboardShortcut(.return, modifiers: X)`.
        let literalPattern = #"\.keyboardShortcut\((?:"([^"]+)"|\.([a-zA-Z]+))(?:,\s*modifiers:\s*(\[[^\]]*\]|\.[a-z]+))?\)"#
        let literalRegex = try NSRegularExpression(pattern: literalPattern)
        let ns = source as NSString
        for match in literalRegex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let key: String = {
                for group in [1, 2] where match.range(at: group).location != NSNotFound {
                    return ns.substring(with: match.range(at: group)).lowercased()
                }
                return "?"
            }()
            let modifierText = match.range(at: 3).location == NSNotFound
                ? ".command"  // SwiftUI's default
                : ns.substring(with: match.range(at: 3))
            chords.append(Self.chord(key: key, modifierText: modifierText))
        }

        // `.keyboardShortcut(KeymapRegistry.shared.shortcut(for: "imbib.…"))`
        let registryPattern = #"KeymapRegistry\.shared\.shortcut\(for:\s*"([^"]+)"\)"#
        let registryRegex = try NSRegularExpression(pattern: registryPattern)
        var registryCommandIDs: [String] = []
        for match in registryRegex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let commandID = ns.substring(with: match.range(at: 1))
            registryCommandIDs.append(commandID)
            guard let shortcut = KeymapRegistry.shared.shortcut(for: commandID) else {
                continue  // chordless, e.g. Save to Library — nothing to collide
            }
            chords.append(Self.chord(shortcut: shortcut))
        }
        XCTAssertGreaterThan(registryCommandIDs.count, 40, "the scan stopped matching imbibApp.swift's registry lookups")
        XCTAssertGreaterThan(chords.count, 40, "the scan stopped matching imbibApp.swift's shortcuts")

        for chord in ImpressPaneLayoutButtons.chords() {
            var names: [String] = []
            if chord.modifiers.contains(.control) { names.append("control") }
            if chord.modifiers.contains(.option) { names.append("option") }
            if chord.modifiers.contains(.shift) { names.append("shift") }
            if chord.modifiers.contains(.command) { names.append("command") }
            chords.append("\(names.joined(separator: "+"))-\(chord.key)")
        }
        XCTAssertTrue(
            source.contains("KeyEquivalent(Character(\"\\(index + 1)\")), modifiers: [.command, .control]"),
            "View ▸ Layouts' ⌃⌘1–9 moved; update this scan")
        chords += (1...9).map { "control+command-\($0)" }

        for chord in chords { seen[chord, default: 0] += 1 }
        let shared = seen.filter { $0.value > 1 }.keys.sorted()
        XCTAssertEqual(shared, [], "imbib's menu registers these chords more than once: \(shared)")
    }

    /// `[.command, .shift]` and `[.shift, .command]` are one chord.
    private static func chord(key: String, modifierText: String) -> String {
        let names = ["control", "option", "shift", "command"].filter {
            modifierText.contains(".\($0)")
        }
        return "\(names.joined(separator: "+"))-\(key)"
    }

    /// Same descriptor, from a resolved `KeyboardShortcut` (the registry
    /// path) rather than a parsed literal.
    private static func chord(shortcut: KeyboardShortcut) -> String {
        var names: [String] = []
        if shortcut.modifiers.contains(.control) { names.append("control") }
        if shortcut.modifiers.contains(.option) { names.append("option") }
        if shortcut.modifiers.contains(.shift) { names.append("shift") }
        if shortcut.modifiers.contains(.command) { names.append("command") }
        return "\(names.joined(separator: "+"))-\(String(shortcut.key.character).lowercased())"
        // (KeyEquivalent.character is a Character; String(_:) here is the same
        // widen-then-lowercase idiom `Chord.key` values use elsewhere.)
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
