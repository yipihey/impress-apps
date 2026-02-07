//
//  DetailTab.swift
//  PublicationManagerCore
//
//  Shared detail tab enum used by both macOS and iOS detail views.
//

/// Represents the available tabs in the publication detail view.
/// Shared across macOS and iOS platforms.
public enum DetailTab: String, CaseIterable, Identifiable, Sendable {
    case info
    case pdf
    case notes
    case bibtex

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .info: "Info"
        case .pdf: "PDF"
        case .notes: "Notes"
        case .bibtex: "BibTeX"
        }
    }

    public var icon: String {
        switch self {
        case .info: "info.circle"
        case .pdf: "doc.richtext"
        case .notes: "note.text"
        case .bibtex: "chevron.left.forwardslash.chevron.right"
        }
    }
}
