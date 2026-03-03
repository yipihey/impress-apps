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

    @Test("Color hex initialization")
    func colorHexInit() {
        #expect(Color(hex: "#FF0000") != nil)
        #expect(Color(hex: "00FF00") != nil)
        #expect(Color(hex: "invalid") == nil)
        #expect(Color(hex: "") == nil)
    }
}
