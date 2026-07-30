// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): a display-ready value
// snapshot of a message row. No view, no AppKit.
//
//  MessageRowData.swift
//  PublicationManagerCore
//
//  MailStyleItem row model for `email-message` items (Stage 2-A, ADR-0021).
//  The mail list finally uses the mail-style row chrome for actual MAIL —
//  same value-type mirror shape as FigureRowData/ManuscriptRowData.
//

import Foundation
import ImpressFTUI
import ImpressMailStyle
import ImpressRustCore

/// A display-ready snapshot of an `email-message` item for the chassis list.
public struct MessageRowData: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let subject: String
    /// Full plain-text body (Stage 0 mirrors text bodies only) — the detail
    /// pane reads it for Source/View; the list shows `preview`.
    public let body: String
    public let from: String
    public let to: [String]
    public let cc: [String]
    public let messageIDHeader: String?
    public let threadID: String?
    /// Whitespace-collapsed body prefix (~200 chars) for the row preview.
    public let preview: String
    /// Owning folder (envelope parent), lowercase store id string.
    public let parentIDString: String?
    public let isReadState: Bool
    public let isStarredState: Bool
    public let flag: PublicationFlag?
    public let tagDisplays: [TagDisplayData]
    public let tagPaths: [String]
    /// REAL message date — `createdMs` carries the RFC-822 date (Stage 0-WP3).
    public let messageDate: Date
    public let dateModified: Date
    /// Number of messages in this row's thread; set by the list wrapper's
    /// in-list thread grouping (`collapsedByThread`). 1 = no thread badge.
    public var threadCount: Int = 1

    public init?(from row: SharedItemRow) {
        guard let id = UUID(uuidString: row.id) else { return nil }
        self.id = id
        let payload = MailStoreReader.messagePayload(from: row)
        self.subject = payload?.subject ?? ""
        let body = payload?.body ?? ""
        self.body = body
        self.from = payload?.from ?? ""
        self.to = payload?.to ?? []
        self.cc = payload?.cc ?? []
        self.messageIDHeader = payload?.messageID
        self.threadID = payload?.threadID
        self.preview = Self.previewText(from: body)
        self.parentIDString = row.parentId
        self.isReadState = row.isRead
        self.isStarredState = row.isStarred

        if let colorName = row.flagColor, let flagColor = FlagColor(rawValue: colorName) {
            // SharedItemRow carries only the color — default solid/full chrome.
            self.flag = PublicationFlag(color: flagColor)
        } else {
            self.flag = nil
        }

        self.tagPaths = row.tags
        self.tagDisplays = row.tags.map { path in
            TagDisplayData(
                id: UUID(),
                path: path,
                leaf: path.components(separatedBy: "/").last ?? path
            )
        }
        self.messageDate = Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000.0)
        self.dateModified = Date(timeIntervalSince1970: TimeInterval(row.modifiedMs) / 1000.0)
    }

    /// Collapse runs of whitespace/newlines and clip to ~200 characters.
    static func previewText(from body: String) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(200))
    }

    /// In-list thread grouping (Stage 2-A v1): group by payload `thread_id`
    /// (fallback: the message's own id), collapse each thread to its NEWEST
    /// message carrying `threadCount`, and sort newest-first. No
    /// expand/collapse chevrons in v1 — the thread badge plus the detail
    /// pane's thread view stand in (see docs/chassis-capability-matrix.md).
    static func collapsedByThread(_ messages: [MessageRowData]) -> [MessageRowData] {
        var byThread: [String: [MessageRowData]] = [:]
        var order: [String] = []
        for message in messages {
            let key = message.threadID ?? message.id.uuidString
            if byThread[key] == nil { order.append(key) }
            byThread[key, default: []].append(message)
        }
        var collapsed: [MessageRowData] = []
        for key in order {
            guard let members = byThread[key], !members.isEmpty else { continue }
            var newest = members.max(by: { $0.messageDate < $1.messageDate }) ?? members[0]
            newest.threadCount = members.count
            collapsed.append(newest)
        }
        return collapsed.sorted { $0.messageDate > $1.messageDate }
    }
}

// MARK: - MailStyleItem

extension MessageRowData: MailStyleItem {
    public var headerText: String {
        from.isEmpty ? "Unknown Sender" : from
    }
    public var titleText: String {
        subject.isEmpty ? "(No Subject)" : subject
    }
    public var date: Date { messageDate }
    /// Real read/unread semantics — unlike figures/manuscripts, the unread
    /// dot is meaningful for mail.
    public var isRead: Bool { isReadState }
    public var isStarred: Bool { isStarredState }

    public var previewText: String? {
        preview.isEmpty ? nil : preview
    }

    /// Thread badge: "(n)" when the row stands in for a collapsed thread.
    public var trailingBadgeText: String? {
        threadCount > 1 ? "(\(threadCount))" : nil
    }

    public var subtitleText: String? { nil }
    public var hasAttachment: Bool { false }
    public var hasSecondaryAttachment: Bool { false }
    public var yearText: String? { nil }
}
