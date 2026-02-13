//
//  ExplorationRetentionStore.swift
//  PublicationManagerCore
//
//  Retention settings for the Exploration section.
//

import Foundation

/// Stores retention settings for exploration collections and searches.
@MainActor
public final class ExplorationRetentionStore {
    public static let shared = ExplorationRetentionStore()

    private let defaults = UserDefaults.standard
    private let retentionKey = "exploration.retentionDays"

    /// Number of days to keep explorations. 0 means forever.
    public var retentionDays: Int {
        get { defaults.integer(forKey: retentionKey) }
        set { defaults.set(newValue, forKey: retentionKey) }
    }

    /// Retention presets for the UI.
    public enum RetentionPreset: Int, CaseIterable, Sendable {
        case oneWeek = 7
        case oneMonth = 30
        case threeMonths = 90
        case forever = 0

        public var displayName: String {
            switch self {
            case .oneWeek: return "1 Week"
            case .oneMonth: return "1 Month"
            case .threeMonths: return "3 Months"
            case .forever: return "Forever"
            }
        }
    }

    private init() {
        // Default: 30 days retention
        if defaults.object(forKey: retentionKey) == nil {
            defaults.set(RetentionPreset.oneMonth.rawValue, forKey: retentionKey)
        }
    }
}
