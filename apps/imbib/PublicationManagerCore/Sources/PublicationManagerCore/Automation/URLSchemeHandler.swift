//
//  URLSchemeHandler.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation
import OSLog

private let automationLogger = Logger(subsystem: "com.imbib.app", category: "automation")

// MARK: - URL Scheme Handler

/// Handles automation commands received via URL schemes.
///
/// This actor parses incoming `imbib://` URLs and executes the corresponding
/// commands by posting to NotificationCenter.
///
/// ## Usage
///
/// Add to your SwiftUI App:
/// ```swift
/// WindowGroup {
///     ContentView()
/// }
/// .onOpenURL { url in
///     Task {
///         await URLSchemeHandler.shared.handle(url)
///     }
/// }
/// ```
///
/// ## URL Format
///
/// - `imbib://search?query=einstein&source=ads`
/// - `imbib://navigate/inbox`
/// - `imbib://paper/<citeKey>/open-pdf`
/// - `imbib://selected/toggle-read`
///
public actor URLSchemeHandler {
    public static let shared = URLSchemeHandler()

    private let parser = URLCommandParser()

    private init() {}

    /// Handle an incoming URL scheme request.
    ///
    /// - Parameter url: The URL to handle
    /// - Returns: The result of executing the command
    @discardableResult
    public func handle(_ url: URL) async -> AutomationResult {
        NSLog("[DEBUG] URLSchemeHandler.handle called with: %@", url.absoluteString)

        // Check if automation is enabled
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        NSLog("[DEBUG] Automation enabled: %d", isEnabled ? 1 : 0)
        guard isEnabled else {
            automationLogger.warning("Automation request rejected: API disabled. URL: \(url.absoluteString)")
            NSLog("[DEBUG] Automation disabled, rejecting")
            return .failure(command: url.host ?? "unknown", error: AutomationError.disabled.localizedDescription)
        }

        // Log if enabled
        if await AutomationSettingsStore.shared.shouldLog {
            automationLogger.info("Automation request: \(url.absoluteString)")
        }

        // Parse the command
        let command: AutomationCommand
        do {
            command = try parser.parse(url)
            NSLog("[DEBUG] Parsed command successfully")
        } catch {
            automationLogger.error("Failed to parse automation URL: \(error.localizedDescription)")
            NSLog("[DEBUG] Parse error: %@", error.localizedDescription)
            return .failure(command: url.host ?? "unknown", error: error.localizedDescription)
        }

        // Execute the command
        NSLog("[DEBUG] Executing command...")
        return await execute(command)
    }

    /// Execute an automation command.
    ///
    /// - Parameter command: The command to execute
    /// - Returns: The result of execution
    public func execute(_ command: AutomationCommand) async -> AutomationResult {
        switch command {

        // MARK: - File Operations

        case .importBibTeX(let data, let filePath, _):
            if data != nil || filePath != nil {
                // TODO: Support direct data import
                await postNotification(.importBibTeX)
            } else {
                await postNotification(.importBibTeX)
            }
            return .success(command: "importBibTeX")

        case .importRIS(let data, let filePath, _):
            if data != nil || filePath != nil {
                await postNotification(.importBibTeX) // Uses same handler
            } else {
                await postNotification(.importBibTeX)
            }
            return .success(command: "importRIS")

        case .importFromExtension(let item):
            NSLog("[DEBUG] importFromExtension case reached")
            // Convert [String: String] to [String: Any] for SafariImportHandler
            var importItem: [String: Any] = [:]
            for (key, value) in item {
                if key == "authors" {
                    // Authors are pipe-separated in the URL
                    importItem["authors"] = value.split(separator: "|").map(String.init)
                } else {
                    importItem[key] = value
                }
            }
            NSLog("[DEBUG] Import item: %@", importItem.description)
            do {
                try await SafariImportHandler.shared.processImportItem(importItem)
                NSLog("[DEBUG] Import succeeded")
                return .success(command: "importFromExtension", result: ["imported": AnyCodable(true)])
            } catch {
                NSLog("[DEBUG] Import failed: %@", error.localizedDescription)
                return .failure(command: "importFromExtension", error: error.localizedDescription)
            }

        case .exportLibrary(_, let format):
            await postNotification(.exportBibTeX, userInfo: ["format": format.rawValue])
            return .success(command: "exportLibrary")

        // MARK: - Search

        case .search(let query, let source, let maxResults):
            var userInfo: [String: Any] = ["query": query]
            if let source = source { userInfo["source"] = source }
            if let max = maxResults { userInfo["maxResults"] = max }
            await postNotification(.showSearch, userInfo: userInfo)
            return .success(command: "search", result: ["query": AnyCodable(query)])

        case .searchCategory(let category):
            await postNotification(.searchCategory, userInfo: ["category": category])
            return .success(command: "searchCategory", result: ["category": AnyCodable(category)])

        case .createSmartSearch(let query, let name, let sourceID):
            // Create smart search in exploration library (same as Safari extension)
            let truncatedQuery = String(query.prefix(40)) + (query.count > 40 ? "..." : "")
            let searchName = name ?? "Search: \(truncatedQuery)"
            let source = sourceID ?? "ads"

            let explorationLibrary = await MainActor.run {
                let manager = LibraryManager()
                return manager.getOrCreateExplorationLibrary()
            }

            let smartSearch = await MainActor.run {
                SmartSearchRepository.shared.create(
                    name: searchName,
                    query: query,
                    sourceIDs: [source],
                    library: explorationLibrary,
                    maxResults: 100
                )
            }

            // Create source manager for search execution
            let sourceManager = SourceManager()
            await sourceManager.registerBuiltInSources()

            // Auto-execute the search
            let provider = SmartSearchProvider(
                from: smartSearch,
                sourceManager: sourceManager,
                repository: PublicationRepository()
            )

            do {
                try await provider.refresh()
                await MainActor.run {
                    SmartSearchRepository.shared.markExecuted(smartSearch)
                }
            } catch {
                // Log but don't fail - search was created
                automationLogger.warning("Smart search auto-execute failed: \(error.localizedDescription)")
            }

            // Notify sidebar to refresh and navigate
            await MainActor.run {
                NotificationCenter.default.post(name: .explorationLibraryDidChange, object: nil)
                NotificationCenter.default.post(name: .navigateToSmartSearch, object: smartSearch.id)
            }

            return .success(command: "createSmartSearch", result: [
                "id": AnyCodable(smartSearch.id.uuidString),
                "name": AnyCodable(searchName),
                "query": AnyCodable(query)
            ])

        // MARK: - Navigation

        case .navigate(let target):
            switch target {
            case .library:
                await postNotification(.showLibrary)
            case .search:
                await postNotification(.showSearch)
            case .inbox:
                await postNotification(.showInbox)
            case .pdfTab:
                await postNotification(.showPDFTab)
            case .bibtexTab:
                await postNotification(.showBibTeXTab)
            case .notesTab:
                await postNotification(.showNotesTab)
            }
            return .success(command: "navigate", result: ["target": AnyCodable(target.rawValue)])

        case .focus(let target):
            switch target {
            case .sidebar:
                await postNotification(.focusSidebar)
            case .list:
                await postNotification(.focusList)
            case .detail:
                await postNotification(.focusDetail)
            case .search:
                await postNotification(.focusSearch)
            }
            return .success(command: "focus", result: ["target": AnyCodable(target.rawValue)])

        // MARK: - Paper Actions

        case .paper(let citeKey, let action):
            return await executePaperAction(citeKey: citeKey, action: action)

        case .selectedPapers(let action):
            return await executeSelectedPapersAction(action)

        // MARK: - Library Actions

        case .library(let libraryID, let action):
            switch action {
            case .show:
                if let id = libraryID {
                    await postNotification(.showLibrary, userInfo: ["libraryID": id.uuidString])
                } else {
                    await postNotification(.showLibrary)
                }
            case .refresh:
                await postNotification(.refreshData)
            case .create, .delete:
                // These require UI interaction, just show library
                await postNotification(.showLibrary)
            }
            return .success(command: "library", result: ["action": AnyCodable(action.rawValue)])

        // MARK: - Collection Actions

        case .collection(let collectionID, let action):
            switch action {
            case .show:
                await postNotification(.showLibrary, userInfo: ["collectionID": collectionID.uuidString])
            case .addSelected:
                await postNotification(.addToCollection, userInfo: ["collectionID": collectionID.uuidString])
            case .removeSelected:
                await postNotification(.removeFromCollection, userInfo: ["collectionID": collectionID.uuidString])
            }
            return .success(command: "collection", result: ["action": AnyCodable(action.rawValue)])

        // MARK: - Inbox Actions

        case .inbox(let action):
            return await executeInboxAction(action)

        // MARK: - PDF Actions

        case .pdf(let action):
            return await executePDFAction(action)

        // MARK: - App Actions

        case .app(let action):
            return await executeAppAction(action)
        }
    }

    // MARK: - Paper Actions

    private func executePaperAction(citeKey: String, action: PaperAction) async -> AutomationResult {
        // For paper-specific actions, we need to first select the paper
        // This is a simplified implementation - full implementation would look up the paper
        let userInfo: [String: Any] = ["citeKey": citeKey]

        switch action {
        case .open, .openPDF:
            await postNotification(.openSelectedPaper, userInfo: userInfo)
        case .openNotes:
            await postNotification(.showNotesTab, userInfo: userInfo)
        case .openReferences:
            await postNotification(.openReferences, userInfo: userInfo)
        case .toggleRead:
            await postNotification(.toggleReadStatus, userInfo: userInfo)
        case .markRead:
            await postNotification(.toggleReadStatus, userInfo: userInfo.merging(["markAs": "read"]) { _, new in new })
        case .markUnread:
            await postNotification(.toggleReadStatus, userInfo: userInfo.merging(["markAs": "unread"]) { _, new in new })
        case .delete:
            await postNotification(.deleteSelectedPapers, userInfo: userInfo)
        case .keep(let libraryID):
            var info = userInfo
            if let id = libraryID { info["libraryID"] = id.uuidString }
            await postNotification(.keepToLibrary, userInfo: info)
        case .addToCollection(let collectionID):
            await postNotification(.addToCollection, userInfo: userInfo.merging(["collectionID": collectionID.uuidString]) { _, new in new })
        case .removeFromCollection(let collectionID):
            await postNotification(.removeFromCollection, userInfo: userInfo.merging(["collectionID": collectionID.uuidString]) { _, new in new })
        case .copyBibTeX:
            await postNotification(.copyPublications, userInfo: userInfo)
        case .copyCitation:
            await postNotification(.copyAsCitation, userInfo: userInfo)
        case .copyIdentifier:
            await postNotification(.copyIdentifier, userInfo: userInfo)
        case .share:
            await postNotification(.sharePapers, userInfo: userInfo)
        }

        return .success(command: "paper", result: ["citeKey": AnyCodable(citeKey)])
    }

    // MARK: - Selected Papers Actions

    private func executeSelectedPapersAction(_ action: SelectedPapersAction) async -> AutomationResult {
        switch action {
        case .open:
            await postNotification(.openSelectedPaper)
        case .toggleRead:
            await postNotification(.toggleReadStatus)
        case .markRead:
            await postNotification(.toggleReadStatus, userInfo: ["markAs": "read"])
        case .markUnread:
            await postNotification(.toggleReadStatus, userInfo: ["markAs": "unread"])
        case .markAllRead:
            await postNotification(.markAllAsRead)
        case .delete:
            await postNotification(.deleteSelectedPapers)
        case .keep:
            await postNotification(.keepToLibrary)
        case .copy:
            await postNotification(.copyPublications)
        case .cut:
            await postNotification(.cutPublications)
        case .share:
            await postNotification(.sharePapers)
        case .copyAsCitation:
            await postNotification(.copyAsCitation)
        case .copyIdentifier:
            await postNotification(.copyIdentifier)
        }

        return .success(command: "selected", result: ["action": AnyCodable(action.rawValue)])
    }

    // MARK: - Inbox Actions

    private func executeInboxAction(_ action: InboxAction) async -> AutomationResult {
        switch action {
        case .show:
            await postNotification(.showInbox)
        case .keep:
            await postNotification(.inboxKeep)
        case .dismiss:
            await postNotification(.inboxDismiss)
        case .toggleStar:
            await postNotification(.inboxToggleStar)
        case .markRead:
            await postNotification(.inboxMarkRead)
        case .markUnread:
            await postNotification(.inboxMarkUnread)
        case .next:
            await postNotification(.inboxNextItem)
        case .previous:
            await postNotification(.inboxPreviousItem)
        case .open:
            await postNotification(.inboxOpenItem)
        }

        return .success(command: "inbox", result: ["action": AnyCodable(action.rawValue)])
    }

    // MARK: - PDF Actions

    private func executePDFAction(_ action: PDFAction) async -> AutomationResult {
        switch action {
        case .goToPage(let page):
            await postNotification(.pdfGoToPage, userInfo: ["page": page])
            return .success(command: "pdf", result: ["action": AnyCodable("goToPage"), "page": AnyCodable(page)])
        case .pageDown:
            await postNotification(.pdfPageDown)
        case .pageUp:
            await postNotification(.pdfPageUp)
        case .zoomIn:
            await postNotification(.pdfZoomIn)
        case .zoomOut:
            await postNotification(.pdfZoomOut)
        case .actualSize:
            await postNotification(.pdfActualSize)
        case .fitToWindow:
            await postNotification(.pdfFitToWindow)
        }

        return .success(command: "pdf")
    }

    // MARK: - App Actions

    private func executeAppAction(_ action: AppAction) async -> AutomationResult {
        switch action {
        case .refresh:
            await postNotification(.refreshData)
        case .toggleSidebar:
            await postNotification(.toggleSidebar)
        case .toggleDetailPane:
            await postNotification(.toggleDetailPane)
        case .toggleUnreadFilter:
            await postNotification(.toggleUnreadFilter)
        case .togglePDFFilter:
            await postNotification(.togglePDFFilter)
        case .showKeyboardShortcuts:
            await postNotification(.showKeyboardShortcuts)
        }

        return .success(command: "app", result: ["action": AnyCodable(action.rawValue)])
    }

    // MARK: - Notification Posting

    @MainActor
    private func postNotification(_ name: Notification.Name, userInfo: [String: Any]? = nil) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
        if Task.isCancelled { return }
    }
}

// MARK: - Convenience URL Builder

/// Build automation URLs programmatically.
public struct AutomationURLBuilder {

    public static let scheme = "imbib"

    /// Build a search URL
    public static func search(query: String, source: String? = nil, maxResults: Int? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "search"
        var queryItems = [URLQueryItem(name: "query", value: query)]
        if let source = source {
            queryItems.append(URLQueryItem(name: "source", value: source))
        }
        if let max = maxResults {
            queryItems.append(URLQueryItem(name: "max", value: String(max)))
        }
        components.queryItems = queryItems
        return components.url
    }

    /// Build a navigate URL
    public static func navigate(to target: NavigationTarget) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "navigate"
        components.path = "/\(target.rawValue)"
        return components.url
    }

    /// Build a paper action URL
    public static func paper(_ citeKey: String, action: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "paper"
        components.path = "/\(citeKey)/\(action)"
        return components.url
    }

    /// Build a selected papers action URL
    public static func selected(action: SelectedPapersAction) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "selected"
        components.path = "/\(action.rawValue)"
        return components.url
    }

    /// Build an inbox action URL
    public static func inbox(action: InboxAction) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "inbox"
        components.path = "/\(action.rawValue)"
        return components.url
    }

    /// Build an export URL
    public static func export(format: ExportFormat = .bibtex, libraryID: UUID? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "export"
        var queryItems = [URLQueryItem(name: "format", value: format.rawValue)]
        if let id = libraryID {
            queryItems.append(URLQueryItem(name: "library", value: id.uuidString))
        }
        components.queryItems = queryItems
        return components.url
    }
}
