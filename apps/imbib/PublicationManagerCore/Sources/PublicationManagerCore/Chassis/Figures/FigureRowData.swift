// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): a display-ready value
// snapshot of a figure row. No view, no AppKit.
//
//  FigureRowData.swift
//  PublicationManagerCore
//
//  MailStyleItem row model for `figure` items (Stage 2-B, ADR-0021). The
//  figures list reuses the exact mail-style row chrome that publications and
//  manuscripts use — but figures are NOT publication-shaped, so they get
//  their own value type (mirror of ManuscriptRowData).
//

import Foundation
import ImpressFTUI
import ImpressMailStyle
import ImpressRustCore

/// A display-ready snapshot of a `figure` item for the chassis list.
public struct FigureRowData: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let caption: String?
    /// Asset format: "png" | "svg" | "pdf" | … (empty when metadata-only).
    public let format: String
    /// SHA-256 of the CAS artifact, when one was exported.
    public let dataHash: String?
    /// SHA-256 of the generator script, for reproducibility tracking.
    public let scriptHash: String?
    /// Owning folder (envelope parent), lowercase store id string.
    public let parentIDString: String?
    public let isStarredState: Bool
    public let flag: PublicationFlag?
    public let tagDisplays: [TagDisplayData]
    public let tagPaths: [String]
    public let dateAdded: Date
    public let dateModified: Date

    public init?(from row: SharedItemRow) {
        guard let id = UUID(uuidString: row.id) else { return nil }
        self.id = id
        let payload = FigureStoreReader.figurePayload(from: row)
        let title = payload?.title ?? ""
        self.title = title.isEmpty ? "Untitled figure" : title
        self.caption = payload?.caption
        self.format = payload?.format ?? ""
        self.dataHash = payload?.dataHash
        self.scriptHash = payload?.scriptHash
        self.parentIDString = row.parentId
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
        self.dateAdded = Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000.0)
        self.dateModified = Date(timeIntervalSince1970: TimeInterval(row.modifiedMs) / 1000.0)
    }
}

// MARK: - MailStyleItem

extension FigureRowData: MailStyleItem {
    public var headerText: String {
        format.isEmpty ? "Figure" : format.uppercased()
    }
    public var titleText: String { title }
    public var date: Date { dateModified }
    // Figures have no read/unread semantics — always report read so rows
    // don't show a spurious unread dot (same rule as manuscripts).
    public var isRead: Bool { true }
    public var isStarred: Bool { isStarredState }

    public var subtitleText: String? {
        format.isEmpty ? nil : format.capitalized
    }

    public var previewText: String? { caption }

    public var trailingBadgeText: String? { nil }

    /// Paperclip = a rendered CAS artifact exists for this figure.
    public var hasAttachment: Bool { dataHash != nil }
    public var hasSecondaryAttachment: Bool { false }
    public var yearText: String? { nil }
}
