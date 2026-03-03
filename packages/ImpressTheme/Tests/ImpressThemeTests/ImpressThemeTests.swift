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
}
