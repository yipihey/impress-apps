import Testing
import Foundation
@testable import ImpressFTUI

@Suite("Flag Models")
struct FlagModelsTests {

    // MARK: - FlagColor

    @Test("FlagColor has 4 cases")
    func flagColorCases() {
        #expect(FlagColor.allCases.count == 4)
    }

    @Test("FlagColor display names are correct")
    func flagColorDisplayNames() {
        #expect(FlagColor.red.displayName == "Red")
        #expect(FlagColor.amber.displayName == "Amber")
        #expect(FlagColor.blue.displayName == "Blue")
        #expect(FlagColor.gray.displayName == "Gray")
    }

    @Test("FlagColor shortcuts are unique single characters")
    func flagColorShortcuts() {
        let shortcuts = FlagColor.allCases.map(\.shortcut)
        #expect(Set(shortcuts).count == 4)
        #expect(shortcuts.contains("r"))
        #expect(shortcuts.contains("a"))
        #expect(shortcuts.contains("b"))
        #expect(shortcuts.contains("g"))
    }

    // MARK: - FlagStyle

    @Test("FlagStyle has 3 cases with correct display names")
    func flagStyleCases() {
        #expect(FlagStyle.allCases.count == 3)
        #expect(FlagStyle.solid.displayName == "Solid")
        #expect(FlagStyle.dashed.displayName == "Dashed")
        #expect(FlagStyle.dotted.displayName == "Dotted")
    }

    @Test("FlagStyle shortcuts are unique")
    func flagStyleShortcuts() {
        let shortcuts = FlagStyle.allCases.map(\.shortcut)
        #expect(Set(shortcuts).count == 3)
    }

    // MARK: - FlagLength

    @Test("FlagLength fractions are correct")
    func flagLengthFractions() {
        #expect(FlagLength.full.fraction == 1.0)
        #expect(FlagLength.half.fraction == 0.5)
        #expect(FlagLength.quarter.fraction == 0.25)
    }

    @Test("FlagLength display names are correct")
    func flagLengthDisplayNames() {
        #expect(FlagLength.full.displayName == "Full")
        #expect(FlagLength.half.displayName == "Half")
        #expect(FlagLength.quarter.displayName == "Quarter")
    }

    // MARK: - PublicationFlag

    @Test("PublicationFlag.simple() creates solid/full flag")
    func simpleFactory() {
        let flag = PublicationFlag.simple(.red)
        #expect(flag.color == .red)
        #expect(flag.style == .solid)
        #expect(flag.length == .full)
    }

    @Test("PublicationFlag Codable round-trip preserves values")
    func codableRoundTrip() throws {
        let original = PublicationFlag(color: .amber, style: .dashed, length: .half)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PublicationFlag.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - FlagColorConfig

    @Test("FlagColorConfig.defaults has entry for every color")
    func defaultsComplete() {
        for color in FlagColor.allCases {
            #expect(FlagColorConfig.defaults[color] != nil)
        }
    }

    @Test("FlagColorConfig semantic labels are non-empty")
    func semanticLabels() {
        for (_, config) in FlagColorConfig.defaults {
            #expect(!config.semanticLabel.isEmpty)
        }
    }
}
