import XCTest
@testable import ImpressKeyboard

final class ShortcutKeyTests: XCTestCase {

    func testCharacterKeyDisplayStringIsLowercase() {
        let key = ShortcutKey.character("J")
        XCTAssertEqual(key.displayString, "j")
    }

    func testSpecialKeyDisplaySymbols() {
        XCTAssertEqual(ShortcutKey.special(.return).displayString, "↩")
        XCTAssertEqual(ShortcutKey.special(.escape).displayString, "⎋")
        XCTAssertEqual(ShortcutKey.special(.upArrow).displayString, "↑")
        XCTAssertEqual(ShortcutKey.special(.downArrow).displayString, "↓")
        XCTAssertEqual(ShortcutKey.special(.space).displayString, "Space")
    }

    func testStringInitParsesSpecialKeys() {
        let returnKey = ShortcutKey(from: "return")
        XCTAssertEqual(returnKey, .special(.return))

        let escapeKey = ShortcutKey(from: "escape")
        XCTAssertEqual(escapeKey, .special(.escape))
    }

    func testStringInitParsesCharacterKeys() {
        let jKey = ShortcutKey(from: "j")
        XCTAssertEqual(jKey, .character("j"))

        let upperKey = ShortcutKey(from: "K")
        XCTAssertEqual(upperKey, .character("k"))
    }

    func testStringValueRoundtrip() {
        let charKey = ShortcutKey.character("x")
        XCTAssertEqual(charKey.stringValue, "x")

        let specialKey = ShortcutKey.special(.tab)
        XCTAssertEqual(specialKey.stringValue, "tab")
    }
}

final class ShortcutModifiersTests: XCTestCase {

    func testCommandDisplayString() {
        let mods = ShortcutModifiers.command
        XCTAssertEqual(mods.displayString, "⌘")
    }

    func testShiftDisplayString() {
        let mods = ShortcutModifiers.shift
        XCTAssertEqual(mods.displayString, "Shift+")
    }

    func testMultipleModifiersDisplayString() {
        let mods: ShortcutModifiers = [.command, .shift]
        XCTAssertEqual(mods.displayString, "⇧⌘")
    }

    func testOptionSetOperations() {
        var mods: ShortcutModifiers = .command
        mods.insert(.option)
        XCTAssertTrue(mods.contains(.command))
        XCTAssertTrue(mods.contains(.option))
        XCTAssertFalse(mods.contains(.shift))
    }

    func testNoneModifier() {
        let mods = ShortcutModifiers.none
        XCTAssertTrue(mods.isEmpty)
        XCTAssertEqual(mods.displayString, "")
    }
}
