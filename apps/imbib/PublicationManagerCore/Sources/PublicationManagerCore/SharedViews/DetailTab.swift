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

    // Kind-aware availability moved to RecordKindDescriptor (ADR-0021):
    // descriptors declare tabs + availability per record kind;
    // `descriptor.availableTabs(for:)` / `coercedTab(_:for:)` replace the
    // old closed ItemKind enum (deleted in S1-WP7b).
}
