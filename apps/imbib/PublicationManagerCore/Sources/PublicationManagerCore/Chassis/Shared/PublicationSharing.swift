//
//  PublicationSharing.swift
//  PublicationManagerCore
//
//  Paper ▸ Share… (⇧⌘F): the selection through the system share picker.
//

import Foundation
#if os(macOS)
import AppKit
#endif

extension PublicationRowData {
    /// The paper's page on the web: its DOI, else its arXiv abstract, else its
    /// ADS abstract (a 19-character bibcode). The toolbar's Copy Link, Edit ▸
    /// Copy DOI/URL and Paper ▸ Share… all use this one resolver.
    public var webURL: URL? {
        if let doi, !doi.isEmpty {
            return URL(string: "https://doi.org/\(doi)")
        }
        if let arxivID, !arxivID.isEmpty {
            return URL(string: "https://arxiv.org/abs/\(arxivID)")
        }
        if let bibcode, bibcode.count == 19 {
            return URL(string: "https://ui.adsabs.harvard.edu/abs/\(bibcode)")
        }
        return nil
    }
}

/// What Paper ▸ Share… hands the share picker: the selection's BibTeX as
/// text, then each paper's `webURL` (papers without one contribute only
/// their BibTeX).
public enum PublicationShareItems {
    public static func items(bibtex: String, rows: [PublicationRowData]) -> [Any] {
        var items: [Any] = []
        let text = bibtex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { items.append(text) }
        items.append(contentsOf: rows.compactMap(\.webURL))
        return items
    }
}

#if os(macOS)
/// Presents `NSSharingServicePicker` for items, anchored in the key window's
/// content view — the anchor the toolbar's "Email with PDF & BibTeX…" uses.
/// SwiftUI's `ShareLink` (the toolbar's Share menu) cannot be triggered from
/// code, which is why ⇧⌘F went unobserved until 2026-09-25.
@MainActor
public enum PublicationSharePicker {
    @discardableResult
    public static func present(_ items: [Any]) -> Bool {
        guard !items.isEmpty, let contentView = NSApp.keyWindow?.contentView else { return false }
        // Top centre, opening downwards. SwiftUI's hosting view is flipped, so
        // its top is minY and "below" is the maxY edge; an unflipped view is
        // the other way round.
        let flipped = contentView.isFlipped
        let top = flipped ? contentView.bounds.minY : contentView.bounds.maxY - 1
        let anchor = NSRect(x: contentView.bounds.midX, y: top, width: 1, height: 1)
        NSSharingServicePicker(items: items)
            .show(relativeTo: anchor, of: contentView, preferredEdge: flipped ? .maxY : .minY)
        return true
    }
}
#endif
