//
//  KeymapRegistryTests.swift
//  ImpressKeyboardTests
//
//  R2b: pins every one of the 66 imbib chords seeded in `impress-keymap`
//  against the literal each menu site declares (`imbibApp.swift`,
//  `PaneLayoutCommands.swift`, `DetachedViews.swift`) — transcribed here,
//  not read from the live SwiftUI tree (a `Commands` body isn't
//  introspectable). Once a site is switched to
//  `KeymapRegistry.shared.shortcut(for:)`, this is what would catch a
//  divergence: a registry edit that changes a chord with no matching menu
//  edit, or vice versa.
//

import XCTest
import SwiftUI
@testable import ImpressKeyboard

final class KeymapRegistryTests: XCTestCase {

    /// One seeded command id and the chord its menu site declares today,
    /// exactly as `crates/impress-keymap/src/imbib.rs` records it. `nil`
    /// modifiers/key means chordless (Save to Library).
    private struct Expected {
        let id: String
        let key: KeyEquivalent?
        let modifiers: EventModifiers
    }

    private static let expected: [Expected] = [
        Expected(id: "imbib.pane.toggle_detail", key: "0", modifiers: .command),
        Expected(id: "imbib.pane.toggle_list", key: "0", modifiers: [.command, .option]),
        Expected(id: "imbib.pane.toggle_sidebar", key: "s", modifiers: [.control, .command]),
        Expected(id: "imbib.layout.apply_1", key: "1", modifiers: [.control, .command]),
        Expected(id: "imbib.file.import", key: "i", modifiers: .command),
        Expected(id: "imbib.file.export", key: "e", modifiers: [.command, .shift]),
        Expected(id: "imbib.edit.copy", key: "c", modifiers: .command),
        Expected(id: "imbib.edit.copy_as_citation", key: "c", modifiers: [.command, .shift]),
        Expected(id: "imbib.edit.copy_identifier", key: "c", modifiers: [.command, .option]),
        Expected(id: "imbib.edit.cut", key: "x", modifiers: .command),
        Expected(id: "imbib.edit.paste", key: "v", modifiers: .command),
        Expected(id: "imbib.edit.select_all", key: "a", modifiers: .command),
        Expected(id: "imbib.edit.smart_search", key: "s", modifiers: .command),
        Expected(id: "imbib.edit.undo_history", key: "z", modifiers: [.command, .option]),
        Expected(id: "imbib.view.command_palette", key: "p", modifiers: [.command, .shift]),
        Expected(id: "imbib.view.show_library", key: "1", modifiers: .command),
        Expected(id: "imbib.view.show_search", key: "2", modifiers: .command),
        Expected(id: "imbib.view.show_inbox", key: "3", modifiers: .command),
        Expected(id: "imbib.view.show_pdf_tab", key: "4", modifiers: .command),
        Expected(id: "imbib.view.show_notes_tab", key: "5", modifiers: .command),
        Expected(id: "imbib.view.show_bibtex_tab", key: "6", modifiers: .command),
        Expected(id: "imbib.view.detach_pdf", key: "p", modifiers: [.control, .command]),
        Expected(id: "imbib.view.all_dark_light", key: "d", modifiers: [.control, .command]),
        Expected(id: "imbib.view.focus_sidebar", key: "1", modifiers: [.command, .option]),
        Expected(id: "imbib.view.focus_list", key: "2", modifiers: [.command, .option]),
        Expected(id: "imbib.view.focus_detail", key: "3", modifiers: [.command, .option]),
        Expected(id: "imbib.view.show_console", key: "c", modifiers: [.control, .command]),
        Expected(id: "imbib.view.increase_text_size", key: "=", modifiers: [.command, .shift]),
        Expected(id: "imbib.view.decrease_text_size", key: "-", modifiers: [.command, .shift]),
        Expected(id: "imbib.paper.open_pdf", key: .return, modifiers: []),
        Expected(id: "imbib.paper.open_notes", key: "r", modifiers: .command),
        Expected(id: "imbib.paper.open_references", key: "r", modifiers: [.command, .shift]),
        Expected(id: "imbib.paper.toggle_read", key: "u", modifiers: [.command, .shift]),
        Expected(id: "imbib.paper.mark_all_read", key: "u", modifiers: [.command, .option]),
        Expected(id: "imbib.paper.save_to_library", key: nil, modifiers: []),
        Expected(id: "imbib.paper.dismiss_from_inbox", key: "j", modifiers: [.command, .shift]),
        Expected(id: "imbib.paper.move_to_collection", key: "m", modifiers: [.control, .command]),
        Expected(id: "imbib.paper.add_to_collection", key: "l", modifiers: .command),
        Expected(id: "imbib.paper.remove_from_collection", key: "l", modifiers: [.command, .shift]),
        Expected(id: "imbib.paper.share", key: "f", modifiers: [.command, .shift]),
        Expected(id: "imbib.paper.mirror_to_remarkable", key: "e", modifiers: [.control, .command]),
        Expected(id: "imbib.paper.delete", key: .delete, modifiers: .command),
        Expected(id: "imbib.annotate.highlight", key: "h", modifiers: .control),
        Expected(id: "imbib.annotate.underline", key: "u", modifiers: .control),
        Expected(id: "imbib.annotate.strikethrough", key: "t", modifiers: .control),
        Expected(id: "imbib.annotate.add_note", key: "n", modifiers: .control),
        Expected(id: "imbib.go.back", key: "[", modifiers: .command),
        Expected(id: "imbib.go.forward", key: "]", modifiers: .command),
        Expected(id: "imbib.go.first_paper", key: .upArrow, modifiers: .command),
        Expected(id: "imbib.go.last_paper", key: .downArrow, modifiers: .command),
        Expected(id: "imbib.go.next_unread", key: .downArrow, modifiers: .option),
        Expected(id: "imbib.go.previous_unread", key: .upArrow, modifiers: .option),
        Expected(id: "imbib.go.to_page", key: "g", modifiers: .command),
        Expected(id: "imbib.window.refresh", key: "n", modifiers: [.command, .shift]),
        Expected(id: "imbib.window.toggle_unread_filter", key: "\\", modifiers: .command),
        Expected(id: "imbib.window.toggle_pdf_filter", key: "\\", modifiers: [.command, .shift]),
        Expected(id: "imbib.window.open_pdf_fullscreen", key: "p", modifiers: .shift),
        Expected(id: "imbib.window.open_notes_fullscreen", key: "n", modifiers: .shift),
        Expected(id: "imbib.window.open_info_fullscreen", key: "i", modifiers: .shift),
        Expected(id: "imbib.window.open_bibtex_fullscreen", key: "b", modifiers: .shift),
        Expected(id: "imbib.window.flip_positions", key: "f", modifiers: .shift),
        Expected(id: "imbib.window.close_detached", key: "w", modifiers: [.command, .shift, .option]),
        Expected(id: "imbib.help.open", key: "?", modifiers: .command),
        Expected(id: "imbib.help.search", key: "?", modifiers: [.command, .shift]),
        Expected(id: "imbib.help.keyboard_shortcuts", key: "/", modifiers: .command),
        Expected(id: "imbib.detached.save", key: "s", modifiers: .command),
    ]

    func testEverySeededCommandMatchesItsMenuLiteral() {
        let registry = KeymapRegistry.shared
        XCTAssertFalse(registry.entries.isEmpty, "registry decoded no bindings — is keymapJson() reachable?")

        for expectation in Self.expected {
            guard let entry = registry.entry(for: expectation.id) else {
                XCTFail("registry has no entry for \(expectation.id)")
                continue
            }
            XCTAssertEqual(entry.chordless, expectation.key == nil, "chordless mismatch for \(expectation.id)")

            let shortcut = registry.shortcut(for: expectation.id)
            if let expectedKey = expectation.key {
                guard let shortcut else {
                    XCTFail("registry produced no shortcut for \(expectation.id)")
                    continue
                }
                XCTAssertEqual(shortcut.key, expectedKey, "key mismatch for \(expectation.id)")
                XCTAssertEqual(shortcut.modifiers, expectation.modifiers, "modifiers mismatch for \(expectation.id)")
            } else {
                XCTAssertNil(shortcut, "\(expectation.id) should be chordless")
            }
        }

        // Every imbib command entry is accounted for above; imprint has its
        // own context and assertions below.
        let seededCommandIDs = Set(registry.entries(forApp: "imbib")
            .filter { $0.target.kind == "command" }.map(\.target.id))
        let expectedIDs = Set(Self.expected.map(\.id))
        XCTAssertEqual(seededCommandIDs, expectedIDs, "registry command ids and this test's table have diverged")
    }

    func testImprintSeededMenuAndWindowChords() {
        let registry = KeymapRegistry.shared
        let expected: [(String, KeyEquivalent, EventModifiers)] = [
            ("imprint.pane.toggle_detail", "0", .command),
            ("imprint.pane.toggle_list", "0", [.option, .command]),
            ("imprint.pane.toggle_sidebar", "s", [.control, .command]),
            ("imprint.edit.find_in_list", "f", .command),
            ("imprint.edit.build_manuscript", "b", [.option, .command]),
            ("imprint.view.cycle_edit_mode", .tab, .command),
        ]
        for (id, key, modifiers) in expected {
            guard let entry = registry.entry(for: id), let shortcut = registry.shortcut(for: id) else {
                XCTFail("missing seeded imprint command \(id)")
                continue
            }
            XCTAssertEqual(entry.scope, "window:imprint", "wrong scope for \(id)")
            XCTAssertEqual(shortcut.key, key, "wrong key for \(id)")
            XCTAssertEqual(shortcut.modifiers, modifiers, "wrong modifiers for \(id)")
        }

        for ordinal in 1...9 {
            for context in ["chassis", "editor"] {
                let id = "imprint.layout.\(context)_\(ordinal)"
                guard let entry = registry.entry(for: id), let shortcut = registry.shortcut(for: id) else {
                    XCTFail("missing seeded imprint ordinal \(id)")
                    continue
                }
                XCTAssertEqual(entry.scope, "window:imprint.\(context)")
                XCTAssertEqual(shortcut.key, KeyEquivalent(Character(String(ordinal))))
                XCTAssertEqual(shortcut.modifiers, [.control, .command])
            }
        }
        XCTAssertEqual(registry.entries(forApp: "imprint").count, 60)
    }

    func testEntriesForAppUseAnExactScopeBoundary() {
        let json = """
        {"wire_version":1,"bindings":[
          {"chord":"⌘F","scope":"window:imprint","target":{"kind":"command","id":"a"},"label":"A","section":"A","chordless":false},
          {"chord":"⌃⌘1","scope":"window:imprint.editor","target":{"kind":"command","id":"b"},"label":"B","section":"B","chordless":false},
          {"chord":"⌘G","scope":"pane:imprint.search","target":{"kind":"command","id":"c"},"label":"C","section":"C","chordless":false},
          {"chord":"⌘H","scope":"window:imprint2","target":{"kind":"command","id":"d"},"label":"D","section":"D","chordless":false},
          {"chord":"⌘J","scope":"global","target":{"kind":"command","id":"e"},"label":"E","section":"E","chordless":false}
        ]}
        """
        let registry = KeymapRegistry(json: json)
        XCTAssertEqual(registry.entries(forApp: "imprint").map(\.target.id), ["a", "b", "c"])
        XCTAssertEqual(registry.entries(forApp: "imprint2").map(\.target.id), ["d"])
        XCTAssertTrue(registry.entries(forApp: "").isEmpty)
    }

    func testParseRoundTripsSpecialGlyphs() {
        XCTAssertEqual(KeymapRegistry.parse("\u{23ce}")?.key, .return)
        XCTAssertEqual(KeymapRegistry.parse("\u{232b}")?.key, .delete)
        XCTAssertEqual(KeymapRegistry.parse("\u{2191}")?.key, .upArrow)
        XCTAssertEqual(KeymapRegistry.parse("\u{2193}")?.key, .downArrow)
        XCTAssertEqual(KeymapRegistry.parse("\u{2318}\u{21e5}")?.key, .tab)
        XCTAssertEqual(KeymapRegistry.parse("\u{2318}\u{21e5}")?.modifiers, .command)
        XCTAssertEqual(KeymapRegistry.parse("")?.key, nil)
    }

    func testParseHandlesEveryModifierGlyphInOrder() {
        let shortcut = KeymapRegistry.parse("\u{2303}\u{2325}\u{21e7}\u{2318}F")
        XCTAssertEqual(shortcut?.key, "f")
        XCTAssertEqual(shortcut?.modifiers, [.control, .option, .shift, .command])
    }

    func testUnknownCommandIDHasNoShortcut() {
        XCTAssertNil(KeymapRegistry.shared.shortcut(for: "imbib.not.a.real.command"))
    }
}
