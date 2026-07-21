#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  ManuscriptRowData.swift
//  PublicationManagerCore
//
//  MailStyleItem row model for manuscript items (GUI-meld plan §5). The
//  manuscripts list reuses the exact mail-style row chrome that publications
//  use — but manuscripts are NOT publication-shaped, so they get their own
//  value type instead of leaking into PublicationRowData / the 2231-line
//  UnifiedPublicationListWrapper.

import Foundation
import ImpressFTUI
import ImpressMailStyle

/// A display-ready snapshot of a `manuscript@1.0.0` item for the chassis list.
public struct ManuscriptRowData: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let authorString: String
    /// Lifecycle status parsed from the Rust `status` string (nil if unknown).
    public let status: JournalManuscriptStatus?
    /// Raw status string (preserved even when it doesn't map to the enum).
    public let statusRaw: String
    /// Source format: "typst" | "latex" (empty when metadata-only).
    public let format: String
    public let journalTarget: String?
    public let bodyContentHash: String?
    public let bodyModifiedAt: Date?
    public let revisionCount: Int
    public let isReadState: Bool
    public let isStarredState: Bool
    public let flag: PublicationFlag?
    public let tagDisplays: [TagDisplayData]
    public let dateAdded: Date
    public let dateModified: Date

    public init?(from row: ManuscriptRow) {
        guard let id = UUID(uuidString: row.id) else { return nil }
        self.id = id
        self.title = row.title.isEmpty ? "Untitled" : row.title
        self.authorString = row.authorString
        self.statusRaw = row.status
        self.status = JournalManuscriptStatus(rawValue: row.status)
        self.format = row.format
        self.journalTarget = row.journalTarget
        self.bodyContentHash = row.bodyContentHash
        self.bodyModifiedAt = row.bodyModifiedAt.flatMap(Self.parseISO8601)
        self.revisionCount = Int(row.revisionCount)
        self.isReadState = row.isRead
        self.isStarredState = row.isStarred

        if let colorName = row.flagColor, let flagColor = FlagColor(rawValue: colorName) {
            let flagStyle = row.flagStyle.flatMap { FlagStyle(rawValue: $0) } ?? .solid
            let flagLength = row.flagLength.flatMap { FlagLength(rawValue: $0) } ?? .full
            self.flag = PublicationFlag(color: flagColor, style: flagStyle, length: flagLength)
        } else {
            self.flag = nil
        }

        self.tagDisplays = row.tags.map { tag in
            TagDisplayData(
                id: UUID(),
                path: tag.path,
                leaf: tag.leafName,
                colorLight: tag.colorLight,
                colorDark: tag.colorDark
            )
        }
        self.dateAdded = Date(timeIntervalSince1970: TimeInterval(row.dateAdded) / 1000.0)
        self.dateModified = Date(timeIntervalSince1970: TimeInterval(row.dateModified) / 1000.0)
    }

    private static let iso8601 = ISO8601DateFormatter()
    private static func parseISO8601(_ s: String) -> Date? { iso8601.date(from: s) }
}

// MARK: - MailStyleItem

extension ManuscriptRowData: MailStyleItem {
    public var headerText: String {
        authorString.isEmpty ? (status?.displayName ?? statusRaw.capitalized) : authorString
    }
    public var titleText: String { title }
    public var date: Date { dateModified }
    public var isRead: Bool { isReadState }
    public var isStarred: Bool { isStarredState }

    public var subtitleText: String? {
        // "Status · Format" (both when present), so the row shows lifecycle
        // and source kind the way a publication row shows venue.
        let statusText = status?.displayName ?? (statusRaw.isEmpty ? nil : statusRaw.capitalized)
        let formatText = format.isEmpty ? nil : format.capitalized
        switch (statusText, formatText) {
        case (let s?, let f?): return "\(s) · \(f)"
        case (let s?, nil):    return s
        case (nil, let f?):    return f
        case (nil, nil):       return journalTarget
        }
    }

    public var previewText: String? { journalTarget.map { "→ \($0)" } }

    public var trailingBadgeText: String? {
        revisionCount > 0 ? "v\(revisionCount)" : nil
    }

    /// Manuscripts don't carry attachment indicators in the list (their PDF is
    /// compiled output, shown in the detail pane, not a linked attachment).
    public var hasAttachment: Bool { false }
    public var hasSecondaryAttachment: Bool { false }
    public var yearText: String? { nil }
}
#endif
