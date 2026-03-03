import Testing
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
}
