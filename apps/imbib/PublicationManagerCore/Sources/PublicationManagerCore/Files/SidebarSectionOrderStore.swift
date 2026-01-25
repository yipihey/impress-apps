//
//  SidebarSectionOrderStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation

// MARK: - Sidebar Section Type

/// Represents the reorderable and collapsible sections in the sidebar
public enum SidebarSectionType: String, CaseIterable, Codable, Identifiable, Equatable {
    case inbox
    case libraries
    case scixLibraries
    case search
    case exploration
    case dismissed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .inbox: return "Inbox"
        case .libraries: return "Libraries"
        case .scixLibraries: return "SciX Libraries"
        case .search: return "Search"
        case .exploration: return "Exploration"
        case .dismissed: return "Dismissed"
        }
    }
}

// MARK: - Sidebar Section Order Store

/// Persists the user's preferred order of sidebar sections
public actor SidebarSectionOrderStore {

    // MARK: - Singleton

    public static let shared = SidebarSectionOrderStore()

    // MARK: - Properties

    private let key = "sidebarSectionOrder"
    private var cachedOrder: [SidebarSectionType]?

    // MARK: - Default Order

    public static let defaultOrder: [SidebarSectionType] = [
        .inbox,
        .libraries,
        .scixLibraries,
        .search,
        .exploration,
        .dismissed
    ]

    // MARK: - Public API

    /// Get the current section order
    public func order() -> [SidebarSectionType] {
        if let cached = cachedOrder {
            return cached
        }

        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SidebarSectionType].self, from: data) else {
            cachedOrder = Self.defaultOrder
            return Self.defaultOrder
        }

        // Ensure all sections are present (in case new sections were added)
        var result = decoded.filter { Self.defaultOrder.contains($0) }
        for section in Self.defaultOrder where !result.contains(section) {
            result.append(section)
        }

        cachedOrder = result
        return result
    }

    /// Save a new section order
    public func save(_ order: [SidebarSectionType]) {
        cachedOrder = order
        if let data = try? JSONEncoder().encode(order) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Reset to default order
    public func reset() {
        cachedOrder = Self.defaultOrder
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Synchronous Load (for SwiftUI @State init)

    /// Load order synchronously (for initial SwiftUI state)
    public nonisolated static func loadOrderSync() -> [SidebarSectionType] {
        guard let data = UserDefaults.standard.data(forKey: "sidebarSectionOrder"),
              let decoded = try? JSONDecoder().decode([SidebarSectionType].self, from: data) else {
            return defaultOrder
        }

        // Ensure all sections are present
        var result = decoded.filter { defaultOrder.contains($0) }
        for section in defaultOrder where !result.contains(section) {
            result.append(section)
        }
        return result
    }
}

// MARK: - Sidebar Collapsed State Store

/// Persists which sidebar sections are collapsed
public actor SidebarCollapsedStateStore {

    // MARK: - Singleton

    public static let shared = SidebarCollapsedStateStore()

    // MARK: - Properties

    private let key = "sidebarCollapsedSections"
    private var cachedState: Set<SidebarSectionType>?

    // MARK: - Public API

    /// Get the set of collapsed sections
    public func collapsedSections() -> Set<SidebarSectionType> {
        if let cached = cachedState {
            return cached
        }

        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Set<SidebarSectionType>.self, from: data) else {
            cachedState = []
            return []
        }

        cachedState = decoded
        return decoded
    }

    /// Save the collapsed state
    public func save(_ collapsed: Set<SidebarSectionType>) {
        cachedState = collapsed
        if let data = try? JSONEncoder().encode(collapsed) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Toggle collapsed state for a section
    public func toggle(_ section: SidebarSectionType) -> Set<SidebarSectionType> {
        var current = collapsedSections()
        if current.contains(section) {
            current.remove(section)
        } else {
            current.insert(section)
        }
        save(current)
        return current
    }

    /// Check if a section is collapsed
    public func isCollapsed(_ section: SidebarSectionType) -> Bool {
        collapsedSections().contains(section)
    }

    // MARK: - Synchronous Load (for SwiftUI @State init)

    /// Load collapsed state synchronously (for initial SwiftUI state)
    public nonisolated static func loadCollapsedSync() -> Set<SidebarSectionType> {
        guard let data = UserDefaults.standard.data(forKey: "sidebarCollapsedSections"),
              let decoded = try? JSONDecoder().decode(Set<SidebarSectionType>.self, from: data) else {
            return []
        }
        return decoded
    }
}

// MARK: - Notification

public extension Notification.Name {
    static let sidebarSectionOrderDidChange = Notification.Name("sidebarSectionOrderDidChange")
    static let sidebarCollapsedStateDidChange = Notification.Name("sidebarCollapsedStateDidChange")
}
