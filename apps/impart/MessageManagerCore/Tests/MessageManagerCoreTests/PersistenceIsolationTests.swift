import Foundation
import Testing

@testable import MessageManagerCore

@MainActor
@Suite("Legacy mail store isolation")
struct PersistenceIsolationTests {
    @Test("hosted tests choose a per-process Core Data file")
    func hostedTestUsesScratchStore() {
        let selected = PersistenceController.selectedStoreURL(inMemory: false)
            .standardizedFileURL
        let expected = FileManager.default.temporaryDirectory
            .appendingPathComponent("impress-unit-tests-\(ProcessInfo.processInfo.processIdentifier)")
            .appendingPathComponent("legacy-mail/Impart.sqlite")
            .standardizedFileURL

        #expect(selected == expected)
        #expect(selected.path != FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("impart/Impart.sqlite").path)
        #expect(PersistenceController.selectedStoreURL(inMemory: true).path == "/dev/null")
    }
}
