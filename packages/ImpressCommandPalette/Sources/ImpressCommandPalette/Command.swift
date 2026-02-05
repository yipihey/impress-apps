//
//  Command.swift
//  ImpressCommandPalette
//
//  Universal command representation for cross-app command palette.
//

import Foundation

// MARK: - Command

/// A command that can be executed from the universal command palette.
public struct Command: Identifiable, Codable, Sendable, Hashable {
    /// Unique identifier for the command
    public let id: String

    /// Display name shown in the palette
    public let name: String

    /// Optional description/subtitle
    public let description: String?

    /// Category for grouping (e.g., "Navigation", "Paper Actions")
    public let category: String

    /// The app that provides this command (e.g., "imbib", "imprint")
    public let app: String

    /// Keyboard shortcut display string (e.g., "⌘1", "j")
    public let shortcut: String?

    /// Icon name (SF Symbol)
    public let icon: String?

    /// Whether this command is currently available
    public let isEnabled: Bool

    /// Deep link URI to execute this command (e.g., "impress://imbib/command/showLibrary")
    public let uri: String

    public init(
        id: String,
        name: String,
        description: String? = nil,
        category: String,
        app: String,
        shortcut: String? = nil,
        icon: String? = nil,
        isEnabled: Bool = true,
        uri: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.app = app
        self.shortcut = shortcut
        self.icon = icon
        self.isEnabled = isEnabled
        self.uri = uri
    }

    /// Full display string for the command (includes app prefix for cross-app)
    public var displayName: String {
        "\(name)"
    }

    /// Qualified name including app (for disambiguation)
    public var qualifiedName: String {
        "\(app): \(name)"
    }
}

// MARK: - Command Category

/// Standard command categories used across all impress apps.
public enum CommandCategory: String, CaseIterable, Sendable {
    case navigation = "Navigation"
    case views = "Views"
    case actions = "Actions"
    case search = "Search"
    case files = "Files"
    case editing = "Editing"
    case tools = "Tools"
    case app = "App"

    public var displayName: String { rawValue }

    public var icon: String {
        switch self {
        case .navigation: return "arrow.up.arrow.down"
        case .views: return "rectangle.3.group"
        case .actions: return "bolt.fill"
        case .search: return "magnifyingglass"
        case .files: return "folder"
        case .editing: return "pencil"
        case .tools: return "wrench.and.screwdriver"
        case .app: return "app"
        }
    }
}

// MARK: - Command Response

/// Response from GET /api/commands endpoint
public struct CommandsResponse: Codable, Sendable {
    public let status: String
    public let app: String
    public let version: String
    public let commands: [Command]

    public init(app: String, version: String, commands: [Command]) {
        self.status = "ok"
        self.app = app
        self.version = version
        self.commands = commands
    }
}

// MARK: - Command Provider Protocol

/// Protocol for apps to provide their available commands.
/// Each app implements this to expose its command set.
public protocol CommandProvider: Sendable {
    /// The app identifier (e.g., "imbib", "imprint")
    var appIdentifier: String { get }

    /// The app's current version
    var appVersion: String { get }

    /// Get all available commands from this app.
    /// Commands should reflect current app state (e.g., whether certain actions are available).
    func commands() async -> [Command]
}
