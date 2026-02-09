//
//  TabSidebarTypes.swift
//  imbib
//
//  Created by Claude on 2026-02-06.
//

import Foundation
import SwiftUI
import PublicationManagerCore

// MARK: - Notification Names

extension NSNotification.Name {
    /// Posted by SectionContentView when batch PDF download is requested.
    /// userInfo: ["publications": [CDPublication], "libraryID": UUID]
    static let showBatchDownload = NSNotification.Name("showBatchDownload")
}

/// Tab selection for the sidebarAdaptable TabView.
///
/// Each case maps to a tab or tab within a section in the TabView.
/// Uses value types (UUIDs, strings) rather than Core Data objects
/// so the enum is Hashable without issues.
enum ImbibTab: Hashable {
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
    case flagged(String?)     // nil = any flag, String = FlagColor.rawValue
    case dismissed
}

// MARK: - Flag Counts

/// Sidebar flag counts for badge display
struct FlagCounts {
    var total: Int = 0
    var byColor: [String: Int] = [:]

    static let empty = FlagCounts()
}

// MARK: - Shareable Item (iCloud Sharing)

/// Represents an item that can be shared via iCloud
public enum ShareableItem: Identifiable {
    case library(CDLibrary)
    case collection(CDCollection)

    public var id: String {
        switch self {
        case .library(let lib): return "library-\(lib.id)"
        case .collection(let col): return "collection-\(col.id)"
        }
    }
}
