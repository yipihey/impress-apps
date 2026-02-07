//
//  FlagColorOrderStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-02-06.
//

import Foundation
import ImpressFTUI

// MARK: - Flag Color Order Store

/// Persists the user's preferred order of flag colors in the sidebar
public actor FlagColorOrderStore {

    // MARK: - Singleton

    public static let shared = FlagColorOrderStore()

    // MARK: - Properties

    private let orderKey = "flagColorOrder"
    private var cachedOrder: [FlagColor]?

    // MARK: - Default Values

    public static let defaultOrder: [FlagColor] = [.red, .amber, .blue, .gray]

    // MARK: - Order Methods

    /// Get the current flag color order
    public func order() -> [FlagColor] {
        if let cached = cachedOrder {
            return cached
        }

        guard let data = UserDefaults.standard.data(forKey: orderKey),
              let decoded = try? JSONDecoder().decode([FlagColor].self, from: data) else {
            cachedOrder = Self.defaultOrder
            return Self.defaultOrder
        }

        // Ensure all colors are present (in case new ones were added)
        var result = decoded.filter { Self.defaultOrder.contains($0) }
        for color in Self.defaultOrder where !result.contains(color) {
            result.append(color)
        }

        cachedOrder = result
        return result
    }

    /// Save a new flag color order
    public func save(_ order: [FlagColor]) {
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

    // MARK: - Synchronous Load (for SwiftUI @State init)

    /// Load order synchronously (for initial SwiftUI state)
    public nonisolated static func loadOrderSync() -> [FlagColor] {
        guard let data = UserDefaults.standard.data(forKey: "flagColorOrder"),
              let decoded = try? JSONDecoder().decode([FlagColor].self, from: data) else {
            return defaultOrder
        }

        // Ensure all colors are present
        var result = decoded.filter { defaultOrder.contains($0) }
        for color in defaultOrder where !result.contains(color) {
            result.append(color)
        }
        return result
    }
}
