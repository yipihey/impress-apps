import Testing
@testable import ImpressCommandPalette

@Suite("Command Filtering")
struct CommandFilteringTests {

    // MARK: - Test data

    private static let testCommands: [Command] = [
        Command(id: "1", name: "Show Library", category: "Navigation", app: "imbib", uri: "impress://imbib/showLibrary"),
        Command(id: "2", name: "New Document", category: "Actions", app: "imprint", uri: "impress://imprint/newDocument"),
        Command(id: "3", name: "Navigate Forward", description: "Go to next item", category: "Navigation", app: "imbib", shortcut: "l", uri: "impress://imbib/navigateForward"),
        Command(id: "4", name: "Compose Email", category: "Actions", app: "impart", uri: "impress://impart/compose"),
        Command(id: "5", name: "Search Papers", category: "Search", app: "imbib", uri: "impress://imbib/search"),
    ]

    // MARK: - filtered(by:)

    @Test("Empty query returns all commands")
    func emptyQueryReturnsAll() {
        let filtered = Self.testCommands.filtered(by: "")
        #expect(filtered.count == Self.testCommands.count)
    }

    @Test("Filter by name matches correctly")
    func filterByName() {
        let filtered = Self.testCommands.filtered(by: "Library")
        #expect(filtered.count == 1)
        #expect(filtered[0].name == "Show Library")
    }

    @Test("Filter is case-insensitive")
    func caseInsensitive() {
        let upper = Self.testCommands.filtered(by: "LIBRARY")
        let lower = Self.testCommands.filtered(by: "library")
        #expect(upper.count == lower.count)
        #expect(upper.count == 1)
    }

    @Test("Filter matches on category")
    func filterByCategory() {
        let filtered = Self.testCommands.filtered(by: "Navigation")
        #expect(filtered.count == 2) // "Show Library" and "Navigate Forward"
    }

    @Test("Filter matches on app name")
    func filterByApp() {
        let filtered = Self.testCommands.filtered(by: "impart")
        #expect(filtered.count == 1)
        #expect(filtered[0].name == "Compose Email")
    }

    @Test("Filter matches on description")
    func filterByDescription() {
        let filtered = Self.testCommands.filtered(by: "next item")
        #expect(filtered.count == 1)
        #expect(filtered[0].name == "Navigate Forward")
    }

    @Test("No matches returns empty array")
    func noMatches() {
        let filtered = Self.testCommands.filtered(by: "zzzznonexistent")
        #expect(filtered.isEmpty)
    }

    // MARK: - groupedByApp()

    @Test("groupedByApp creates correct grouping")
    func groupedByApp() {
        let grouped = Self.testCommands.groupedByApp()
        #expect(grouped["imbib"]?.count == 3)
        #expect(grouped["imprint"]?.count == 1)
        #expect(grouped["impart"]?.count == 1)
    }

    // MARK: - groupedByCategory()

    @Test("groupedByCategory creates correct grouping")
    func groupedByCategory() {
        let grouped = Self.testCommands.groupedByCategory()
        #expect(grouped["Navigation"]?.count == 2)
        #expect(grouped["Actions"]?.count == 2)
        #expect(grouped["Search"]?.count == 1)
    }
}
