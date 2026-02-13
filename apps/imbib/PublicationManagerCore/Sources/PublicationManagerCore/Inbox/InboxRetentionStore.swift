//
//  InboxRetentionStore.swift
//  PublicationManagerCore
//
//  Retention settings for the Inbox section.
//

import Foundation

/// Stores retention settings for inbox papers.
@MainActor
public final class InboxRetentionStore {
    public static let shared = InboxRetentionStore()

    private let defaults = UserDefaults.standard
    private let retentionKey = "inbox.retentionDays"
    private let autoRemoveReadKey = "inbox.autoRemoveRead"

    /// Number of days to keep inbox papers. 0 means forever.
    public var retentionDays: Int {
        get { defaults.integer(forKey: retentionKey) }
        set { defaults.set(newValue, forKey: retentionKey) }
    }

    /// Whether to automatically remove papers that have been read.
    public var autoRemoveRead: Bool {
        get { defaults.bool(forKey: autoRemoveReadKey) }
        set { defaults.set(newValue, forKey: autoRemoveReadKey) }
    }

    /// Retention presets for the UI.
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

    private init() {
        // Default: 30 days retention
        if defaults.object(forKey: retentionKey) == nil {
            defaults.set(RetentionPreset.oneMonth.rawValue, forKey: retentionKey)
        }
    }
}
