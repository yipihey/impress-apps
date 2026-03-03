import Testing
@testable import ImpressKeyboard

@Suite("Shortcut Key")
struct ShortcutKeyTests {

    // MARK: - init(from:)

    @Test("init(from:) creates character key for regular strings")
    func initCharacter() {
        let key = ShortcutKey(from: "a")
        if case .character(let char) = key {
            #expect(char == "a")
        } else {
            Issue.record("Expected .character")
        }
    }

    @Test("init(from:) creates special key for known names")
    func initSpecial() {
        let key = ShortcutKey(from: "return")
        if case .special(let special) = key {
            #expect(special == .return)
        } else {
            Issue.record("Expected .special(.return)")
        }
    }

    @Test("init(from:) lowercases character keys")
    func initLowercases() {
        let key = ShortcutKey(from: "J")
        if case .character(let char) = key {
            #expect(char == "j")
        } else {
            Issue.record("Expected .character")
        }
    }

    // MARK: - displayString

    @Test("Character key displayString is lowercase")
    func displayStringCharacter() {
        #expect(ShortcutKey.character("A").displayString == "a")
        #expect(ShortcutKey.character("j").displayString == "j")
    }

    @Test("Special key displayString uses symbols")
    func displayStringSpecial() {
        #expect(ShortcutKey.special(.return).displayString == "↩")
        #expect(ShortcutKey.special(.escape).displayString == "⎋")
        #expect(ShortcutKey.special(.upArrow).displayString == "↑")
        #expect(ShortcutKey.special(.downArrow).displayString == "↓")
    }

    // MARK: - stringValue round-trip

    @Test("stringValue round-trips through init(from:)")
    func roundTrip() {
        let original = ShortcutKey(from: "escape")
        let restored = ShortcutKey(from: original.stringValue)
        #expect(original == restored)

        let charOriginal = ShortcutKey(from: "k")
        let charRestored = ShortcutKey(from: charOriginal.stringValue)
        #expect(charOriginal == charRestored)
    }

    // MARK: - SpecialKey coverage

    @Test("All special keys have non-empty display symbols")
    func allSpecialKeysHaveSymbols() {
        for key in ShortcutKey.SpecialKey.allCases {
            #expect(!key.displaySymbol.isEmpty, "Missing symbol for \(key.rawValue)")
        }
    }

    @Test("All special keys have distinct raw values")
    func distinctRawValues() {
        let rawValues = ShortcutKey.SpecialKey.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == ShortcutKey.SpecialKey.allCases.count)
    }
}
