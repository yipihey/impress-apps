//
//  main.swift
//  imbib-cli
//
//  A command-line interface for controlling the imbib app.
//
//  Created by Claude on 2026-01-09.
//

import ArgumentParser
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// imbib CLI - Control imbib from the command line.
///
/// This tool sends URL scheme commands to the imbib app.
/// Requires imbib to be running with automation enabled.
@main
struct ImbibCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imbib",
        abstract: "Control imbib from the command line",
        discussion: """
            This CLI sends URL scheme commands to the imbib app.
            Make sure imbib is running and automation is enabled in Settings > General.

            Examples:
              imbib search "dark matter"
              imbib list --library "My Papers" --unread
              imbib batch mark-read --filter unread
              imbib navigate inbox
              imbib selected toggle-read
              imbib paper Einstein1905 open-pdf
            """,
        version: "1.1.0",
        subcommands: [
            SearchCommand.self,
            ListCommand.self,
            BatchCommand.self,
            NavigateCommand.self,
            FocusCommand.self,
            PaperCommand.self,
            SelectedCommand.self,
            InboxCommand.self,
            PDFCommand.self,
            AppCommand.self,
            ImportCommand.self,
            ExportCommand.self,
            RawCommand.self
        ],
        defaultSubcommand: nil
    )
}

// MARK: - URL Launcher

/// Opens imbib:// URLs using the system.
enum URLLauncher {
    /// Open a URL scheme command.
    static func open(_ urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw CLIError.invalidURL(urlString)
        }

        #if canImport(AppKit)
        let workspace = NSWorkspace.shared
        let configuration = NSWorkspace.OpenConfiguration()

        try await workspace.open(url, configuration: configuration)
        #else
        throw CLIError.unsupportedPlatform
        #endif
    }

    /// Build and open a URL with the given path and query parameters.
    static func open(path: String, queryItems: [URLQueryItem] = []) async throws {
        var components = URLComponents()
        components.scheme = "imbib"
        components.host = path.components(separatedBy: "/").first ?? path

        // Handle paths like "paper/Einstein1905/open-pdf"
        let pathParts = path.components(separatedBy: "/")
        if pathParts.count > 1 {
            components.path = "/" + pathParts.dropFirst().joined(separator: "/")
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw CLIError.invalidURL(path)
        }

        try await open(url.absoluteString)
    }
}

// MARK: - CLI Error

enum CLIError: LocalizedError {
    case invalidURL(String)
    case unsupportedPlatform
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .unsupportedPlatform:
            return "This command is only supported on macOS"
        case .executionFailed(let reason):
            return "Command failed: \(reason)"
        }
    }
}

// MARK: - Search Command

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search for papers online",
        discussion: """
            Search academic databases for papers matching your query.

            Available sources:
              arxiv      - arXiv preprint server
              ads        - NASA ADS (astrophysics)
              crossref   - Crossref DOI database
              pubmed     - PubMed biomedical literature
              semantic   - Semantic Scholar
              openalex   - OpenAlex
              dblp       - DBLP computer science
              all        - Search all sources (default)

            Examples:
              imbib search "dark matter halos"
              imbib search "neural networks" --source arxiv --max 20
              imbib search "CRISPR" --source pubmed
              imbib search "2401.12345" --source arxiv  # Search by arXiv ID
              imbib search "10.1038/nature12373"        # Search by DOI
            """
    )

    @Argument(help: "Search query, arXiv ID, or DOI")
    var query: String

    @Option(name: .shortAndLong, help: "Source: arxiv, ads, crossref, pubmed, semantic, openalex, dblp, all")
    var source: String?

    @Option(name: .shortAndLong, help: "Maximum number of results (default: 20)")
    var max: Int?

    @Option(name: .long, help: "Year range start (e.g., 2020)")
    var yearFrom: Int?

    @Option(name: .long, help: "Year range end (e.g., 2024)")
    var yearTo: Int?

    @Option(name: .long, help: "Author name to filter by")
    var author: String?

    @Flag(name: .long, help: "Auto-import first result to library")
    var autoImport: Bool = false

    @Flag(name: .long, help: "Show results in interactive selection mode")
    var interactive: Bool = false

    func run() async throws {
        var items = [URLQueryItem(name: "query", value: query)]

        if let source = source {
            items.append(URLQueryItem(name: "source", value: source))
        }
        if let max = max {
            items.append(URLQueryItem(name: "max", value: String(max)))
        }
        if let yearFrom = yearFrom {
            items.append(URLQueryItem(name: "year-from", value: String(yearFrom)))
        }
        if let yearTo = yearTo {
            items.append(URLQueryItem(name: "year-to", value: String(yearTo)))
        }
        if let author = author {
            items.append(URLQueryItem(name: "author", value: author))
        }
        if autoImport {
            items.append(URLQueryItem(name: "auto-import", value: "true"))
        }
        if interactive {
            items.append(URLQueryItem(name: "interactive", value: "true"))
        }

        try await URLLauncher.open(path: "search", queryItems: items)

        // Print search summary
        var details: [String] = []
        if let source = source { details.append("source: \(source)") }
        if let max = max { details.append("max: \(max)") }
        if let author = author { details.append("author: \(author)") }
        if let yearFrom = yearFrom, let yearTo = yearTo {
            details.append("years: \(yearFrom)-\(yearTo)")
        } else if let yearFrom = yearFrom {
            details.append("from: \(yearFrom)")
        } else if let yearTo = yearTo {
            details.append("until: \(yearTo)")
        }

        let detailsStr = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        print("Searching for: \(query)\(detailsStr)")
    }
}

// MARK: - List Command

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List publications with filters",
        discussion: """
            Opens the library view with specified filters applied.
            Use filters to narrow down the displayed publications.

            Examples:
              imbib list                            # Show all publications
              imbib list --library "My Papers"      # Show specific library
              imbib list --collection "To Read"    # Show specific collection
              imbib list --unread                   # Show only unread papers
              imbib list --starred                  # Show only starred papers
              imbib list --has-pdf                  # Show papers with PDFs
            """
    )

    @Option(name: .shortAndLong, help: "Library name or ID")
    var library: String?

    @Option(name: .shortAndLong, help: "Collection name or ID")
    var collection: String?

    @Flag(name: .long, help: "Show only unread papers")
    var unread: Bool = false

    @Flag(name: .long, help: "Show only starred papers")
    var starred: Bool = false

    @Flag(name: [.customLong("has-pdf")], help: "Show only papers with PDFs")
    var hasPDF: Bool = false

    @Option(name: .shortAndLong, help: "Search query to filter results")
    var query: String?

    @Option(name: .long, help: "Sort by: date, title, author, year")
    var sort: String?

    @Flag(name: .long, help: "Sort in descending order")
    var descending: Bool = false

    func run() async throws {
        var items: [URLQueryItem] = []

        if let library = library {
            items.append(URLQueryItem(name: "library", value: library))
        }
        if let collection = collection {
            items.append(URLQueryItem(name: "collection", value: collection))
        }
        if unread {
            items.append(URLQueryItem(name: "filter", value: "unread"))
        }
        if starred {
            items.append(URLQueryItem(name: "filter", value: "starred"))
        }
        if hasPDF {
            items.append(URLQueryItem(name: "filter", value: "has-pdf"))
        }
        if let query = query {
            items.append(URLQueryItem(name: "query", value: query))
        }
        if let sort = sort {
            items.append(URLQueryItem(name: "sort", value: sort))
        }
        if descending {
            items.append(URLQueryItem(name: "order", value: "desc"))
        }

        try await URLLauncher.open(path: "list", queryItems: items)

        // Print summary of filters applied
        var filterDesc: [String] = []
        if let library = library { filterDesc.append("library: \(library)") }
        if let collection = collection { filterDesc.append("collection: \(collection)") }
        if unread { filterDesc.append("unread only") }
        if starred { filterDesc.append("starred only") }
        if hasPDF { filterDesc.append("with PDF") }
        if let query = query { filterDesc.append("query: \(query)") }

        if filterDesc.isEmpty {
            print("Listing all publications")
        } else {
            print("Listing publications: \(filterDesc.joined(separator: ", "))")
        }
    }
}

// MARK: - Batch Command

struct BatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "Perform batch operations on publications",
        discussion: """
            Perform bulk operations on publications matching a filter.
            This is useful for managing large libraries from the command line.

            Examples:
              imbib batch mark-read --filter unread    # Mark all unread as read
              imbib batch mark-unread --library "Papers"
              imbib batch delete --filter starred --confirm
              imbib batch move --collection "Archive" --target "Done"
            """
    )

    @Argument(help: "Action: mark-read, mark-unread, delete, move, add-to-collection, remove-from-collection, export")
    var action: String

    @Option(name: .shortAndLong, help: "Filter: unread, starred, has-pdf, no-pdf, all")
    var filter: String?

    @Option(name: .shortAndLong, help: "Library name or ID")
    var library: String?

    @Option(name: .shortAndLong, help: "Collection name or ID")
    var collection: String?

    @Option(name: .shortAndLong, help: "Target collection for move/add operations")
    var target: String?

    @Option(name: .shortAndLong, help: "Search query to select papers")
    var query: String?

    @Flag(name: .long, help: "Skip confirmation for destructive operations")
    var confirm: Bool = false

    func run() async throws {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "action", value: action)
        ]

        if let filter = filter {
            items.append(URLQueryItem(name: "filter", value: filter))
        }
        if let library = library {
            items.append(URLQueryItem(name: "library", value: library))
        }
        if let collection = collection {
            items.append(URLQueryItem(name: "collection", value: collection))
        }
        if let target = target {
            items.append(URLQueryItem(name: "target", value: target))
        }
        if let query = query {
            items.append(URLQueryItem(name: "query", value: query))
        }
        if confirm {
            items.append(URLQueryItem(name: "confirm", value: "true"))
        }

        try await URLLauncher.open(path: "batch", queryItems: items)

        // Print action summary
        var scope: [String] = []
        if let library = library { scope.append("library: \(library)") }
        if let collection = collection { scope.append("collection: \(collection)") }
        if let filter = filter { scope.append("filter: \(filter)") }
        if let query = query { scope.append("query: \(query)") }

        let scopeStr = scope.isEmpty ? "all papers" : scope.joined(separator: ", ")
        print("Batch \(action) on \(scopeStr)")
    }
}

// MARK: - Navigate Command

struct NavigateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "navigate",
        abstract: "Navigate to a view",
        aliases: ["nav", "go"]
    )

    @Argument(help: "Target: library, search, inbox, pdf-tab, bibtex-tab, notes-tab")
    var target: String

    func run() async throws {
        try await URLLauncher.open(path: "navigate/\(target)")
        print("Navigating to: \(target)")
    }
}

// MARK: - Focus Command

struct FocusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Focus a UI area"
    )

    @Argument(help: "Target: sidebar, list, detail, search")
    var target: String

    func run() async throws {
        try await URLLauncher.open(path: "focus/\(target)")
        print("Focusing: \(target)")
    }
}

// MARK: - Paper Command

struct PaperCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paper",
        abstract: "Perform action on a specific paper"
    )

    @Argument(help: "Cite key of the paper")
    var citeKey: String

    @Argument(help: "Action: open, open-pdf, open-notes, toggle-read, mark-read, mark-unread, delete, copy-bibtex, copy-citation, share")
    var action: String

    @Option(name: .long, help: "Library ID for keep action")
    var library: String?

    @Option(name: .long, help: "Collection ID for add-to/remove-from collection")
    var collection: String?

    func run() async throws {
        var items: [URLQueryItem] = []
        if let library = library {
            items.append(URLQueryItem(name: "library", value: library))
        }
        if let collection = collection {
            items.append(URLQueryItem(name: "collection", value: collection))
        }

        try await URLLauncher.open(path: "paper/\(citeKey)/\(action)", queryItems: items)
        print("Paper '\(citeKey)': \(action)")
    }
}

// MARK: - Selected Command

struct SelectedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "selected",
        abstract: "Perform action on selected papers"
    )

    @Argument(help: "Action: open, toggle-read, mark-read, mark-unread, mark-all-read, delete, keep, copy, cut, share, copy-citation, copy-identifier")
    var action: String

    func run() async throws {
        try await URLLauncher.open(path: "selected/\(action)")
        print("Selected papers: \(action)")
    }
}

// MARK: - Inbox Command

struct InboxCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inbox",
        abstract: "Inbox actions"
    )

    @Argument(help: "Action: show, keep, dismiss, toggle-star, mark-read, mark-unread, next, previous, open")
    var action: String = "show"

    func run() async throws {
        try await URLLauncher.open(path: "inbox/\(action)")
        print("Inbox: \(action)")
    }
}

// MARK: - PDF Command

struct PDFCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "PDF viewer actions"
    )

    @Argument(help: "Action: go-to-page, page-down, page-up, zoom-in, zoom-out, actual-size, fit-to-window")
    var action: String

    @Option(name: .shortAndLong, help: "Page number (for go-to-page)")
    var page: Int?

    func run() async throws {
        var items: [URLQueryItem] = []
        if let page = page {
            items.append(URLQueryItem(name: "page", value: String(page)))
        }

        try await URLLauncher.open(path: "pdf/\(action)", queryItems: items)
        print("PDF: \(action)")
    }
}

// MARK: - App Command

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "App-level actions"
    )

    @Argument(help: "Action: refresh, toggle-sidebar, toggle-detail-pane, toggle-unread-filter, toggle-pdf-filter, show-keyboard-shortcuts")
    var action: String

    func run() async throws {
        try await URLLauncher.open(path: "app/\(action)")
        print("App: \(action)")
    }
}

// MARK: - Import Command

struct ImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import BibTeX or RIS file"
    )

    @Argument(help: "File path to import")
    var file: String?

    @Option(name: .shortAndLong, help: "Format: bibtex, ris")
    var format: String = "bibtex"

    @Option(name: .shortAndLong, help: "Library ID to import into")
    var library: String?

    func run() async throws {
        var items: [URLQueryItem] = [URLQueryItem(name: "format", value: format)]
        if let file = file {
            items.append(URLQueryItem(name: "file", value: file))
        }
        if let library = library {
            items.append(URLQueryItem(name: "library", value: library))
        }

        try await URLLauncher.open(path: "import", queryItems: items)
        print("Importing \(format)...")
    }
}

// MARK: - Export Command

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export library or collection",
        discussion: """
            Export publications to various formats.

            Supported formats:
              bibtex  - BibTeX format (.bib)
              ris     - RIS format (.ris)
              mbox    - Email archive format (.mbox)
              json    - JSON format (.json)
              csv     - CSV spreadsheet (.csv)

            Examples:
              imbib export --format bibtex
              imbib export --library "My Papers" --output ~/Desktop/papers.bib
              imbib export --collection "Project A" --format ris
              imbib export --filter unread --format json
            """
    )

    @Option(name: .shortAndLong, help: "Format: bibtex, ris, mbox, json, csv")
    var format: String = "bibtex"

    @Option(name: .shortAndLong, help: "Library name or ID to export")
    var library: String?

    @Option(name: .shortAndLong, help: "Collection name or ID to export")
    var collection: String?

    @Option(name: .shortAndLong, help: "Output file path")
    var output: String?

    @Option(name: .long, help: "Filter: unread, starred, has-pdf")
    var filter: String?

    @Option(name: .shortAndLong, help: "Search query to filter exports")
    var query: String?

    @Flag(name: .long, help: "Include PDFs in export (for mbox format)")
    var includePDFs: Bool = false

    @Flag(name: .long, help: "Open export location after completion")
    var reveal: Bool = false

    func run() async throws {
        var items: [URLQueryItem] = [URLQueryItem(name: "format", value: format)]

        if let library = library {
            items.append(URLQueryItem(name: "library", value: library))
        }
        if let collection = collection {
            items.append(URLQueryItem(name: "collection", value: collection))
        }
        if let output = output {
            // Expand ~ to home directory
            let expandedPath = (output as NSString).expandingTildeInPath
            items.append(URLQueryItem(name: "output", value: expandedPath))
        }
        if let filter = filter {
            items.append(URLQueryItem(name: "filter", value: filter))
        }
        if let query = query {
            items.append(URLQueryItem(name: "query", value: query))
        }
        if includePDFs {
            items.append(URLQueryItem(name: "include-pdfs", value: "true"))
        }
        if reveal {
            items.append(URLQueryItem(name: "reveal", value: "true"))
        }

        try await URLLauncher.open(path: "export", queryItems: items)

        // Print export summary
        var scope: [String] = []
        if let library = library { scope.append("library: \(library)") }
        if let collection = collection { scope.append("collection: \(collection)") }
        if let filter = filter { scope.append("filter: \(filter)") }
        if let query = query { scope.append("query: \(query)") }

        let scopeStr = scope.isEmpty ? "all publications" : scope.joined(separator: ", ")
        let outputStr = output.map { " to \($0)" } ?? ""

        print("Exporting \(scopeStr) as \(format)\(outputStr)...")
    }
}

// MARK: - Raw Command

struct RawCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "raw",
        abstract: "Send raw URL command"
    )

    @Argument(help: "Raw URL path (e.g., 'search?query=test')")
    var path: String

    func run() async throws {
        let url = "imbib://\(path)"
        try await URLLauncher.open(url)
        print("Sent: \(url)")
    }
}
