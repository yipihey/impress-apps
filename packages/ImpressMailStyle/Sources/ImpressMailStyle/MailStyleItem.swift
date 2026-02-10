//
//  MailStyleItem.swift
//  ImpressMailStyle
//

import Foundation
import ImpressFTUI

/// Protocol defining the data contract for a mail-style list row.
///
/// Any item that conforms to this protocol can be rendered by ``MailStyleRow``.
/// Required properties cover the universal elements of a mail-style row
/// (header, title, date, read state). Optional properties have defaults.
///
/// Follows the `SidebarTreeNode` pattern from ImpressSidebar.
@MainActor
public protocol MailStyleItem: Identifiable, Hashable, Sendable where ID == UUID {
    var id: UUID { get }

    // MARK: - Required

    /// Top-left header text (e.g., "Einstein, A. · 2005" or "Alice Smith")
    var headerText: String { get }

    /// Main content line (paper title or email subject)
    var titleText: String { get }

    /// Date for relative date display in the row header
    var date: Date { get }

    /// Whether the item has been read
    var isRead: Bool { get }

    // MARK: - Optional (defaults provided)

    /// Whether the item is starred/flagged
    var isStarred: Bool { get }

    /// Preview text below the title (abstract or message snippet)
    var previewText: String? { get }

    /// Secondary text line (venue or "To: recipients")
    var subtitleText: String? { get }

    /// Trailing badge in the header row (e.g., "42" or "(5)")
    var trailingBadgeText: String? { get }

    /// Whether the item has a primary attachment (PDF or file)
    var hasAttachment: Bool { get }

    /// Whether the item has a secondary attachment (non-PDF files)
    var hasSecondaryAttachment: Bool { get }

    /// Rich flag state for the leading stripe
    var flag: PublicationFlag? { get }

    /// Tag display data for the tag line
    var tagDisplays: [TagDisplayData] { get }
}

// MARK: - Default Implementations

public extension MailStyleItem {
    var isStarred: Bool { false }
    var previewText: String? { nil }
    var subtitleText: String? { nil }
    var trailingBadgeText: String? { nil }
    var hasAttachment: Bool { false }
    var hasSecondaryAttachment: Bool { false }
    var flag: PublicationFlag? { nil }
    var tagDisplays: [TagDisplayData] { [] }
}
