//
//  ShareExtensionView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI

/// SwiftUI view for the share extension dialog.
///
/// Displays either a smart search creation form or paper import form based on
/// the type of URL being shared (ADS or arXiv). When a page title is provided
/// (via JavaScript preprocessing), it's used as the clean query for smart searches.
public struct ShareExtensionView: View {

    // MARK: - Parsed URL Type

    /// Unified type for parsed URLs from any supported source
    enum ParsedURLType {
        case paper(identifier: String, sourceID: String, label: String)
        case search(query: String, title: String?, sourceID: String)
        case categoryFeed(category: String, sourceID: String)
        case docsSelection(query: String)
    }

    // MARK: - Properties

    /// The URL being shared
    public let sharedURL: URL

    /// The page title extracted via JavaScript preprocessing
    /// For ADS search pages, this contains the clean query
    public let pageTitle: String?

    /// Callback when user confirms the action
    public let onConfirm: (ShareExtensionService.SharedItem) -> Void

    /// Callback when user cancels
    public let onCancel: () -> Void

    // MARK: - State

    @State private var parsedURL: ParsedURLType?
    @State private var smartSearchName: String = ""
    @State private var smartSearchQuery: String = ""
    @State private var selectedLibraryID: UUID?
    @State private var addToInbox: Bool = true
    @State private var isProcessing: Bool = false

    // MARK: - Environment

    private let availableLibraries: [SharedLibraryInfo]

    // MARK: - Initialization

    public init(
        sharedURL: URL,
        pageTitle: String? = nil,
        availableLibraries: [SharedLibraryInfo] = [],
        onConfirm: @escaping (ShareExtensionService.SharedItem) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.sharedURL = sharedURL
        self.pageTitle = pageTitle
        self.availableLibraries = availableLibraries.isEmpty
            ? ShareExtensionService.shared.getAvailableLibraries()
            : availableLibraries
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if let urlType = parsedURL {
                switch urlType {
                case .search(let query, let title, _):
                    smartSearchForm(query: query, suggestedTitle: title)
                case .paper(let identifier, _, let label):
                    paperImportForm(identifier: identifier, label: label)
                case .categoryFeed(let category, _):
                    categoryFeedForm(category: category)
                case .docsSelection(let query):
                    docsSelectionForm(query: query)
                }
            } else {
                invalidURLView
            }
        }
        .onAppear {
            parsedURL = parseSharedURL(sharedURL)
            if case .search(let urlQuery, _, _) = parsedURL {
                // If we have a page title from JavaScript preprocessing, use it as the query
                if let title = pageTitle, !title.isEmpty {
                    smartSearchName = title
                    smartSearchQuery = title
                } else {
                    smartSearchName = urlQuery
                    smartSearchQuery = urlQuery
                }
            } else if case .categoryFeed(let category, _) = parsedURL {
                // For category feeds, create a descriptive name
                smartSearchName = "arXiv \(category)"
                smartSearchQuery = "cat:\(category)"
            }
            // Default to first library
            selectedLibraryID = availableLibraries.first(where: { $0.isDefault })?.id
                ?? availableLibraries.first?.id
        }
    }

    // MARK: - URL Parsing

    /// Parse URL to unified type supporting both ADS and arXiv
    private func parseSharedURL(_ url: URL) -> ParsedURLType? {
        // Try ADS first
        if let adsType = ADSURLParser.parse(url) {
            switch adsType {
            case .paper(let bibcode):
                return .paper(identifier: bibcode, sourceID: "ads", label: "ADS Bibcode")
            case .search(let query, let title):
                return .search(query: query, title: title, sourceID: "ads")
            case .docsSelection(let query):
                return .docsSelection(query: query)
            }
        }

        // Try arXiv
        if let arxivType = ArXivURLParser.parse(url) {
            switch arxivType {
            case .paper(let arxivID):
                return .paper(identifier: arxivID, sourceID: "arxiv", label: "arXiv ID")
            case .pdf(let arxivID):
                return .paper(identifier: arxivID, sourceID: "arxiv", label: "arXiv ID")
            case .search(let query, let title):
                return .search(query: query, title: title, sourceID: "arxiv")
            case .categoryList(let category, _):
                return .categoryFeed(category: category, sourceID: "arxiv")
            }
        }

        return nil
    }

    // MARK: - Smart Search Form

    private func smartSearchForm(query: String, suggestedTitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Label("Create Smart Search", systemImage: "magnifyingglass.circle")
                .font(.headline)

            // Name field
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Smart Search Name", text: $smartSearchName)
                    .textFieldStyle(.roundedBorder)
            }

            // Query preview (read-only) - show the actual query that will be used
            VStack(alignment: .leading, spacing: 4) {
                Text("Query")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(smartSearchQuery)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
            }

            // Info text - searches from share extension go to Exploration
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Search will appear in Exploration section")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            Spacer()

            // Buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    confirmSmartSearch()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(smartSearchName.isEmpty || isProcessing)
            }
        }
        .padding()
        .frame(minWidth: 300, minHeight: 220)
    }

    // MARK: - Paper Import Form

    private func paperImportForm(identifier: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Label("Import Paper", systemImage: "doc.badge.plus")
                .font(.headline)

            // Identifier display
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(identifier)
                    .font(.system(.body, design: .monospaced))
            }

            // Destination
            VStack(alignment: .leading, spacing: 8) {
                Text("Destination")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Toggle("Add to Inbox", isOn: $addToInbox)

                if !addToInbox && !availableLibraries.isEmpty {
                    Picker("Library", selection: $selectedLibraryID) {
                        ForEach(availableLibraries) { library in
                            Text(library.name).tag(library.id as UUID?)
                        }
                    }
                    .labelsHidden()
                    #if os(macOS)
                    .pickerStyle(.menu)
                    #endif
                }
            }

            Spacer()

            // Buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Import") {
                    confirmPaperImport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isProcessing)
            }
        }
        .padding()
        .frame(minWidth: 300, minHeight: 200)
    }

    // MARK: - Category Feed Form

    private func categoryFeedForm(category: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Label("Follow arXiv Category", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)

            // Category display
            VStack(alignment: .leading, spacing: 4) {
                Text("Category")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(category)
                    .font(.system(.title3, design: .monospaced))
                    .fontWeight(.medium)
            }

            // Name field
            VStack(alignment: .leading, spacing: 4) {
                Text("Feed Name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Feed Name", text: $smartSearchName)
                    .textFieldStyle(.roundedBorder)
            }

            // Info text - category feeds from share extension go to Exploration
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Feed will appear in Exploration section")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            Spacer()

            // Buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Follow") {
                    confirmSmartSearch()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(smartSearchName.isEmpty || isProcessing)
            }
        }
        .padding()
        .frame(minWidth: 300, minHeight: 250)
    }

    // MARK: - Docs Selection Form

    /// Form for importing papers from a temporary ADS selection (docs() URL).
    /// Always imports to Inbox - no naming or library picker needed.
    private func docsSelectionForm(query: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Label("Import Selected Papers", systemImage: "square.and.arrow.down.on.square")
                .font(.headline)

            // Info text
            Text("This will import all papers from your ADS selection to Inbox.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Query display (truncated hash)
            VStack(alignment: .leading, spacing: 4) {
                Text("Selection")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(query)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Import to Inbox") {
                    confirmDocsSelection(query: query)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isProcessing)
            }
        }
        .padding()
        .frame(minWidth: 300, minHeight: 200)
    }

    // MARK: - Invalid URL View

    private var invalidURLView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("Unsupported URL")
                .font(.headline)

            Text("This URL is not a recognized ADS or arXiv URL.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(sharedURL.absoluteString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Button("Close") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(minWidth: 300, minHeight: 200)
    }

    // MARK: - Actions

    private func confirmSmartSearch() {
        isProcessing = true

        // Store the query in the name field (for the main app to create the smart search)
        // The main app will use ADSURLParser to get the URL query, but we override with pageTitle
        let item = ShareExtensionService.SharedItem(
            url: sharedURL,
            type: .smartSearch,
            name: smartSearchName,
            query: smartSearchQuery,
            libraryID: selectedLibraryID,
            createdAt: Date()
        )

        onConfirm(item)
    }

    private func confirmPaperImport() {
        isProcessing = true

        let item = ShareExtensionService.SharedItem(
            url: sharedURL,
            type: .paper,
            name: nil,
            query: nil,
            libraryID: addToInbox ? nil : selectedLibraryID,
            createdAt: Date()
        )

        onConfirm(item)
    }

    private func confirmDocsSelection(query: String) {
        isProcessing = true

        let item = ShareExtensionService.SharedItem(
            url: sharedURL,
            type: .docsSelection,
            name: nil,
            query: query,
            libraryID: nil,  // Always to Inbox
            createdAt: Date()
        )

        onConfirm(item)
    }
}

// MARK: - Preview

#Preview("Smart Search URL") {
    ShareExtensionView(
        sharedURL: URL(string: "https://ui.adsabs.harvard.edu/search/q=author%3AAbel%2CTom")!,
        pageTitle: "author:Abel,Tom property:article property:refereed",
        availableLibraries: [
            SharedLibraryInfo(id: UUID(), name: "Main Library", isDefault: true),
            SharedLibraryInfo(id: UUID(), name: "Project Alpha", isDefault: false)
        ],
        onConfirm: { item in
            print("Confirmed: \(item)")
        },
        onCancel: {
            print("Cancelled")
        }
    )
}

#Preview("Paper URL") {
    ShareExtensionView(
        sharedURL: URL(string: "https://ui.adsabs.harvard.edu/abs/2024ApJ...123..456B/abstract")!,
        availableLibraries: [
            SharedLibraryInfo(id: UUID(), name: "Main Library", isDefault: true)
        ],
        onConfirm: { item in
            print("Confirmed: \(item)")
        },
        onCancel: {
            print("Cancelled")
        }
    )
}

#Preview("Invalid URL") {
    ShareExtensionView(
        sharedURL: URL(string: "https://example.com")!,
        availableLibraries: [],
        onConfirm: { _ in },
        onCancel: {}
    )
}

#Preview("arXiv Paper URL") {
    ShareExtensionView(
        sharedURL: URL(string: "https://arxiv.org/abs/2301.12345")!,
        availableLibraries: [
            SharedLibraryInfo(id: UUID(), name: "Main Library", isDefault: true)
        ],
        onConfirm: { item in
            print("Confirmed: \(item)")
        },
        onCancel: {
            print("Cancelled")
        }
    )
}

#Preview("arXiv Category Feed") {
    ShareExtensionView(
        sharedURL: URL(string: "https://arxiv.org/list/cs.LG/recent")!,
        availableLibraries: [
            SharedLibraryInfo(id: UUID(), name: "Main Library", isDefault: true),
            SharedLibraryInfo(id: UUID(), name: "ML Papers", isDefault: false)
        ],
        onConfirm: { item in
            print("Confirmed: \(item)")
        },
        onCancel: {
            print("Cancelled")
        }
    )
}

#Preview("arXiv Search URL") {
    ShareExtensionView(
        sharedURL: URL(string: "https://arxiv.org/search/?query=transformer+attention&searchtype=all")!,
        availableLibraries: [
            SharedLibraryInfo(id: UUID(), name: "Main Library", isDefault: true)
        ],
        onConfirm: { item in
            print("Confirmed: \(item)")
        },
        onCancel: {
            print("Cancelled")
        }
    )
}
