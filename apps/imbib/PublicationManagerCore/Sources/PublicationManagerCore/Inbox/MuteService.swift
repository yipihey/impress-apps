//
//  MuteService.swift
//  PublicationManagerCore
//
//  Global mute service — filters papers by author, DOI, bibcode, venue, or arXiv category.
//  Extracted from InboxManager to support generalized feed collections.
//

import Foundation
import OSLog

// MARK: - Mute Service

/// Global service for managing muted items (authors, DOIs, venues, categories).
///
/// Mute rules are applied before papers are imported into any feed collection,
/// not just the Inbox. This service owns the mute list and provides filtering.
@MainActor
@Observable
public final class MuteService {

    // MARK: - Singleton

    public static let shared = MuteService()

    // MARK: - State

    /// All muted items
    public private(set) var mutedItems: [MutedItem] = []

    // MARK: - Properties

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    // MARK: - Initialization

    public init() {
        loadMutedItems()
    }

    // MARK: - Load

    /// Load all muted items from the store.
    private func loadMutedItems() {
        mutedItems = store.listMutedItems()
        Logger.inbox.debugCapture("MuteService loaded \(mutedItems.count) muted items", category: "mute")
    }

    /// Reload muted items (e.g., after a reset).
    public func reload() {
        loadMutedItems()
    }

    // MARK: - Mute Operations

    /// Mute an item (author, paper, venue, category).
    @discardableResult
    public func mute(type: MuteType, value: String) -> MutedItem? {
        Logger.inbox.infoCapture("Muting \(type.rawValue): \(value)", category: "mute")

        // Check if already muted
        if let existing = mutedItems.first(where: { $0.muteType == type.rawValue && $0.value == value }) {
            return existing
        }

        guard let item = store.createMutedItem(muteType: type.rawValue, value: value) else {
            Logger.inbox.errorCapture("Failed to create muted item", category: "mute")
            return nil
        }

        mutedItems.insert(item, at: 0)
        return item
    }

    /// Unmute an item.
    public func unmute(_ item: MutedItem) {
        Logger.inbox.infoCapture("Unmuting \(item.muteType): \(item.value)", category: "mute")
        store.deleteItem(id: item.id)
        mutedItems.removeAll { $0.id == item.id }
    }

    /// Get muted items by type.
    public func mutedItems(ofType type: MuteType) -> [MutedItem] {
        mutedItems.filter { $0.muteType == type.rawValue }
    }

    /// Clear all muted items.
    public func clearAllMutedItems() {
        Logger.inbox.warningCapture("Clearing all \(mutedItems.count) muted items", category: "mute")

        for item in mutedItems {
            store.deleteItem(id: item.id)
        }

        mutedItems = []
    }

    // MARK: - Filtering

    /// Check if a paper should be filtered out based on mute rules.
    public func shouldFilter(paper: any PaperRepresentable) -> Bool {
        shouldFilter(
            id: paper.id,
            authors: paper.authors,
            doi: paper.doi,
            venue: paper.venue,
            arxivID: paper.arxivID
        )
    }

    /// Check if a search result should be filtered out based on mute rules.
    public func shouldFilter(result: SearchResult) -> Bool {
        shouldFilter(
            id: result.id,
            authors: result.authors,
            doi: result.doi,
            venue: result.venue,
            arxivID: result.arxivID
        )
    }

    /// Core mute check with explicit parameters.
    public func shouldFilter(
        id: String,
        authors: [String],
        doi: String?,
        venue: String?,
        arxivID: String?
    ) -> Bool {
        for item in mutedItems {
            guard let muteType = MuteType(rawValue: item.muteType) else { continue }

            switch muteType {
            case .author:
                if authors.contains(where: { $0.lowercased().contains(item.value.lowercased()) }) {
                    return true
                }

            case .doi:
                if doi?.lowercased() == item.value.lowercased() {
                    return true
                }

            case .bibcode:
                if id.lowercased() == item.value.lowercased() {
                    return true
                }

            case .venue:
                if let venue = venue?.lowercased(), venue.contains(item.value.lowercased()) {
                    return true
                }

            case .arxivCategory:
                if let arxiv = arxivID, arxiv.lowercased().hasPrefix(item.value.lowercased()) {
                    return true
                }
            }
        }

        return false
    }
}
