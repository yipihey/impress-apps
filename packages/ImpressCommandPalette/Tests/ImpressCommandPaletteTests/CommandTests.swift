//
//  CommandTests.swift
//  ImpressCommandPaletteTests
//
//  Tests for Command type and related functionality.
//

import XCTest
@testable import ImpressCommandPalette

final class CommandTests: XCTestCase {

    // MARK: - Command Creation

    func testCommandCreation() {
        let command = Command(
            id: "imbib.showLibrary",
            name: "Show Library",
            description: "Navigate to the library view",
            category: "Navigation",
            app: "imbib",
            shortcut: "⌘1",
            icon: "books.vertical",
            isEnabled: true,
            uri: "impress://imbib/command/showLibrary"
        )

        XCTAssertEqual(command.id, "imbib.showLibrary")
        XCTAssertEqual(command.name, "Show Library")
        XCTAssertEqual(command.description, "Navigate to the library view")
        XCTAssertEqual(command.category, "Navigation")
        XCTAssertEqual(command.app, "imbib")
        XCTAssertEqual(command.shortcut, "⌘1")
        XCTAssertEqual(command.icon, "books.vertical")
        XCTAssertTrue(command.isEnabled)
        XCTAssertEqual(command.uri, "impress://imbib/command/showLibrary")
    }

    func testCommandDisplayName() {
        let command = Command(
            id: "test.command",
            name: "Test Command",
            category: "Actions",
            app: "imbib",
            uri: "impress://imbib/command/test"
        )

        XCTAssertEqual(command.displayName, "Test Command")
    }

    func testCommandQualifiedName() {
        let command = Command(
            id: "test.command",
            name: "Search",
            category: "Search",
            app: "imbib",
            uri: "impress://imbib/command/search"
        )

        XCTAssertEqual(command.qualifiedName, "imbib: Search")
    }

    func testCommandDefaults() {
        let command = Command(
            id: "test",
            name: "Test",
            category: "Test",
            app: "test",
            uri: "test://test"
        )

        // Test default values
        XCTAssertNil(command.description)
        XCTAssertNil(command.shortcut)
        XCTAssertNil(command.icon)
        XCTAssertTrue(command.isEnabled) // Default is true
    }

    // MARK: - Command Equatable/Hashable

    func testCommandEquatable() {
        let command1 = Command(
            id: "imbib.search",
            name: "Search",
            category: "Search",
            app: "imbib",
            uri: "impress://imbib/command/search"
        )

        let command2 = Command(
            id: "imbib.search",
            name: "Search",
            category: "Search",
            app: "imbib",
            uri: "impress://imbib/command/search"
        )

        XCTAssertEqual(command1, command2)
    }

    func testCommandHashable() {
        let command1 = Command(
            id: "imbib.search",
            name: "Search",
            category: "Search",
            app: "imbib",
            uri: "impress://imbib/command/search"
        )

        let command2 = Command(
            id: "imbib.search",
            name: "Search",
            category: "Search",
            app: "imbib",
            uri: "impress://imbib/command/search"
        )

        var set = Set<Command>()
        set.insert(command1)
        set.insert(command2)

        XCTAssertEqual(set.count, 1)
    }

    // MARK: - Command Codable

    func testCommandEncodeDecode() throws {
        let original = Command(
            id: "imbib.toggleSidebar",
            name: "Toggle Sidebar",
            description: "Show or hide the sidebar",
            category: "Views",
            app: "imbib",
            shortcut: "⌘\\",
            icon: "sidebar.left",
            isEnabled: true,
            uri: "impress://imbib/command/toggleSidebar"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Command.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - CommandCategory

    func testCommandCategoryDisplayName() {
        XCTAssertEqual(CommandCategory.navigation.displayName, "Navigation")
        XCTAssertEqual(CommandCategory.views.displayName, "Views")
        XCTAssertEqual(CommandCategory.actions.displayName, "Actions")
        XCTAssertEqual(CommandCategory.search.displayName, "Search")
        XCTAssertEqual(CommandCategory.files.displayName, "Files")
        XCTAssertEqual(CommandCategory.editing.displayName, "Editing")
        XCTAssertEqual(CommandCategory.tools.displayName, "Tools")
        XCTAssertEqual(CommandCategory.app.displayName, "App")
    }

    func testCommandCategoryIcon() {
        // Just verify icons are non-empty SF Symbol names
        for category in CommandCategory.allCases {
            XCTAssertFalse(category.icon.isEmpty, "Category \(category) should have an icon")
        }
    }

    // MARK: - CommandsResponse

    func testCommandsResponseCreation() {
        let commands = [
            Command(
                id: "test.cmd1",
                name: "Command 1",
                category: "Test",
                app: "test",
                uri: "test://cmd1"
            ),
            Command(
                id: "test.cmd2",
                name: "Command 2",
                category: "Test",
                app: "test",
                uri: "test://cmd2"
            )
        ]

        let response = CommandsResponse(
            app: "test",
            version: "1.0.0",
            commands: commands
        )

        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.app, "test")
        XCTAssertEqual(response.version, "1.0.0")
        XCTAssertEqual(response.commands.count, 2)
    }

    func testCommandsResponseEncodeDecode() throws {
        let commands = [
            Command(
                id: "imbib.library",
                name: "Show Library",
                category: "Navigation",
                app: "imbib",
                uri: "impress://imbib/command/showLibrary"
            )
        ]

        let original = CommandsResponse(
            app: "imbib",
            version: "3.0.0",
            commands: commands
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CommandsResponse.self, from: data)

        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.app, original.app)
        XCTAssertEqual(decoded.version, original.version)
        XCTAssertEqual(decoded.commands.count, original.commands.count)
        XCTAssertEqual(decoded.commands.first?.id, "imbib.library")
    }

    // MARK: - Command Filtering

    func testCommandFilteringByName() {
        let commands = [
            Command(id: "1", name: "Show Library", category: "Nav", app: "imbib", uri: "u1"),
            Command(id: "2", name: "Search", category: "Search", app: "imbib", uri: "u2"),
            Command(id: "3", name: "Show PDF", category: "Nav", app: "imbib", uri: "u3")
        ]

        let filtered = commands.filtered(by: "show")

        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.contains(where: { $0.name == "Show Library" }))
        XCTAssertTrue(filtered.contains(where: { $0.name == "Show PDF" }))
    }

    func testCommandFilteringByCategory() {
        let commands = [
            Command(id: "1", name: "Nav Command", category: "Navigation", app: "imbib", uri: "u1"),
            Command(id: "2", name: "Search Command", category: "Search", app: "imbib", uri: "u2")
        ]

        let filtered = commands.filtered(by: "navigation")

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.name, "Nav Command")
    }

    func testCommandFilteringByApp() {
        let commands = [
            Command(id: "1", name: "Cmd A", category: "Test", app: "imbib", uri: "u1"),
            Command(id: "2", name: "Cmd B", category: "Test", app: "imprint", uri: "u2")
        ]

        let filtered = commands.filtered(by: "imprint")

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.app, "imprint")
    }

    func testCommandFilteringCaseInsensitive() {
        let commands = [
            Command(id: "1", name: "Show Library", category: "Nav", app: "imbib", uri: "u1")
        ]

        XCTAssertEqual(commands.filtered(by: "LIBRARY").count, 1)
        XCTAssertEqual(commands.filtered(by: "Library").count, 1)
        XCTAssertEqual(commands.filtered(by: "library").count, 1)
    }

    func testCommandFilteringEmptyQuery() {
        let commands = [
            Command(id: "1", name: "Cmd 1", category: "Test", app: "test", uri: "u1"),
            Command(id: "2", name: "Cmd 2", category: "Test", app: "test", uri: "u2")
        ]

        let filtered = commands.filtered(by: "")

        XCTAssertEqual(filtered.count, 2)
    }

    // MARK: - Command Grouping

    func testCommandGroupingByApp() {
        let commands = [
            Command(id: "1", name: "Cmd 1", category: "Test", app: "imbib", uri: "u1"),
            Command(id: "2", name: "Cmd 2", category: "Test", app: "imprint", uri: "u2"),
            Command(id: "3", name: "Cmd 3", category: "Test", app: "imbib", uri: "u3")
        ]

        let grouped = commands.groupedByApp()

        XCTAssertEqual(grouped.keys.count, 2)
        XCTAssertEqual(grouped["imbib"]?.count, 2)
        XCTAssertEqual(grouped["imprint"]?.count, 1)
    }

    func testCommandGroupingByCategory() {
        let commands = [
            Command(id: "1", name: "Cmd 1", category: "Navigation", app: "test", uri: "u1"),
            Command(id: "2", name: "Cmd 2", category: "Search", app: "test", uri: "u2"),
            Command(id: "3", name: "Cmd 3", category: "Navigation", app: "test", uri: "u3")
        ]

        let grouped = commands.groupedByCategory()

        XCTAssertEqual(grouped.keys.count, 2)
        XCTAssertEqual(grouped["Navigation"]?.count, 2)
        XCTAssertEqual(grouped["Search"]?.count, 1)
    }

    // MARK: - AppEndpoint

    func testAppEndpointDefaults() {
        XCTAssertEqual(AppEndpoint.imbib.app, "imbib")
        XCTAssertEqual(AppEndpoint.imbib.port, 23120)

        XCTAssertEqual(AppEndpoint.imprint.app, "imprint")
        XCTAssertEqual(AppEndpoint.imprint.port, 23121)

        XCTAssertEqual(AppEndpoint.impart.app, "impart")
        XCTAssertEqual(AppEndpoint.impart.port, 23122)

        XCTAssertEqual(AppEndpoint.impel.app, "impel")
        XCTAssertEqual(AppEndpoint.impel.port, 23123)

        XCTAssertEqual(AppEndpoint.implore.app, "implore")
        XCTAssertEqual(AppEndpoint.implore.port, 23124)
    }

    func testAppEndpointURLs() {
        let endpoint = AppEndpoint.imbib

        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://127.0.0.1:23120")
        XCTAssertEqual(endpoint.commandsURL.absoluteString, "http://127.0.0.1:23120/api/commands")
        XCTAssertEqual(endpoint.statusURL.absoluteString, "http://127.0.0.1:23120/api/status")
    }

    func testAppEndpointAllList() {
        let all = AppEndpoint.all

        XCTAssertEqual(all.count, 5)
        XCTAssertTrue(all.contains(where: { $0.app == "imbib" }))
        XCTAssertTrue(all.contains(where: { $0.app == "imprint" }))
        XCTAssertTrue(all.contains(where: { $0.app == "impart" }))
        XCTAssertTrue(all.contains(where: { $0.app == "impel" }))
        XCTAssertTrue(all.contains(where: { $0.app == "implore" }))
    }
}
