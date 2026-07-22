//
//  DetailTab.swift
//  PublicationManagerCore
//
//  Shared detail tab enum used by both macOS and iOS detail views.
//

/// Represents the available tabs in the detail pane. Shared across macOS and
/// iOS, and across item kinds (publications and manuscripts).
///
/// `.source` is manuscript-only (the Typst/LaTeX editor, GUI-meld Phase 3);
/// `.bibtex` is publication-only. Availability is resolved per item kind via
/// `available(for:)`, and `coerced(for:)` keeps a persisted tab valid when the
/// selected item's kind changes (mapping "text tab" ↔ "text tab").
public enum DetailTab: String, CaseIterable, Identifiable, Sendable {
    case info
    case source
    case pdf
    case notes
    case bibtex

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .info: "Info"
        case .source: "Source"
        case .pdf: "PDF"
        case .notes: "Notes"
        case .bibtex: "BibTeX"
        }
    }

    public var icon: String {
        switch self {
        case .info: "info.circle"
        case .source: "curlybraces"
        case .pdf: "doc.richtext"
        case .notes: "note.text"
        case .bibtex: "chevron.left.forwardslash.chevron.right"
        }
    }

    // MARK: - Kind-aware availability

    /// The kind of item the detail pane is showing.
    public enum ItemKind: Sendable {
        /// A publication; `editable` gates the Notes tab (online results are
        /// not editable).
        case publication(editable: Bool)
        case manuscript
    }

    /// Tabs available for the given item kind, in display order.
    public static func available(for kind: ItemKind) -> [DetailTab] {
        switch kind {
        case .publication(let editable):
            return editable ? [.info, .pdf, .notes, .bibtex] : [.info, .pdf, .bibtex]
        case .manuscript:
            // No standalone Notes tab: the store manuscript has a `notes`
            // field but no write path (only setManuscriptBody), and the Info
            // tab already surfaces notes. A dedicated editable Notes tab needs
            // a `set_manuscript_notes` FFI — tracked separately. (Rendering it
            // here would show a blank tab.)
            return [.info, .source, .pdf]
        }
    }

    /// Coerce a (possibly persisted) tab to one valid for `kind`. Maps the
    /// "text tab" of one kind to the other's (source ↔ bibtex) so switching
    /// between a manuscript and a publication lands somewhere sensible;
    /// otherwise falls back to `.info`.
    public func coerced(for kind: ItemKind) -> DetailTab {
        let valid = Self.available(for: kind)
        if valid.contains(self) { return self }
        switch self {
        case .bibtex where kind == .manuscript: return .source
        case .source: return valid.contains(.bibtex) ? .bibtex : .info
        default: return .info
        }
    }
}

extension DetailTab.ItemKind: Equatable {}
