#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  TabSidebarTypes.swift
//  imbib
//
//  Created by Claude on 2026-02-06.
//

import Foundation
import SwiftUI

// MARK: - Notification Names

extension NSNotification.Name {
    /// Posted by SectionContentView when batch PDF download is requested.
    /// userInfo: ["publicationIDs": [UUID], "libraryID": UUID]
    public static let showBatchDownload = NSNotification.Name("showBatchDownload")
}

/// Tab selection for the sidebarAdaptable TabView.
///
/// Each case maps to a tab or tab within a section in the TabView.
/// Uses value types (UUIDs, strings) rather than Core Data objects
/// so the enum is Hashable without issues.
public enum ImbibTab: Hashable {
    case inbox
    case library(UUID)
    case sharedLibrary(UUID)
    case scixLibrary(UUID)
    case searchForm(SearchFormType)
    case exploration(UUID)
    case collection(UUID)            // Collection in a regular library
    case explorationCollection(UUID) // Collection in exploration library
    case inboxFeed(UUID)             // Smart search with feedsToInbox
    case inboxCollection(UUID)       // Collection in the inbox library
    case libraryFeed(UUID)           // Auto-refreshing feed in a non-inbox library
    case flagged(String?)     // nil = any flag, String = FlagColor.rawValue
    case allArtifacts
    case artifactType(String)   // ArtifactType.rawValue
    case dismissed
    case citedInManuscripts   // pseudo smart library — papers cited in any imprint manuscript
    case recent               // papers the user viewed or added by hand (never automated ingest)
    case reviewQueue          // pending agent review-requests from the shared impress store

    // Journal pipeline (per ADR-0011 D8)
    case journalAll                                  // root: all manuscripts in any status
    case journalByStatus(JournalManuscriptStatus)    // smart-collection-style filter
    case journalSubmissions                          // pending submissions inbox
    case manuscript(String)                          // detail view for a manuscript by ID
    case manuscriptFolder(String)                    // user folder (manuscript-collection UUID)
    case addFeed                 // Navigate to search form picker for feed creation
    case addLibraryFeed(UUID)    // Navigate to feed creation for a specific library
    case editFeed(UUID)          // Navigate to search form to edit an existing feed
}

// MARK: - Content Routes

/// Declarative route for the main imbib content area.
///
/// The sidebar resolves to one of these value routes, and
/// `SectionContentView` renders the route. Keeping this as a small value type
/// makes SwiftUI identity, search mode, and future route additions explicit
/// instead of scattering them through view-body switches.
public enum ImbibContentRoute: Equatable {
    case publicationList(PublicationSource)
    case searchForm(ImbibSearchFormRoute)
    case artifacts(ArtifactType?)
    case reviewQueue
    case feedFormPicker
    case journal(ImbibJournalRoute)

    /// Stable key for selection clearing and SwiftUI cache boundaries.
    public var stableID: String {
        switch self {
        case .publicationList(let source):
            return "source-\(source.viewID)"
        case .searchForm(let route):
            return "search-\(route.stableID)"
        case .artifacts(let type):
            return "artifacts-\(type?.rawValue ?? "all")"
        case .reviewQueue:
            return "reviewQueue"
        case .feedFormPicker:
            return "feedFormPicker"
        case .journal(let route):
            return "journal-\(route.stableID)"
        }
    }

    public var publicationSource: PublicationSource? {
        if case .publicationList(let source) = self { return source }
        return nil
    }

    public var isSearchForm: Bool {
        if case .searchForm = self { return true }
        return false
    }

    public var isArtifactRoute: Bool {
        if case .artifacts = self { return true }
        return false
    }
}

public struct ImbibSearchFormRoute: Equatable {
    public let formType: SearchFormType
    public let mode: SearchFormMode
    public let editingFeedID: UUID?

    public init(
        formType: SearchFormType,
        mode: SearchFormMode,
        editingFeedID: UUID? = nil
    ) {
        self.formType = formType
        self.mode = mode
        self.editingFeedID = editingFeedID
    }

    public var stableID: String {
        var parts = [formType.rawValue, mode.routeKey]
        if let editingFeedID {
            parts.append("edit-\(editingFeedID.uuidString)")
        }
        return parts.joined(separator: "-")
    }
}

public enum ImbibJournalRoute: Equatable {
    case submissions
    case all
    case status(JournalManuscriptStatus)
    case manuscript(String)
    case folder(String)

    public var stableID: String {
        switch self {
        case .submissions:
            return "submissions"
        case .all:
            return "all"
        case .status(let status):
            return "status-\(status.rawValue)"
        case .manuscript(let id):
            return "manuscript-\(id)"
        case .folder(let id):
            return "folder-\(id)"
        }
    }
}

extension ImbibTab {
    public var journalRoute: ImbibJournalRoute? {
        switch self {
        case .journalSubmissions:
            return .submissions
        case .journalAll:
            return .all
        case .journalByStatus(let status):
            return .status(status)
        case .manuscript(let id):
            return .manuscript(id)
        case .manuscriptFolder(let id):
            return .folder(id)
        default:
            return nil
        }
    }
}

extension SearchFormMode {
    var routeKey: String {
        switch self {
        case .librarySmartSearch(let id, _):
            return "librarySmartSearch-\(id.uuidString)"
        case .inboxFeed:
            return "inboxFeed"
        case .libraryFeed(let id, _):
            return "libraryFeed-\(id.uuidString)"
        case .explorationSearch:
            return "explorationSearch"
        }
    }
}

// MARK: - Flag Counts

/// Sidebar flag counts for badge display
struct FlagCounts {
    var total: Int = 0
    var byColor: [String: Int] = [:]

    static let empty = FlagCounts()
}

#endif
