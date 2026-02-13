//
//  ListViewSettings.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import Foundation
import ImpressFTUI
import ImpressMailStyle

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

    // MARK: - Flags & Tags

    /// Show the colored flag stripe at the leading edge of rows
    public var showFlagStripe: Bool

    /// How tags are displayed in publication rows (dots, text, or hybrid)
    public var tagDisplayStyle: TagDisplayStyle

    /// How tag paths are rendered in text/chip mode (full, leaf-only, or truncated)
    public var tagPathStyle: TagPathStyle

    // MARK: - Auto-Import

    /// Automatically create tags from ADS/source keywords when importing papers
    public var importKeywordsAsTags: Bool

    /// Optional prefix prepended to imported keyword tags (e.g., "keywords/")
    public var keywordTagPrefix: String

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
        showFlagStripe: Bool = true,
        tagDisplayStyle: TagDisplayStyle = .dots(maxVisible: 5),
        tagPathStyle: TagPathStyle = .leafOnly,
        importKeywordsAsTags: Bool = false,
        keywordTagPrefix: String = "",
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
        self.showFlagStripe = showFlagStripe
        self.tagDisplayStyle = tagDisplayStyle
        self.tagPathStyle = tagPathStyle
        self.importKeywordsAsTags = importKeywordsAsTags
        self.keywordTagPrefix = keywordTagPrefix
        self.rowDensity = rowDensity
    }

    /// Default settings matching the original MailStylePublicationRow behavior
    public static let `default` = ListViewSettings()

    // MARK: - Resilient Codable

    /// Custom decoder that handles missing keys gracefully.
    /// This prevents settings from being lost when new fields are added.
    public init(from decoder: Decoder) throws {
        let defaults = ListViewSettings.default
        let container = try decoder.container(keyedBy: CodingKeys.self)

        showYear = (try? container.decode(Bool.self, forKey: .showYear)) ?? defaults.showYear
        showTitle = (try? container.decode(Bool.self, forKey: .showTitle)) ?? defaults.showTitle
        showVenue = (try? container.decode(Bool.self, forKey: .showVenue)) ?? defaults.showVenue
        showCitationCount = (try? container.decode(Bool.self, forKey: .showCitationCount)) ?? defaults.showCitationCount
        showUnreadIndicator = (try? container.decode(Bool.self, forKey: .showUnreadIndicator)) ?? defaults.showUnreadIndicator
        showAttachmentIndicator = (try? container.decode(Bool.self, forKey: .showAttachmentIndicator)) ?? defaults.showAttachmentIndicator
        showCategories = (try? container.decode(Bool.self, forKey: .showCategories)) ?? defaults.showCategories
        showDateAdded = (try? container.decode(Bool.self, forKey: .showDateAdded)) ?? defaults.showDateAdded
        abstractLineLimit = (try? container.decode(Int.self, forKey: .abstractLineLimit)) ?? defaults.abstractLineLimit
        showFlagStripe = (try? container.decode(Bool.self, forKey: .showFlagStripe)) ?? defaults.showFlagStripe
        tagDisplayStyle = (try? container.decode(TagDisplayStyle.self, forKey: .tagDisplayStyle)) ?? defaults.tagDisplayStyle
        tagPathStyle = (try? container.decode(TagPathStyle.self, forKey: .tagPathStyle)) ?? defaults.tagPathStyle
        importKeywordsAsTags = (try? container.decode(Bool.self, forKey: .importKeywordsAsTags)) ?? defaults.importKeywordsAsTags
        keywordTagPrefix = (try? container.decode(String.self, forKey: .keywordTagPrefix)) ?? defaults.keywordTagPrefix
        rowDensity = (try? container.decode(RowDensity.self, forKey: .rowDensity)) ?? defaults.rowDensity
    }
}

// MARK: - MailStyleRowConfiguration Bridge

extension ListViewSettings {
    /// Convert to a domain-agnostic ``MailStyleRowConfiguration`` for use with ``MailStyleRow``.
    public var mailStyleConfiguration: MailStyleRowConfiguration {
        MailStyleRowConfiguration(
            showYear: showYear,
            showDate: showDateAdded,
            showTitle: showTitle,
            showSubtitle: showVenue,
            showTrailingBadge: showCitationCount,
            showUnreadIndicator: showUnreadIndicator,
            showAttachmentIndicator: showAttachmentIndicator,
            showFlagStripe: showFlagStripe,
            previewLineLimit: abstractLineLimit,
            tagDisplayStyle: tagDisplayStyle,
            tagPathStyle: tagPathStyle,
            density: MailStyleRowDensity(rawValue: rowDensity.rawValue) ?? .default
        )
    }
}
