//
//  ExplorationRetentionStore.swift
//  PublicationManagerCore
//
//  Retention settings for the Exploration section — read from the settings
//  registry (ADR-0036 D5, plan-self-reflective-layer R1) since 2026-09-26;
//  see `InboxRetentionStore` for the migration rule. The key is
//  `imbib.retention.exploration_days`, legacy `exploration.retentionDays`.
//

import Foundation
import ImpressKit

/// Stores retention settings for exploration collections and searches.
@MainActor
public final class ExplorationRetentionStore {
    public static let shared = ExplorationRetentionStore()

    public static let retentionKey = "imbib.retention.exploration_days"

    /// Number of days to keep explorations. 0 means forever.
    public var retentionDays: Int {
        get { ImpressSettings.shared.value(Self.retentionKey, as: Int.self) }
        set { ImpressSettings.shared.set(Self.retentionKey, newValue) }
    }

    /// Retention presets for the UI (the registry's `choices` for the key).
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

    private init() {}
}
