import Testing
import Foundation
@testable import ImpressCommandPalette

@Suite("Command Model")
struct CommandModelTests {

    // MARK: - Command properties

    @Test("displayName returns name")
    func displayName() {
        let cmd = Command(id: "1", name: "Show Library", category: "Nav", app: "imbib", uri: "impress://imbib/show")
        #expect(cmd.displayName == "Show Library")
    }

    @Test("qualifiedName returns 'app: name'")
    func qualifiedName() {
        let cmd = Command(id: "1", name: "Show Library", category: "Nav", app: "imbib", uri: "impress://imbib/show")
        #expect(cmd.qualifiedName == "imbib: Show Library")
    }

    @Test("Command is Hashable")
    func hashable() {
        let cmd1 = Command(id: "1", name: "A", category: "Nav", app: "imbib", uri: "x")
        let cmd2 = Command(id: "2", name: "B", category: "Nav", app: "imbib", uri: "y")
        let set: Set<Command> = [cmd1, cmd2]
        #expect(set.count == 2)
    }

    // MARK: - CommandCategory

    @Test("All 8 categories have non-empty displayName")
    func categoryDisplayNames() {
        for category in CommandCategory.allCases {
            #expect(!category.displayName.isEmpty)
        }
    }

    @Test("All 8 categories have non-empty icon")
    func categoryIcons() {
        for category in CommandCategory.allCases {
            #expect(!category.icon.isEmpty)
        }
    }

    @Test("CommandCategory has exactly 8 cases")
    func categoryCaseCount() {
        #expect(CommandCategory.allCases.count == 8)
    }

    // MARK: - CommandsResponse

    @Test("CommandsResponse Codable round-trip")
    func commandsResponseCodable() throws {
        let cmd = Command(id: "1", name: "Test", category: "Nav", app: "imbib", uri: "x")
        let response = CommandsResponse(app: "imbib", version: "1.0", commands: [cmd])

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(CommandsResponse.self, from: data)

        #expect(decoded.status == "ok")
        #expect(decoded.app == "imbib")
        #expect(decoded.version == "1.0")
        #expect(decoded.commands.count == 1)
        #expect(decoded.commands[0].name == "Test")
    }

    // MARK: - AppEndpoint

    @Test("AppEndpoint URL construction")
    func endpointURLs() {
        let endpoint = AppEndpoint(app: "test", port: 8080)
        #expect(endpoint.baseURL.absoluteString == "http://127.0.0.1:8080")
        #expect(endpoint.commandsURL.absoluteString.contains("/api/commands"))
        #expect(endpoint.statusURL.absoluteString.contains("/api/status"))
    }

    @Test("AppEndpoint presets have correct ports")
    func presetPorts() {
        #expect(AppEndpoint.imbib.port == 23120)
        #expect(AppEndpoint.imprint.port == 23121)
        #expect(AppEndpoint.impart.port == 23122)
        #expect(AppEndpoint.impel.port == 23123)
        #expect(AppEndpoint.implore.port == 23124)
    }

    @Test("AppEndpoint.all contains all 5 apps")
    func allEndpoints() {
        #expect(AppEndpoint.all.count == 5)
        let apps = Set(AppEndpoint.all.map(\.app))
        #expect(apps.contains("imbib"))
        #expect(apps.contains("imprint"))
        #expect(apps.contains("impart"))
        #expect(apps.contains("impel"))
        #expect(apps.contains("implore"))
    }
}
