//
//  InboxRetentionStore.swift
//  PublicationManagerCore
//
//  Retention settings for the Inbox section — read from the settings
//  registry (ADR-0036 D5, plan-self-reflective-layer R1) since 2026-09-26.
//
//  The keys `imbib.retention.inbox_days` and `imbib.retention.auto_remove_read`
//  are declared once, in `crates/impress-settings`, with their defaults and
//  the legacy `UserDefaults` names (`inbox.retentionDays`,
//  `inbox.autoRemoveRead`) this store used to write. A device that set them
//  before this build has its values copied into `<workspace>/settings/`
//  on the first read, and the `UserDefaults` keys are left in place (D-R5).
//  The same values answer `settings-service_get` over the CLI and MCP.
//

import Foundation
import ImpressKit

/// Stores retention settings for inbox papers.
@MainActor
public final class InboxRetentionStore {
    public static let shared = InboxRetentionStore()

    public static let retentionKey = "imbib.retention.inbox_days"
    public static let autoRemoveReadKey = "imbib.retention.auto_remove_read"

    /// Number of days to keep inbox papers. 0 means forever.
    public var retentionDays: Int {
        get { ImpressSettings.shared.value(Self.retentionKey, as: Int.self) }
        set { ImpressSettings.shared.set(Self.retentionKey, newValue) }
    }

    /// Whether to automatically remove papers that have been read.
    public var autoRemoveRead: Bool {
        get { ImpressSettings.shared.value(Self.autoRemoveReadKey, as: Bool.self) }
        set { ImpressSettings.shared.set(Self.autoRemoveReadKey, newValue) }
    }

    /// Retention presets for the UI — the registry's `choices` for the key,
    /// spelled here for the menu; `SettingsRegistryTests` in ImpressKit pins
    /// the days to the registry.
    public enum RetentionPreset: Int, CaseIterable, Sendable {
        case oneWeek = 7
        case twoWeeks = 14
        case oneMonth = 30
        case threeMonths = 90
        case forever = 0

        public var displayName: String {
            switch self {
            case .oneWeek: return "1 Week"
            case .twoWeeks: return "2 Weeks"
            case .oneMonth: return "1 Month"
            case .threeMonths: return "3 Months"
            case .forever: return "Forever"
            }
        }
    }

    private init() {}
}
