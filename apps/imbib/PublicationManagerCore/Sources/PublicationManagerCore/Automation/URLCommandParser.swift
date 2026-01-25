//
//  URLCommandParser.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation

// MARK: - Automation Command

/// Commands that can be executed via the automation API.
///
/// These commands map to internal NotificationCenter notifications
/// and can be triggered via URL schemes or the CLI tool.
public enum AutomationCommand: Sendable {

    // MARK: - File Operations

    /// Import BibTeX data
    case importBibTeX(data: Data?, filePath: String?, libraryID: UUID?)

    /// Import RIS data
    case importRIS(data: Data?, filePath: String?, libraryID: UUID?)

    /// Import from browser extension with metadata
    case importFromExtension(item: [String: String])

    /// Export library to specified format
    case exportLibrary(libraryID: UUID?, format: ExportFormat)

    // MARK: - Search

    /// Search online sources
    case search(query: String, source: String?, maxResults: Int?)

    /// Search within a specific arXiv category
    case searchCategory(category: String)

    /// Create a smart search in the exploration library
    case createSmartSearch(query: String, name: String?, sourceID: String?)

    // MARK: - Navigation

    /// Navigate to a specific view
    case navigate(target: NavigationTarget)

    /// Focus a specific area of the UI
    case focus(target: FocusTarget)

    // MARK: - Paper Actions

    /// Action on a specific paper
    case paper(citeKey: String, action: PaperAction)

    /// Action on currently selected papers
    case selectedPapers(action: SelectedPapersAction)

    // MARK: - Library Actions

    /// Action on a library
    case library(libraryID: UUID?, action: LibraryAction)

    // MARK: - Collection Actions

    /// Action on a collection
    case collection(collectionID: UUID, action: CollectionAction)

    // MARK: - Inbox Actions

    /// Action on inbox items
    case inbox(action: InboxAction)

    // MARK: - PDF Viewer Actions

    /// Action on the PDF viewer
    case pdf(action: PDFAction)

    // MARK: - App Actions

    /// General app actions
    case app(action: AppAction)
}

// MARK: - Navigation Target

/// Targets for navigation commands.
public enum NavigationTarget: String, Sendable, CaseIterable {
    case library = "library"
    case search = "search"
    case inbox = "inbox"
    case pdfTab = "pdf-tab"
    case bibtexTab = "bibtex-tab"
    case notesTab = "notes-tab"
}

// MARK: - Focus Target

/// Targets for focus commands.
public enum FocusTarget: String, Sendable, CaseIterable {
    case sidebar = "sidebar"
    case list = "list"
    case detail = "detail"
    case search = "search"
}

// MARK: - Paper Action

/// Actions that can be performed on a specific paper.
public enum PaperAction: Sendable {
    case open
    case openPDF
    case openNotes
    case openReferences
    case toggleRead
    case markRead
    case markUnread
    case delete
    case keep(libraryID: UUID?)
    case addToCollection(collectionID: UUID)
    case removeFromCollection(collectionID: UUID)
    case copyBibTeX
    case copyCitation
    case copyIdentifier
    case share
}

// MARK: - Selected Papers Action

/// Actions on currently selected papers.
public enum SelectedPapersAction: String, Sendable, CaseIterable {
    case open = "open"
    case toggleRead = "toggle-read"
    case markRead = "mark-read"
    case markUnread = "mark-unread"
    case markAllRead = "mark-all-read"
    case delete = "delete"
    case keep = "keep"
    case copy = "copy"
    case cut = "cut"
    case share = "share"
    case copyAsCitation = "copy-citation"
    case copyIdentifier = "copy-identifier"
}

// MARK: - Library Action

/// Actions on libraries.
public enum LibraryAction: String, Sendable, CaseIterable {
    case show = "show"
    case refresh = "refresh"
    case create = "create"
    case delete = "delete"
}

// MARK: - Collection Action

/// Actions on collections.
public enum CollectionAction: String, Sendable, CaseIterable {
    case show = "show"
    case addSelected = "add-selected"
    case removeSelected = "remove-selected"
}

// MARK: - Inbox Action

/// Actions on inbox items.
public enum InboxAction: String, Sendable, CaseIterable {
    case show = "show"
    case keep = "keep"
    case dismiss = "dismiss"
    case toggleStar = "toggle-star"
    case markRead = "mark-read"
    case markUnread = "mark-unread"
    case next = "next"
    case previous = "previous"
    case open = "open"
}

// MARK: - PDF Action

/// Actions on the PDF viewer.
public enum PDFAction: Sendable {
    case goToPage(page: Int)
    case pageDown
    case pageUp
    case zoomIn
    case zoomOut
    case actualSize
    case fitToWindow
}

// MARK: - App Action

/// General app actions.
public enum AppAction: String, Sendable, CaseIterable {
    case refresh = "refresh"
    case toggleSidebar = "toggle-sidebar"
    case toggleDetailPane = "toggle-detail-pane"
    case toggleUnreadFilter = "toggle-unread-filter"
    case togglePDFFilter = "toggle-pdf-filter"
    case showKeyboardShortcuts = "show-keyboard-shortcuts"
}

// MARK: - Export Format (Re-export for convenience)

public extension ExportFormat {
    /// Initialize from string
    init?(string: String) {
        switch string.lowercased() {
        case "bibtex", "bib": self = .bibtex
        case "ris": self = .ris
        case "csv": self = .csv
        default: return nil
        }
    }
}

// MARK: - URL Command Parser

/// Parses URL scheme commands into AutomationCommand values.
public struct URLCommandParser {

    public init() {}

    /// Parse a URL into an automation command.
    ///
    /// URL format: `imbib://<command>/<subcommand>?param1=value1&param2=value2`
    ///
    /// Examples:
    /// - `imbib://search?query=einstein&source=ads&max=50`
    /// - `imbib://paper/Einstein1905/open-pdf`
    /// - `imbib://navigate/inbox`
    /// - `imbib://selected/toggle-read`
    /// - `imbib://inbox/keep`
    /// - `imbib://pdf/go-to-page?page=5`
    public func parse(_ url: URL) throws -> AutomationCommand {
        guard url.scheme == "imbib" else {
            throw AutomationError.invalidScheme(url.scheme ?? "nil")
        }

        // Get path components (host is first path component for imbib:// URLs)
        var pathComponents = url.pathComponents.filter { $0 != "/" }

        // For URLs like imbib://search, host becomes the command
        if let host = url.host, !host.isEmpty {
            pathComponents.insert(host, at: 0)
        }

        guard let command = pathComponents.first else {
            throw AutomationError.missingCommand
        }

        let queryParams = parseQueryParams(url)

        switch command {
        case "search":
            // Check for subcommand: imbib://search/create-smart-search?...
            if pathComponents.count > 1 && pathComponents[1] == "create-smart-search" {
                return try parseCreateSmartSearchCommand(queryParams)
            }
            return try parseSearchCommand(queryParams)

        case "search-category":
            return try parseSearchCategoryCommand(queryParams)

        case "import":
            return try parseImportCommand(queryParams)

        case "export":
            return try parseExportCommand(queryParams)

        case "navigate", "nav":
            return try parseNavigateCommand(pathComponents, queryParams)

        case "focus":
            return try parseFocusCommand(pathComponents, queryParams)

        case "paper":
            return try parsePaperCommand(pathComponents, queryParams)

        case "selected":
            return try parseSelectedCommand(pathComponents, queryParams)

        case "library":
            return try parseLibraryCommand(pathComponents, queryParams)

        case "collection":
            return try parseCollectionCommand(pathComponents, queryParams)

        case "inbox":
            return try parseInboxCommand(pathComponents, queryParams)

        case "pdf":
            return try parsePDFCommand(pathComponents, queryParams)

        case "app":
            return try parseAppCommand(pathComponents, queryParams)

        default:
            throw AutomationError.unknownCommand(command)
        }
    }

    // MARK: - Query Parameter Parsing

    private func parseQueryParams(_ url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return [:]
        }
        var params: [String: String] = [:]
        for item in queryItems {
            params[item.name] = item.value ?? ""
        }
        return params
    }

    // MARK: - Command Parsers

    private func parseSearchCommand(_ params: [String: String]) throws -> AutomationCommand {
        guard let query = params["query"], !query.isEmpty else {
            throw AutomationError.missingParameter("query")
        }
        let source = params["source"]
        let maxResults = params["max"].flatMap { Int($0) }
        return .search(query: query, source: source, maxResults: maxResults)
    }

    private func parseSearchCategoryCommand(_ params: [String: String]) throws -> AutomationCommand {
        guard let category = params["category"], !category.isEmpty else {
            throw AutomationError.missingParameter("category")
        }
        return .searchCategory(category: category)
    }

    private func parseCreateSmartSearchCommand(_ params: [String: String]) throws -> AutomationCommand {
        guard let query = params["query"], !query.isEmpty else {
            throw AutomationError.missingParameter("query")
        }
        let name = params["name"]
        let sourceID = params["sourceID"]
        return .createSmartSearch(query: query, name: name, sourceID: sourceID)
    }

    private func parseImportCommand(_ params: [String: String]) throws -> AutomationCommand {
        // Check if this is a browser extension import (has sourceType parameter)
        if params["sourceType"] != nil {
            // Pass all parameters as the import item
            return .importFromExtension(item: params)
        }

        // Standard file/data import
        let format = params["format"] ?? "bibtex"
        let libraryID = params["library"].flatMap { UUID(uuidString: $0) }
        let filePath = params["file"]
        let base64Data = params["data"].flatMap { Data(base64Encoded: $0) }

        switch format.lowercased() {
        case "bibtex", "bib":
            return .importBibTeX(data: base64Data, filePath: filePath, libraryID: libraryID)
        case "ris":
            return .importRIS(data: base64Data, filePath: filePath, libraryID: libraryID)
        default:
            throw AutomationError.invalidParameter("format", format)
        }
    }

    private func parseExportCommand(_ params: [String: String]) throws -> AutomationCommand {
        let format = ExportFormat(string: params["format"] ?? "bibtex") ?? .bibtex
        let libraryID = params["library"].flatMap { UUID(uuidString: $0) }
        return .exportLibrary(libraryID: libraryID, format: format)
    }

    private func parseNavigateCommand(_ pathComponents: [String], _ params: [String: String]) throws -> AutomationCommand {
        let target: String
        if pathComponents.count > 1 {
            target = pathComponents[1]
        } else if let t = params["target"] {
            target = t
        } else {
            throw AutomationError.missingParameter("target")
        }

        guard let navTarget = NavigationTarget(rawValue: target) else {
            throw AutomationError.invalidParameter("target", target)
        }
        return .navigate(target: navTarget)
    }

    private func parseFocusCommand(_ pathComponents: [String], _ params: [String: String]) throws -> AutomationCommand {
        let target: String
        if pathComponents.count > 1 {
            target = pathComponents[1]
        } else if let t = params["target"] {
            target = t
        } else {
            throw AutomationError.missingParameter("target")
        }

        guard let focusTarget = FocusTarget(rawValue: target) else {
            throw AutomationError.invalidParameter("target", target)
        }
        return .focus(target: focusTarget)
    }

    private func parsePaperCommand(_ pathComponents: [String], _ params: [String: String]) throws -> AutomationCommand {
        guard pathComponents.count >= 3 else {
            throw AutomationError.missingParameter("citeKey or action")
        }

        let citeKey = pathComponents[1]
        let actionStr = pathComponents[2]

        let action: PaperAction
        switch actionStr {
        case "open": action = .open
        case "open-pdf": action = .openPDF
        case "open-notes": action = .openNotes
        case "open-references": action = .openReferences
        case "toggle-read": action = .toggleRead
        case "mark-read": action = .markRead
        case "mark-unread": action = .markUnread
        case "delete": action = .delete
        case "keep":
            let libraryID = params["library"].flatMap { UUID(uuidString: $0) }
            action = .keep(libraryID: libraryID)
        case "add-to-collection":
            guard let collectionIDStr = params["collection"],
                  let collectionID = UUID(uuidString: collectionIDStr) else {
                throw AutomationError.missingParameter("collection")
            }
            action = .addToCollection(collectionID: collectionID)
        case "remove-from-collection":
            guard let collectionIDStr = params["collection"],
                  let collectionID = UUID(uuidString: collectionIDStr) else {
                throw AutomationError.missingParameter("collection")
            }
            action = .removeFromCollection(collectionID: collectionID)
        case "copy-bibtex": action = .copyBibTeX
        case "copy-citation": action = .copyCitation
        case "copy-identifier": action = .copyIdentifier
        case "share": action = .share
        default:
            throw AutomationError.invalidParameter("action", actionStr)
        }

        return .paper(citeKey: citeKey, action: action)
    }

    private func parseSelectedCommand(_ pathComponents: [String], _ params: [String: String]) throws -> AutomationCommand {
        let actionStr: String
        if pathComponents.count > 1 {
            actionStr = pathComponents[1]
        } else if let a = params["action"] {
            actionStr = a
        } else {
            throw AutomationError.missingParameter("action")
        }

        guard let action = SelectedPapersAction(rawValue: actionStr) else {
            throw AutomationError.invalidParameter("action", actionStr)
        }
        return .selectedPapers(action: action)
    }

    private func parseLibraryCommand(_ pathComponents: [String], _ params: [String: String]) throws -> AutomationCommand {
        let actionStr: String
        if pathComponents.count > 1 {
            actionStr = pathComponents[1]
        } else if let a = params["action"] {
            actionStr = a
        } else {
            throw AutomationError.missingParameter("action")
        }

        guard let action = LibraryAction(rawValue: actionStr) else {
            throw AutomationError.invalidParameter("action", actionStr)
        }

        let libraryID = params["id"].flatMap { UUID(uuidString: $0) }
        return .library(libraryID: libraryID, action: action)
    }

    private func parseCollectionCommand(_ pathComponents: [String], _ params: [String: String]) throws -> AutomationCommand {
        guard let collectionIDStr = pathComponents.count > 1 ? pathComponents[1] : params["id"],
              let collectionID = UUID(uuidString: collectionIDStr) else {
            throw AutomationError.missingParameter("collection id")
        }

        let actionStr: String
        if pathComponents.count > 2 {
            actionStr = pathComponents[2]
        } else if let a = params["action"] {
            actionStr = a
        } else {
            throw AutomationError.missingParameter("action")
        }

        guard let action = CollectionAction(rawValue: actionStr) else {
            throw AutomationError.invalidParameter("action", actionStr)
        }

        return .collection(collectionID: collectionID, action: action)
    }

    private func parseInboxCommand(_ pathComponents: [String], _ params: [String: String]) throws -> AutomationCommand {
        let actionStr: String
        if pathComponents.count > 1 {
            actionStr = pathComponents[1]
        } else if let a = params["action"] {
            actionStr = a
        } else {
            // Default to show inbox
            actionStr = "show"
        }

        guard let action = InboxAction(rawValue: actionStr) else {
            throw AutomationError.invalidParameter("action", actionStr)
        }
        return .inbox(action: action)
    }

    private func parsePDFCommand(_ pathComponents: [String], _ params: [String: String]) throws -> AutomationCommand {
        let actionStr: String
        if pathComponents.count > 1 {
            actionStr = pathComponents[1]
        } else if let a = params["action"] {
            actionStr = a
        } else {
            throw AutomationError.missingParameter("action")
        }

        let action: PDFAction
        switch actionStr {
        case "go-to-page":
            guard let pageStr = params["page"], let page = Int(pageStr) else {
                throw AutomationError.missingParameter("page")
            }
            action = .goToPage(page: page)
        case "page-down": action = .pageDown
        case "page-up": action = .pageUp
        case "zoom-in": action = .zoomIn
        case "zoom-out": action = .zoomOut
        case "actual-size": action = .actualSize
        case "fit-to-window": action = .fitToWindow
        default:
            throw AutomationError.invalidParameter("action", actionStr)
        }

        return .pdf(action: action)
    }

    private func parseAppCommand(_ pathComponents: [String], _ params: [String: String]) throws -> AutomationCommand {
        let actionStr: String
        if pathComponents.count > 1 {
            actionStr = pathComponents[1]
        } else if let a = params["action"] {
            actionStr = a
        } else {
            throw AutomationError.missingParameter("action")
        }

        guard let action = AppAction(rawValue: actionStr) else {
            throw AutomationError.invalidParameter("action", actionStr)
        }
        return .app(action: action)
    }
}

// MARK: - Automation Error

/// Errors that can occur during automation command parsing or execution.
public enum AutomationError: LocalizedError, Sendable {
    case disabled
    case invalidScheme(String)
    case missingCommand
    case unknownCommand(String)
    case missingParameter(String)
    case invalidParameter(String, String)
    case executionFailed(String)
    case paperNotFound(String)
    case libraryNotFound(UUID)
    case collectionNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Automation API is disabled. Enable it in Settings > General."
        case .invalidScheme(let scheme):
            return "Invalid URL scheme '\(scheme)'. Expected 'imbib'."
        case .missingCommand:
            return "Missing command in URL."
        case .unknownCommand(let command):
            return "Unknown command '\(command)'."
        case .missingParameter(let param):
            return "Missing required parameter '\(param)'."
        case .invalidParameter(let param, let value):
            return "Invalid value '\(value)' for parameter '\(param)'."
        case .executionFailed(let reason):
            return "Command execution failed: \(reason)"
        case .paperNotFound(let citeKey):
            return "Paper not found: '\(citeKey)'"
        case .libraryNotFound(let id):
            return "Library not found: \(id)"
        case .collectionNotFound(let id):
            return "Collection not found: \(id)"
        }
    }
}
