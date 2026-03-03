import Testing
@testable import ImpressLogging

@Suite("Log Level")
struct LogLevelTests {

    @Test("All 4 levels have non-empty icon strings")
    func iconsNonEmpty() {
        for level in LogLevel.allCases {
            #expect(!level.icon.isEmpty)
        }
    }

    @Test("All 4 levels have distinct raw values")
    func distinctRawValues() {
        let rawValues = LogLevel.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == 4)
    }

    @Test("LogLevel has exactly 4 cases")
    func caseCount() {
        #expect(LogLevel.allCases.count == 4)
    }

    @Test("Raw values match expected strings")
    func rawValues() {
        #expect(LogLevel.debug.rawValue == "debug")
        #expect(LogLevel.info.rawValue == "info")
        #expect(LogLevel.warning.rawValue == "warning")
        #expect(LogLevel.error.rawValue == "error")
    }
}
