//
//  MailStyleRowConfiguration.swift
//  ImpressMailStyle
//

import Foundation
import ImpressFTUI

/// Display configuration for ``MailStyleRow``.
///
/// Controls which elements are visible and how they render.
/// Domain-agnostic — apps bridge their own settings to this type.
public struct MailStyleRowConfiguration: Equatable, Sendable {

    /// Show the relative date in the header row
    public var showDate: Bool

    /// Show the title line
    public var showTitle: Bool

    /// Show the subtitle line (venue, recipients)
    public var showSubtitle: Bool

    /// Show the trailing badge text (citation count, thread count)
    public var showTrailingBadge: Bool

    /// Show the unread indicator dot
    public var showUnreadIndicator: Bool

    /// Show attachment indicator icons
    public var showAttachmentIndicator: Bool

    /// Show the colored flag stripe at the leading edge
    public var showFlagStripe: Bool

    /// Number of preview text lines (0 = hidden)
    public var previewLineLimit: Int

    /// Maximum lines for title (nil = unlimited)
    public var titleLineLimit: Int?

    /// How tags are displayed (dots, text, hybrid, hidden)
    public var tagDisplayStyle: TagDisplayStyle

    /// How tag paths are rendered (full, leaf-only, truncated)
    public var tagPathStyle: TagPathStyle

    /// Row density affecting padding and spacing
    public var density: MailStyleRowDensity

    public init(
        showDate: Bool = true,
        showTitle: Bool = true,
        showSubtitle: Bool = false,
        showTrailingBadge: Bool = true,
        showUnreadIndicator: Bool = true,
        showAttachmentIndicator: Bool = true,
        showFlagStripe: Bool = true,
        previewLineLimit: Int = 2,
        titleLineLimit: Int? = nil,
        tagDisplayStyle: TagDisplayStyle = .dots(maxVisible: 5),
        tagPathStyle: TagPathStyle = .leafOnly,
        density: MailStyleRowDensity = .default
    ) {
        self.showDate = showDate
        self.showTitle = showTitle
        self.showSubtitle = showSubtitle
        self.showTrailingBadge = showTrailingBadge
        self.showUnreadIndicator = showUnreadIndicator
        self.showAttachmentIndicator = showAttachmentIndicator
        self.showFlagStripe = showFlagStripe
        self.previewLineLimit = previewLineLimit
        self.titleLineLimit = titleLineLimit
        self.tagDisplayStyle = tagDisplayStyle
        self.tagPathStyle = tagPathStyle
        self.density = density
    }

    /// Default configuration matching Apple Mail-style rows
    public static let `default` = MailStyleRowConfiguration()
}
