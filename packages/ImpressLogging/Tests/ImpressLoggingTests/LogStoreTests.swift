import Testing
import Foundation
@testable import ImpressLogging

@Suite("Log Store")
@MainActor
struct LogStoreTests {

    // Use the shared singleton and reset between tests
    private var store: LogStore { LogStore.shared }

    private func resetStore() {
        store.clear()
        store.isEnabled = true
        store.maxEntries = 1000
    }

    // MARK: - Adding entries

    @Test("add() appends entries")
    func addEntry() {
        resetStore()
        let entry = LogEntry(level: .info, category: "test", message: "hello")
        store.add(entry)
        #expect(store.entries.count >= 1)
        #expect(store.entries.last?.message == "hello")
        #expect(store.entries.last?.level == .info)
        #expect(store.entries.last?.category == "test")
        resetStore()
    }

    @Test("log() convenience creates and adds entry")
    func logConvenience() {
        resetStore()
        store.log(level: .warning, category: "test", message: "warn msg")
        #expect(store.entries.last?.level == .warning)
        #expect(store.entries.last?.message == "warn msg")
        resetStore()
    }

    // MARK: - Ring buffer

    @Test("Ring buffer trims oldest entries when exceeding maxEntries")
    func ringBuffer() {
        resetStore()
        store.maxEntries = 5
        for i in 0..<10 {
            store.log(level: .info, category: "test", message: "msg \(i)")
        }
        #expect(store.entries.count == 5)
        // Oldest entries (0-4) should be trimmed; newest (5-9) remain
        #expect(store.entries.first?.message == "msg 5")
        #expect(store.entries.last?.message == "msg 9")
        resetStore()
    }

    // MARK: - isEnabled

    @Test("isEnabled=false makes add a no-op")
    func disabledStore() {
        resetStore()
        store.isEnabled = false
        store.log(level: .info, category: "test", message: "should not appear")
        #expect(store.entries.isEmpty)
        resetStore()
    }

    // MARK: - clear()

    @Test("clear() removes all entries")
    func clear() {
        resetStore()
        store.log(level: .info, category: "test", message: "msg1")
        store.log(level: .info, category: "test", message: "msg2")
        #expect(!store.entries.isEmpty)
        store.clear()
        #expect(store.entries.isEmpty)
    }

    // MARK: - Filtering

    @Test("filteredEntries filters by level")
    func filterByLevel() {
        resetStore()
        store.log(level: .info, category: "test", message: "info msg")
        store.log(level: .error, category: "test", message: "error msg")
        store.log(level: .debug, category: "test", message: "debug msg")

        let infoOnly = store.filteredEntries(levels: [.info], searchText: "")
        #expect(infoOnly.allSatisfy { $0.level == .info })

        let errorsOnly = store.filteredEntries(levels: [.error], searchText: "")
        #expect(errorsOnly.allSatisfy { $0.level == .error })
        resetStore()
    }

    @Test("filteredEntries filters by multiple levels")
    func filterByMultipleLevels() {
        resetStore()
        store.log(level: .info, category: "test", message: "info")
        store.log(level: .error, category: "test", message: "error")
        store.log(level: .debug, category: "test", message: "debug")

        let infoAndError = store.filteredEntries(levels: [.info, .error], searchText: "")
        #expect(infoAndError.count >= 2)
        #expect(infoAndError.allSatisfy { $0.level == .info || $0.level == .error })
        resetStore()
    }

    @Test("filteredEntries filters by search text in message")
    func filterBySearchText() {
        resetStore()
        store.log(level: .info, category: "test", message: "unique-marker-xyz")
        store.log(level: .info, category: "test", message: "other message")

        let filtered = store.filteredEntries(levels: Set(LogLevel.allCases), searchText: "unique-marker-xyz")
        #expect(filtered.count >= 1)
        #expect(filtered.allSatisfy { $0.message.contains("unique-marker-xyz") })
        resetStore()
    }

    @Test("filteredEntries matches search text in category")
    func filterByCategory() {
        resetStore()
        store.log(level: .info, category: "special-cat", message: "msg")
        store.log(level: .info, category: "other", message: "msg")

        let filtered = store.filteredEntries(levels: Set(LogLevel.allCases), searchText: "special-cat")
        #expect(filtered.count >= 1)
        #expect(filtered.allSatisfy { $0.category.contains("special-cat") })
        resetStore()
    }

    @Test("filteredEntries with empty search returns all matching levels")
    func emptySearchReturnsAll() {
        resetStore()
        store.log(level: .info, category: "test", message: "msg1")
        store.log(level: .info, category: "test", message: "msg2")

        let filtered = store.filteredEntries(levels: [.info], searchText: "")
        #expect(filtered.count >= 2)
        resetStore()
    }

    // MARK: - Export

    @Test("export() produces formatted log lines")
    func exportFormat() {
        resetStore()
        store.log(level: .info, category: "test", message: "export test")

        let exported = store.export()
        #expect(exported.contains("[INFO   ]"))
        #expect(exported.contains("[test"))
        #expect(exported.contains("export test"))
        resetStore()
    }
}
