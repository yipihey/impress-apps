#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  FocusedPane.swift
//  Moved from the imbib app target's ContentView.swift (GUI-meld Phase 1) —
//  the chassis list wrapper drives pane focus, so the type lives with it.
//

import Foundation

/// Represents which pane currently has keyboard focus for vim-style navigation.
/// Used for h/l cycling and j/k per-pane behavior.
public enum FocusedPane: String, Hashable, CaseIterable {
    case sidebar
    case list
    case info
    case pdf
    case notes
    case bibtex

    /// All panes in cycle order (same as toolbar tab order for detail tabs)
    public static let allPanes: [FocusedPane] = [.sidebar, .list, .info, .pdf, .notes, .bibtex]

    /// Whether this pane is a detail tab (info, pdf, notes, bibtex)
    public var isDetailTab: Bool {
        switch self {
        case .info, .pdf, .notes, .bibtex:
            return true
        case .sidebar, .list:
            return false
        }
    }

    /// Convert to DetailTab if this is a detail pane
    public var asDetailTab: DetailTab? {
        switch self {
        case .info: return .info
        case .pdf: return .pdf
        case .notes: return .notes
        case .bibtex: return .bibtex
        case .sidebar, .list: return nil
        }
    }

    /// Create from DetailTab
    public static func from(_ detailTab: DetailTab) -> FocusedPane {
        switch detailTab {
        case .info: return .info
        case .pdf: return .pdf
        case .notes: return .notes
        case .bibtex: return .bibtex
        }
    }
}
#endif
