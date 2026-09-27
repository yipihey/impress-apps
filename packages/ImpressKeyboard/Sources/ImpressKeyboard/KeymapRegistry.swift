//
//  KeymapRegistry.swift
//  ImpressKeyboard
//
//  R2b: the Swift half of the keymap registry (plan-self-reflective-layer.md
//  § Registries, RG-4..6). `impress-keymap` (Rust) is the one place a GUI
//  chord is declared; `keymap_json()` (`impress-store-ffi`, exported to
//  Swift as `keymapJson()`) carries the registry over UniFFI. This type
//  decodes that JSON once and answers `shortcut(for:)` by palette command
//  id — the `.keyboardShortcut(...)` call sites read a chord out of it
//  instead of writing one as a literal. Swift adds no logic here: it only
//  maps the registry's wire shape to SwiftUI's `KeyboardShortcut`.
//

import Foundation
import SwiftUI
import ImpressRustCore

/// A read-only view of the Rust keymap registry, decoded once from
/// `keymapJson()`.
public struct KeymapRegistry {

    /// One row of the wire format — see `impress-keymap::keymap_json`'s doc
    /// comment for the exact shape.
    public struct Entry: Decodable, Sendable {
        public let chord: String
        public let scope: String
        public let target: Target
        public let label: String
        public let section: String
        public let chordless: Bool

        public struct Target: Decodable, Sendable {
            public let kind: String
            public let id: String
        }
    }

    private struct Wire: Decodable {
        let wire_version: Int
        let bindings: [Entry]
    }

    /// The suite-wide instance, decoding `keymapJson()` once at first use.
    public static let shared = KeymapRegistry()

    /// Every seeded binding, in registry order — used by the coverage test
    /// (`ImpressKeyboardTests`) to compare against the menu's own literals.
    public let entries: [Entry]

    private let byCommandID: [String: Entry]

    /// - Parameter json: the registry's wire JSON. Defaults to
    ///   `keymapJson()` (the UniFFI export); a test passes a fixture string
    ///   instead of touching the Rust FFI.
    public init(json: String = keymapJson()) {
        let decoded: Wire
        if let data = json.data(using: .utf8),
           let wire = try? JSONDecoder().decode(Wire.self, from: data) {
            decoded = wire
        } else {
            decoded = Wire(wire_version: 1, bindings: [])
        }
        entries = decoded.bindings
        var byID: [String: Entry] = [:]
        for entry in decoded.bindings where entry.target.kind == "command" {
            // First registration wins — the registry itself is the single
            // source, so a duplicate command id here would be a fixture bug,
            // not a real collision (those are chords, checked by the Rust
            // coverage test).
            if byID[entry.target.id] == nil {
                byID[entry.target.id] = entry
            }
        }
        byCommandID = byID
    }

    /// The registry's row for a palette command id, or nil if the registry
    /// has no entry for it.
    public func entry(for commandID: String) -> Entry? {
        byCommandID[commandID]
    }

    /// The chord registered for a palette command id, as a `KeyboardShortcut`
    /// SwiftUI can attach with `.keyboardShortcut(...)`. Returns nil when the
    /// registry has no entry for the id, or when the entry is deliberately
    /// chordless (e.g. imbib's "Save to Library" — a palette-only command).
    public func shortcut(for commandID: String) -> KeyboardShortcut? {
        guard let entry = byCommandID[commandID], !entry.chordless, !entry.chord.isEmpty else {
            return nil
        }
        return Self.parse(entry.chord)
    }

    /// Parses one `Chord::Display` glyph string (e.g. `"⇧⌘F"`, `"⏎"`,
    /// `"⌃H"`) back into SwiftUI's `KeyEquivalent` + `EventModifiers`. The
    /// encoding is `impress-keymap::Chord`'s own Display impl — a fixed
    /// modifier-glyph order (⌃ ⌥ ⇧ ⌘) followed by exactly one key glyph — so
    /// this is a total, unambiguous inverse of it; no Rust chord logic is
    /// duplicated here, only its published spelling is read back.
    static func parse(_ chord: String) -> KeyboardShortcut? {
        guard !chord.isEmpty else { return nil }
        var modifiers: EventModifiers = []
        var rest = Substring(chord)
        let modifierGlyphs: [(Character, EventModifiers)] = [
            ("\u{2303}", .control),  // ⌃
            ("\u{2325}", .option),   // ⌥
            ("\u{21e7}", .shift),    // ⇧
            ("\u{2318}", .command),  // ⌘
        ]
        for (glyph, modifier) in modifierGlyphs where rest.first == glyph {
            modifiers.insert(modifier)
            rest.removeFirst()
        }
        guard rest.count == 1, let keyGlyph = rest.first else { return nil }
        let specialGlyphs: [Character: KeyEquivalent] = [
            "\u{23ce}": .return,   // ⏎
            "\u{232b}": .delete,   // ⌫
            "\u{238b}": .escape,   // ⎋
            "\u{2191}": .upArrow,  // ↑
            "\u{2193}": .downArrow // ↓
        ]
        let key: KeyEquivalent
        if let special = specialGlyphs[keyGlyph] {
            key = special
        } else {
            // Every other key is a single, case-normalized character in the
            // registry (`Chord::new` lowercases nothing; `Display` uppercases
            // letters, leaving digits/symbols as-is) — lowercasing here
            // exactly undoes that.
            key = KeyEquivalent(Character(String(keyGlyph).lowercased()))
        }
        return KeyboardShortcut(key, modifiers: modifiers)
    }
}
