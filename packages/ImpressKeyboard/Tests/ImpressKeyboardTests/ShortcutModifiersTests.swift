import Testing
import SwiftUI
@testable import ImpressKeyboard

@Suite("Shortcut Modifiers")
struct ShortcutModifiersTests {

    // MARK: - displayString

    @Test("Shift-only displays as 'Shift+'")
    func shiftOnlyDisplay() {
        #expect(ShortcutModifiers.shift.displayString == "Shift+")
    }

    @Test("Command displays as ⌘")
    func commandDisplay() {
        #expect(ShortcutModifiers.command.displayString == "⌘")
    }

    @Test("Control displays as ⌃")
    func controlDisplay() {
        #expect(ShortcutModifiers.control.displayString == "⌃")
    }

    @Test("Option displays as ⌥")
    func optionDisplay() {
        #expect(ShortcutModifiers.option.displayString == "⌥")
    }

    @Test("All modifiers combined display in correct order: ⌃⌥⇧⌘")
    func allModifiersDisplay() {
        let all: ShortcutModifiers = [.control, .option, .shift, .command]
        let display = all.displayString
        #expect(display.contains("⌃"))
        #expect(display.contains("⌥"))
        #expect(display.contains("⇧"))
        #expect(display.contains("⌘"))
    }

    @Test("Empty modifiers display as empty string")
    func emptyDisplay() {
        #expect(ShortcutModifiers.none.displayString == "")
    }

    // MARK: - OptionSet composition

    @Test("OptionSet union works correctly")
    func optionSetUnion() {
        let combined = ShortcutModifiers.command.union(.shift)
        #expect(combined.contains(.command))
        #expect(combined.contains(.shift))
        #expect(!combined.contains(.option))
    }

    // MARK: - eventModifiers conversion

    @Test("eventModifiers maps correctly")
    func eventModifiersMapping() {
        let mods: ShortcutModifiers = [.command, .shift]
        let event = mods.eventModifiers
        #expect(event.contains(.command))
        #expect(event.contains(.shift))
        #expect(!event.contains(.option))
    }

    @Test("init(from:) round-trips through eventModifiers")
    func roundTrip() {
        let original: ShortcutModifiers = [.command, .option]
        let eventMods = original.eventModifiers
        let restored = ShortcutModifiers(from: eventMods)
        #expect(restored == original)
    }
}
