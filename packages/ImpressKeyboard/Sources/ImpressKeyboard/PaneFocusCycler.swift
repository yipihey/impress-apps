//
//  PaneFocusCycler.swift
//  ImpressKeyboard
//
//  Generic pane focus cycling for vim-style h/l navigation.
//

import SwiftUI

/// Protocol for types that represent a pane in a multi-pane layout.
///
/// Conform your app's pane enum to this protocol and provide `allPanes`
/// in the order they should cycle (left-to-right).
///
/// Example:
/// ```swift
/// enum MyPane: String, PaneFocus {
///     case sidebar, list, detail
///     static let allPanes: [MyPane] = [.sidebar, .list, .detail]
/// }
/// ```
public protocol PaneFocus: Hashable, Sendable {
    /// All panes in left-to-right cycle order.
    static var allPanes: [Self] { get }
}

// MARK: - Cycling Logic

public extension PaneFocus {
    /// The pane to the right of this one (wraps around).
    var next: Self {
        let panes = Self.allPanes
        guard let index = panes.firstIndex(of: self) else { return self }
        return panes[(index + 1) % panes.count]
    }

    /// The pane to the left of this one (wraps around).
    var previous: Self {
        let panes = Self.allPanes
        guard let index = panes.firstIndex(of: self) else { return self }
        return panes[(index - 1 + panes.count) % panes.count]
    }
}

// MARK: - Binding Helpers

public extension Binding where Value: PaneFocus {
    /// Cycle focus to the next pane (right / vim 'l').
    func cycleRight() {
        wrappedValue = wrappedValue.next
    }

    /// Cycle focus to the previous pane (left / vim 'h').
    func cycleLeft() {
        wrappedValue = wrappedValue.previous
    }
}

public extension Binding {
    /// Cycle focus right on an optional pane binding, defaulting to the first pane.
    func cycleRight<P: PaneFocus>() where Value == P? {
        if let current = wrappedValue {
            wrappedValue = current.next
        } else {
            wrappedValue = P.allPanes.first
        }
    }

    /// Cycle focus left on an optional pane binding, defaulting to the last pane.
    func cycleLeft<P: PaneFocus>() where Value == P? {
        if let current = wrappedValue {
            wrappedValue = current.previous
        } else {
            wrappedValue = P.allPanes.last
        }
    }
}
