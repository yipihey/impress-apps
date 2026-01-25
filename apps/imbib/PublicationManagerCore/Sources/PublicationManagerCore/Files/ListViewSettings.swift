//
//  ListViewSettings.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import Foundation

// MARK: - Row Density

/// Controls vertical spacing in publication list rows
public enum RowDensity: String, Codable, CaseIterable, Sendable {
    case compact
    case `default`
    case spacious

    public var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .default: return "Default"
        case .spacious: return "Spacious"
        }
    }

    /// Vertical padding for rows
    public var rowPadding: CGFloat {
        switch self {
        case .compact: return 4
        case .default: return 8
        case .spacious: return 12
        }
    }

    /// Spacing between content lines
    public var contentSpacing: CGFloat {
        switch self {
        case .compact: return 1
        case .default: return 2
        case .spacious: return 4
        }
    }
}

// MARK: - List View Settings

/// Settings for customizing publication list row appearance.
///
/// These settings control which fields are displayed in list rows and their visual density.
public struct ListViewSettings: Codable, Equatable, Sendable {

    // MARK: - Field Visibility

    /// Show publication year after author names
    public var showYear: Bool

    /// Show title row (second line)
    public var showTitle: Bool

    /// Show venue (journal, booktitle, or publisher)
    public var showVenue: Bool

    /// Show citation count on the right side
    public var showCitationCount: Bool

    /// Show blue dot for unread publications
    public var showUnreadIndicator: Bool

    /// Show paperclip icon for publications with attachments
    public var showAttachmentIndicator: Bool

    /// Show arXiv category chips for papers with categories
    public var showCategories: Bool

    /// Show date added in top-right corner (Apple Mail style: time/yesterday/date)
    public var showDateAdded: Bool

    // MARK: - Content Limits

    /// Number of abstract preview lines (0 = hidden)
    public var abstractLineLimit: Int

    // MARK: - Visual Style

    /// Row density affecting padding and spacing
    public var rowDensity: RowDensity

    // MARK: - Initialization

    public init(
        showYear: Bool = true,
        showTitle: Bool = true,
        showVenue: Bool = false,
        showCitationCount: Bool = true,
        showUnreadIndicator: Bool = true,
        showAttachmentIndicator: Bool = true,
        showCategories: Bool = true,
        showDateAdded: Bool = true,
        abstractLineLimit: Int = 2,
        rowDensity: RowDensity = .default
    ) {
        self.showYear = showYear
        self.showTitle = showTitle
        self.showVenue = showVenue
        self.showCitationCount = showCitationCount
        self.showUnreadIndicator = showUnreadIndicator
        self.showAttachmentIndicator = showAttachmentIndicator
        self.showCategories = showCategories
        self.showDateAdded = showDateAdded
        self.abstractLineLimit = max(0, min(10, abstractLineLimit))
        self.rowDensity = rowDensity
    }

    /// Default settings matching the original MailStylePublicationRow behavior
    public static let `default` = ListViewSettings()
}
