//
//  CommandPaletteClient.swift
//  ImpressCommandPalette
//
//  Client for discovering and fetching commands from running impress apps.
//

import Foundation

// MARK: - App Endpoint Configuration

/// Configuration for connecting to an impress app's HTTP API.
public struct AppEndpoint: Sendable {
    public let app: String
    public let port: UInt16
    public let host: String

    public init(app: String, port: UInt16, host: String = "127.0.0.1") {
        self.app = app
        self.port = port
        self.host = host
    }

    public var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    public var commandsURL: URL {
        baseURL.appendingPathComponent("api/commands")
    }

    public var statusURL: URL {
        baseURL.appendingPathComponent("api/status")
    }
}

/// Default ports for impress apps
public extension AppEndpoint {
    static let imbib = AppEndpoint(app: "imbib", port: 23120)
    static let imprint = AppEndpoint(app: "imprint", port: 23121)
    static let impart = AppEndpoint(app: "impart", port: 23122)
    static let impel = AppEndpoint(app: "impel", port: 23123)
    static let implore = AppEndpoint(app: "implore", port: 23124)

    static let all: [AppEndpoint] = [.imbib, .imprint, .impart, .impel, .implore]
}

// MARK: - Command Palette Client

/// Client for fetching commands from all running impress apps.
public actor CommandPaletteClient {

    // MARK: - Properties

    private let session: URLSession
    private let endpoints: [AppEndpoint]
    private let timeout: TimeInterval

    /// Cache of discovered commands
    private var cachedCommands: [Command] = []
    private var lastFetchTime: Date?
    private let cacheValiditySeconds: TimeInterval = 5.0

    // MARK: - Initialization

    public init(
        endpoints: [AppEndpoint] = AppEndpoint.all,
        timeout: TimeInterval = 2.0
    ) {
        self.endpoints = endpoints
        self.timeout = timeout

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Fetch commands from all running impress apps.
    /// Returns cached commands if still valid, otherwise fetches fresh.
    public func allCommands(forceRefresh: Bool = false) async -> [Command] {
        // Check cache validity
        if !forceRefresh,
           let lastFetch = lastFetchTime,
           Date().timeIntervalSince(lastFetch) < cacheValiditySeconds {
            return cachedCommands
        }

        // Fetch from all apps in parallel
        let commands = await fetchFromAllApps()
        cachedCommands = commands
        lastFetchTime = Date()

        return commands
    }

    /// Check which apps are currently running and responding.
    public func runningApps() async -> [String] {
        var running: [String] = []

        await withTaskGroup(of: (String, Bool).self) { group in
            for endpoint in endpoints {
                group.addTask {
                    let isRunning = await self.checkAppStatus(endpoint)
                    return (endpoint.app, isRunning)
                }
            }

            for await (app, isRunning) in group {
                if isRunning {
                    running.append(app)
                }
            }
        }

        return running.sorted()
    }

    /// Fetch commands from a specific app.
    public func commands(from app: String) async -> [Command] {
        guard let endpoint = endpoints.first(where: { $0.app == app }) else {
            return []
        }
        return await fetchCommands(from: endpoint)
    }

    // MARK: - Private Helpers

    private func fetchFromAllApps() async -> [Command] {
        var allCommands: [Command] = []

        await withTaskGroup(of: [Command].self) { group in
            for endpoint in endpoints {
                group.addTask {
                    await self.fetchCommands(from: endpoint)
                }
            }

            for await commands in group {
                allCommands.append(contentsOf: commands)
            }
        }

        // Sort by app, then category, then name
        return allCommands.sorted { a, b in
            if a.app != b.app { return a.app < b.app }
            if a.category != b.category { return a.category < b.category }
            return a.name < b.name
        }
    }

    private func fetchCommands(from endpoint: AppEndpoint) async -> [Command] {
        do {
            let (data, response) = try await session.data(from: endpoint.commandsURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return []
            }

            let decoder = JSONDecoder()
            let commandsResponse = try decoder.decode(CommandsResponse.self, from: data)
            return commandsResponse.commands

        } catch {
            // App not running or endpoint not available
            return []
        }
    }

    private func checkAppStatus(_ endpoint: AppEndpoint) async -> Bool {
        do {
            let (_, response) = try await session.data(from: endpoint.statusURL)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - Command Filtering

public extension Array where Element == Command {
    /// Filter commands by search query.
    /// Matches against name, description, category, and app.
    func filtered(by query: String) -> [Command] {
        guard !query.isEmpty else { return self }

        let lowercasedQuery = query.lowercased()

        return filter { command in
            command.name.lowercased().contains(lowercasedQuery) ||
            command.qualifiedName.lowercased().contains(lowercasedQuery) ||
            command.category.lowercased().contains(lowercasedQuery) ||
            command.app.lowercased().contains(lowercasedQuery) ||
            (command.description?.lowercased().contains(lowercasedQuery) ?? false)
        }
    }

    /// Group commands by app.
    func groupedByApp() -> [String: [Command]] {
        Dictionary(grouping: self, by: { $0.app })
    }

    /// Group commands by category.
    func groupedByCategory() -> [String: [Command]] {
        Dictionary(grouping: self, by: { $0.category })
    }
}
