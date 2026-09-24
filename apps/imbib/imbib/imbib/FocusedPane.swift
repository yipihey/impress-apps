//
//  FocusedPane.swift
//  imbib
//
//  The pre-chassis window's own pane-focus enum. A chassis window's focus is
//  the layout tree's (`LayoutController`), so the type lives here, with the
//  one window that cycles it (`ContentView`).
//

import PublicationManagerCore

/// Which pane of imbib's window has keyboard focus, for h/l cycling and
/// per-pane j/k.
enum FocusedPane: String, Hashable, CaseIterable {
    case sidebar
    case list
    case info
    case pdf
    case notes
    case bibtex

    /// All panes in cycle order (the detail tabs in toolbar order).
    static let allPanes: [FocusedPane] = [.sidebar, .list, .info, .pdf, .notes, .bibtex]

    /// The detail tab this pane shows, if it is one.
    var asDetailTab: DetailTab? {
        switch self {
        case .info: return .info
        case .pdf: return .pdf
        case .notes: return .notes
        case .bibtex: return .bibtex
        case .sidebar, .list: return nil
        }
    }
}
