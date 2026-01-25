//
//  SearchFormStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-14.
//

import Foundation

// MARK: - Search Form Type

/// Types of search forms available in the sidebar
public enum SearchFormType: String, CaseIterable, Codable, Identifiable, Equatable, Sendable {
    case adsModern = "ads-modern"
    case adsClassic = "ads-classic"
    case adsPaper = "ads-paper"
    case adsVagueMemory = "ads-vague-memory"
    case arxivAdvanced = "arxiv-advanced"
    case arxivFeed = "arxiv-feed"
    case arxivGroupFeed = "arxiv-group-feed"
    case openalex = "openalex"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .adsModern: return "ADS Modern"
        case .adsClassic: return "ADS Classic"
        case .adsPaper: return "ADS Paper"
        case .adsVagueMemory: return "Vague Memory Search"
        case .arxivAdvanced: return "arXiv Advanced"
        case .arxivFeed: return "arXiv Feed"
        case .arxivGroupFeed: return "Group arXiv Feed"
        case .openalex: return "OpenAlex"
        }
    }

    public var icon: String {
        switch self {
        case .adsModern: return "magnifyingglass"
        case .adsClassic: return "list.bullet.rectangle"
        case .adsPaper: return "doc.text.magnifyingglass"
        case .adsVagueMemory: return "brain.head.profile"
        case .arxivAdvanced: return "text.magnifyingglass"
        case .arxivFeed: return "antenna.radiowaves.left.and.right"
        case .arxivGroupFeed: return "person.3.fill"
        case .openalex: return "book.pages"
        }
    }

    public var description: String {
        switch self {
        case .adsModern: return "Single search box with field syntax"
        case .adsClassic: return "Multi-field form (authors, title, abstract, year)"
        case .adsPaper: return "Find papers by bibcode, DOI, or arXiv ID"
        case .adsVagueMemory: return "Find papers from imperfect memories using fuzzy matching"
        case .arxivAdvanced: return "Multi-field search with category filters"
        case .arxivFeed: return "Subscribe to arXiv categories"
        case .arxivGroupFeed: return "Monitor multiple authors in selected categories"
        case .openalex: return "240M+ scholarly works with OA status and citations"
        }
    }

    /// Whether this form type requires ADS API credentials to be shown
    public var requiresADSCredentials: Bool {
        switch self {
        case .adsVagueMemory:
            return true
        default:
            return false
        }
    }
}

// MARK: - Search Form Order Store

/// Persists the user's preferred order and visibility of search forms
public actor SearchFormStore {

    // MARK: - Singleton

    public static let shared = SearchFormStore()

    // MARK: - Properties

    private let orderKey = "searchFormOrder"
    private let hiddenKey = "searchFormHidden"
    private var cachedOrder: [SearchFormType]?
    private var cachedHidden: Set<SearchFormType>?

    // MARK: - Default Values

    public static let defaultOrder: [SearchFormType] = [.adsModern, .adsClassic, .adsPaper, .adsVagueMemory, .arxivAdvanced, .arxivFeed, .arxivGroupFeed]

    // MARK: - Order Methods

    /// Get the current form order
    public func order() -> [SearchFormType] {
        if let cached = cachedOrder {
            return cached
        }

        guard let data = UserDefaults.standard.data(forKey: orderKey),
              let decoded = try? JSONDecoder().decode([SearchFormType].self, from: data) else {
            cachedOrder = Self.defaultOrder
            return Self.defaultOrder
        }

        // Ensure all form types are present (in case new ones were added)
        var result = decoded.filter { Self.defaultOrder.contains($0) }
        for formType in Self.defaultOrder where !result.contains(formType) {
            result.append(formType)
        }

        cachedOrder = result
        return result
    }

    /// Save a new form order
    public func save(_ order: [SearchFormType]) {
        cachedOrder = order
        if let data = try? JSONEncoder().encode(order) {
            UserDefaults.standard.set(data, forKey: orderKey)
        }
    }

    /// Reset to default order
    public func resetOrder() {
        cachedOrder = Self.defaultOrder
        UserDefaults.standard.removeObject(forKey: orderKey)
    }

    // MARK: - Visibility Methods

    /// Get the set of hidden forms
    public func hiddenForms() -> Set<SearchFormType> {
        if let cached = cachedHidden {
            return cached
        }

        guard let data = UserDefaults.standard.data(forKey: hiddenKey),
              let decoded = try? JSONDecoder().decode(Set<SearchFormType>.self, from: data) else {
            cachedHidden = []
            return []
        }

        cachedHidden = decoded
        return decoded
    }

    /// Save the hidden forms
    public func setHidden(_ forms: Set<SearchFormType>) {
        cachedHidden = forms
        if let data = try? JSONEncoder().encode(forms) {
            UserDefaults.standard.set(data, forKey: hiddenKey)
        }
    }

    /// Toggle visibility for a form
    public func toggleVisibility(_ form: SearchFormType) -> Set<SearchFormType> {
        var current = hiddenForms()
        if current.contains(form) {
            current.remove(form)
        } else {
            current.insert(form)
        }
        setHidden(current)
        return current
    }

    /// Show a specific form (remove from hidden)
    public func show(_ form: SearchFormType) {
        var current = hiddenForms()
        current.remove(form)
        setHidden(current)
    }

    /// Hide a specific form
    public func hide(_ form: SearchFormType) {
        var current = hiddenForms()
        current.insert(form)
        setHidden(current)
    }

    /// Get visible forms in order
    public func visibleForms() -> [SearchFormType] {
        let hidden = hiddenForms()
        return order().filter { !hidden.contains($0) }
    }

    // MARK: - Synchronous Load (for SwiftUI @State init)

    /// Load order synchronously (for initial SwiftUI state)
    public nonisolated static func loadOrderSync() -> [SearchFormType] {
        guard let data = UserDefaults.standard.data(forKey: "searchFormOrder"),
              let decoded = try? JSONDecoder().decode([SearchFormType].self, from: data) else {
            return defaultOrder
        }

        // Ensure all form types are present
        var result = decoded.filter { defaultOrder.contains($0) }
        for formType in defaultOrder where !result.contains(formType) {
            result.append(formType)
        }
        return result
    }

    /// Load hidden forms synchronously (for initial SwiftUI state)
    public nonisolated static func loadHiddenSync() -> Set<SearchFormType> {
        guard let data = UserDefaults.standard.data(forKey: "searchFormHidden"),
              let decoded = try? JSONDecoder().decode(Set<SearchFormType>.self, from: data) else {
            return []
        }
        return decoded
    }

    /// Load visible forms synchronously
    public nonisolated static func loadVisibleFormsSync() -> [SearchFormType] {
        let order = loadOrderSync()
        let hidden = loadHiddenSync()
        return order.filter { !hidden.contains($0) }
    }
}

// MARK: - Notifications

public extension Notification.Name {
    static let searchFormOrderDidChange = Notification.Name("searchFormOrderDidChange")
    static let searchFormVisibilityDidChange = Notification.Name("searchFormVisibilityDidChange")
}
