import Testing
import Foundation
@testable import ImpressTheme

@Suite("ImpressTheme")
struct ImpressThemeTests {
    @Test("AppearanceMode color scheme mapping")
    func appearanceModeColorScheme() {
        #expect(AppearanceMode.system.colorScheme == nil)
        #expect(AppearanceMode.light.colorScheme == .light)
        #expect(AppearanceMode.dark.colorScheme == .dark)
    }

    @Test("AppearanceMode display names")
    func appearanceModeDisplayNames() {
        #expect(AppearanceMode.system.displayName == "System")
        #expect(AppearanceMode.light.displayName == "Light")
        #expect(AppearanceMode.dark.displayName == "Dark")
    }

    @Test("AppearanceMode has exactly 3 cases")
    func allCases() {
        #expect(AppearanceMode.allCases.count == 3)
    }

    @Test("AppearanceMode Codable round-trip preserves values")
    func codableRoundTrip() throws {
        for mode in AppearanceMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(AppearanceMode.self, from: data)
            #expect(decoded == mode)
        }
    }

    /// The storage key is a MIGRATION contract, not an implementation detail:
    /// it is what four hand-written app-local modifiers read before ADR-0022 X2
    /// moved them here, what the chassis settings builtin writes, and what
    /// `PaneLayoutState.appAppearance` mirrors. Renaming it silently resets
    /// every existing user's preference — which reads as "my settings were
    /// lost", not as a bug. Change it only with a stored-value migration in the
    /// same commit.
    @Test("The appearance storage key is the suite-wide one")
    func appearanceStorageKeyIsFrozen() {
        #expect(AppearanceModifier.storageKey == "appearanceMode")
    }

    /// Every raw value the modifier can read back out of `@AppStorage` maps to
    /// a mode. The copies this replaced switched over raw STRINGS with a
    /// `default:` arm, so a fourth mode would have fallen silently to System in
    /// every app while the picker offered it.
    @Test("Every stored raw value round-trips to a mode")
    func everyRawValueIsRepresentable() {
        for mode in AppearanceMode.allCases {
            #expect(AppearanceMode(rawValue: mode.rawValue) == mode)
        }
        // The three raw values the pre-X2 copies matched on, verbatim.
        #expect(AppearanceMode(rawValue: "system") == .system)
        #expect(AppearanceMode(rawValue: "light") == .light)
        #expect(AppearanceMode(rawValue: "dark") == .dark)
        // …and the `default: return nil` arm they all ended with: an
        // unrecognised value is System, then and now.
        #expect(AppearanceMode(rawValue: "sepia") == nil)
    }
}
