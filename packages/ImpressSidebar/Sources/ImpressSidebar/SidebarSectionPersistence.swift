//
//  SidebarSectionPersistence.swift
//  ImpressSidebar
//
//  Generic persistence for sidebar section ordering and collapse state.
//

import Foundation

// MARK: - Section Order Store

/// Persists the user's preferred order of sidebar sections.
///
/// Generic over any section type that is `RawRepresentable<String>` and `CaseIterable`.
/// Each impress app creates its own instance with a unique UserDefaults key.
///
/// **Usage:**
/// ```swift
/// enum MySidebarSection: String, CaseIterable, Codable, Hashable {
///     case inbox, library, search
/// }
///
/// let store = SidebarSectionOrderStore<MySidebarSection>(
///     key: "myAppSectionOrder",
///     defaultOrder: MySidebarSection.allCases
/// )
/// ```
public actor SidebarSectionOrderStore<Section: RawRepresentable & CaseIterable & Hashable & Codable>
    where Section.RawValue == String
{
    private nonisolated let key: String
    private nonisolated let defaultOrder: [Section]
    private var cachedOrder: [Section]?

    public init(key: String, defaultOrder: [Section]) {
        self.key = key
        self.defaultOrder = defaultOrder
    }

    /// Get the current section order.
    ///
    /// Returns cached order if available, otherwise loads from UserDefaults.
    /// Ensures all sections from `defaultOrder` are present (handles app updates adding new sections).
    public func order() -> [Section] {
        if let cached = cachedOrder {
            return cached
        }

        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Section].self, from: data) else {
            cachedOrder = defaultOrder
            return defaultOrder
        }

        // Ensure all sections are present (in case new sections were added)
        var result = decoded.filter { defaultOrder.contains($0) }
        for section in defaultOrder where !result.contains(section) {
            result.append(section)
        }

        cachedOrder = result
        return result
    }

    /// Save a new section order.
    public func save(_ order: [Section]) {
        cachedOrder = order
        if let data = try? JSONEncoder().encode(order) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Reset to default order.
    public func reset() {
        cachedOrder = defaultOrder
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Load order synchronously (for SwiftUI `@State` initialization).
    ///
    /// Cannot use actor isolation, so reads directly from UserDefaults.
    public nonisolated func loadSync() -> [Section] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Section].self, from: data) else {
            return defaultOrder
        }

        var result = decoded.filter { defaultOrder.contains($0) }
        for section in defaultOrder where !result.contains(section) {
            result.append(section)
        }
        return result
    }
}

// MARK: - Collapsed State Store

/// Persists which sidebar sections are collapsed.
///
/// Generic over any section type that is `RawRepresentable<String>` and `Hashable`.
///
/// **Usage:**
/// ```swift
/// let collapseStore = SidebarCollapsedStateStore<MySidebarSection>(
///     key: "myAppCollapsedSections"
/// )
/// ```
public actor SidebarCollapsedStateStore<Section: RawRepresentable & Hashable & Codable>
    where Section.RawValue == String
{
    private nonisolated let key: String
    private var cachedState: Set<Section>?

    public init(key: String) {
        self.key = key
    }

    /// Get the set of collapsed sections.
    public func collapsedSections() -> Set<Section> {
        if let cached = cachedState {
            return cached
        }

        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Set<Section>.self, from: data) else {
            cachedState = []
            return []
        }

        cachedState = decoded
        return decoded
    }

    /// Save the collapsed state.
    public func save(_ collapsed: Set<Section>) {
        cachedState = collapsed
        if let data = try? JSONEncoder().encode(collapsed) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Toggle collapsed state for a section. Returns the new collapsed set.
    public func toggle(_ section: Section) -> Set<Section> {
        var current = collapsedSections()
        if current.contains(section) {
            current.remove(section)
        } else {
            current.insert(section)
        }
        save(current)
        return current
    }

    /// Check if a section is collapsed.
    public func isCollapsed(_ section: Section) -> Bool {
        collapsedSections().contains(section)
    }

    /// Load collapsed state synchronously (for SwiftUI `@State` initialization).
    public nonisolated func loadSync() -> Set<Section> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Set<Section>.self, from: data) else {
            return []
        }
        return decoded
    }
}
