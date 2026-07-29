// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). The row type and the
// ONE generic mapping are data over ImpressMailStyle/ImpressFTUI, both of
// which ship for iOS. The per-kind convenience initializers name the
// macOS-gated row structs (FigureRowData & co.) and were SPLIT out into
// `KindTaggedRow+RowData.swift` rather than half-gating this file.
//
//  KindTaggedRow.swift
//  PublicationManagerCore
//
//  WP G3 (ADR-0022 D4): the heterogeneous list row — id + kind + the
//  MailStyleItem display surface — so ONE list can show publications next to
//  messages next to figures (grouped global search, G6; impress, D9).
//
//  This does NOT replace the per-kind row structs (ADR-0018 D3 / ADR-0021 D2:
//  FigureRowData & co. STAY). It is a lossy display projection of them, built
//  at the point a surface needs mixed kinds.
//

import Foundation
import ImpressFTUI
import ImpressMailStyle

/// A kind-tagged, display-ready row for mixed-kind surfaces.
public struct KindTaggedRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Which record kind this row came from — the registry key a mixed list
    /// uses to pick a row factory and a host uses to pick a detail pane.
    public let kind: RecordKindID

    // MailStyleItem surface (see ImpressMailStyle.MailStyleItem).
    public let headerText: String
    public let titleText: String
    public let subtitleText: String?
    public let previewText: String?
    public let trailingBadgeText: String?
    public let yearText: String?
    public let date: Date
    public let isRead: Bool
    public let isStarred: Bool
    public let hasAttachment: Bool
    public let hasSecondaryAttachment: Bool
    public let flag: PublicationFlag?
    public let tagDisplays: [TagDisplayData]

    public init(
        id: UUID,
        kind: RecordKindID,
        headerText: String,
        titleText: String,
        subtitleText: String? = nil,
        previewText: String? = nil,
        trailingBadgeText: String? = nil,
        yearText: String? = nil,
        date: Date,
        isRead: Bool = true,
        isStarred: Bool = false,
        hasAttachment: Bool = false,
        hasSecondaryAttachment: Bool = false,
        flag: PublicationFlag? = nil,
        tagDisplays: [TagDisplayData] = []
    ) {
        self.id = id
        self.kind = kind
        self.headerText = headerText
        self.titleText = titleText
        self.subtitleText = subtitleText
        self.previewText = previewText
        self.trailingBadgeText = trailingBadgeText
        self.yearText = yearText
        self.date = date
        self.isRead = isRead
        self.isStarred = isStarred
        self.hasAttachment = hasAttachment
        self.hasSecondaryAttachment = hasSecondaryAttachment
        self.flag = flag
        self.tagDisplays = tagDisplays
    }
}

// Every requirement is witnessed by a stored property above.
extension KindTaggedRow: MailStyleItem {}

// MARK: - Mapping from the per-kind row structs

public extension KindTaggedRow {

    /// The one mapping: any per-kind `MailStyleItem` row struct, tagged with
    /// its kind. Per-kind conveniences below just fix the tag, so a new kind
    /// costs one line and can never disagree with the row chrome.
    @MainActor
    init(kind: RecordKindID, item: some MailStyleItem) {
        self.init(
            id: item.id,
            kind: kind,
            headerText: item.headerText,
            titleText: item.titleText,
            subtitleText: item.subtitleText,
            previewText: item.previewText,
            trailingBadgeText: item.trailingBadgeText,
            yearText: item.yearText,
            date: item.date,
            isRead: item.isRead,
            isStarred: item.isStarred,
            hasAttachment: item.hasAttachment,
            hasSecondaryAttachment: item.hasSecondaryAttachment,
            flag: item.flag,
            tagDisplays: item.tagDisplays)
    }
}
