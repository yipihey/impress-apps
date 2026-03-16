//
//  ScopeSelectionController.swift
//  imprint
//
//  Manages keyboard-driven structural scope selection for the source editor.
//
//  Key bindings (intercepted in TypstTextView before Helix):
//    Cmd+Shift+]  →  Expand selection to next coarser structural scope
//    Cmd+Shift+[  →  Shrink selection to next finer structural scope
//
//  These shortcuts work regardless of Helix mode. When the selection is
//  expanded via scope, the ScopeBracketOverlay reflects the active scope level.
//

import AppKit
import Foundation

// MARK: - Scope Selection Controller

/// Manages structural scope selection state for a text view.
///
/// Maintains the current expanded scope level so that repeated Expand/Shrink
/// keypresses cycle predictably through the scope hierarchy.
@MainActor
@Observable
public final class ScopeSelectionController {

    // MARK: - State

    /// The scope level currently selected (nil = no scope-driven selection active).
    public private(set) var activeScope: TextScope?

    /// All scopes available at the last cursor position (finest → coarsest).
    public private(set) var availableScopes: [TextScope] = []

    // MARK: - Dependencies

    private let analyzer: StructuralScopeAnalyzer

    // MARK: - Init

    public init(analyzer: StructuralScopeAnalyzer = .shared) {
        self.analyzer = analyzer
    }

    // MARK: - Scope Refresh

    /// Recompute available scopes for the current cursor position.
    /// Call this whenever the cursor moves or text changes.
    public func refreshScopes(source: String, cursorPosition: Int, format: DocumentFormat) {
        Task {
            let scopes = await analyzer.scopes(in: source, at: cursorPosition, format: format)
            self.availableScopes = scopes
            // Clear active scope when cursor moves without expand/shrink action
            self.activeScope = nil
        }
    }

    // MARK: - Expand / Shrink

    /// Expand the selection to the next coarser structural scope.
    ///
    /// - Parameters:
    ///   - textView: The text view whose selection should be updated.
    ///   - source: The current document source.
    ///   - format: The document format (.typst or .latex).
    public func expandSelection(in textView: NSTextView, source: String, format: DocumentFormat) {
        Task {
            let cursorPosition = textView.selectedRange().location
            let scopes = await analyzer.scopes(in: source, at: cursorPosition, format: format)

            guard !scopes.isEmpty else { return }

            let currentSelection = textView.selectedRange()

            // Find the next scope larger than the current selection
            let nextScope: TextScope?
            if let active = self.activeScope {
                // Already on a scope — move to next coarser one
                nextScope = scopes.first(where: { $0.level > active.level })
            } else if currentSelection.length == 0 {
                // No selection — start at word
                nextScope = scopes.first
            } else {
                // Selection exists but not scope-driven — find the smallest scope that encompasses it
                nextScope = scopes.first(where: { NSIntersectionRange($0.range, currentSelection).length == currentSelection.length })
                    .flatMap { current in scopes.first(where: { $0.level > current.level }) }
                    ?? scopes.first(where: { $0.range.length >= currentSelection.length })
            }

            guard let scope = nextScope else { return }
            self.activeScope = scope
            self.availableScopes = scopes
            textView.setSelectedRange(scope.range)
            textView.scrollRangeToVisible(scope.range)
        }
    }

    /// Shrink the selection to the next finer structural scope.
    ///
    /// - Parameters:
    ///   - textView: The text view whose selection should be updated.
    ///   - source: The current document source.
    ///   - format: The document format.
    public func shrinkSelection(in textView: NSTextView, source: String, format: DocumentFormat) {
        Task {
            let cursorPosition = textView.selectedRange().location
            let scopes = await analyzer.scopes(in: source, at: cursorPosition, format: format)

            guard !scopes.isEmpty else { return }

            // Find the next scope finer than the current active scope
            let prevScope: TextScope?
            if let active = self.activeScope {
                prevScope = scopes.last(where: { $0.level < active.level })
            } else {
                prevScope = nil
            }

            guard let scope = prevScope else {
                // Already at finest scope — just move cursor (deselect)
                let loc = textView.selectedRange().location
                textView.setSelectedRange(NSRange(location: loc, length: 0))
                self.activeScope = nil
                return
            }

            self.activeScope = scope
            self.availableScopes = scopes
            textView.setSelectedRange(scope.range)
            textView.scrollRangeToVisible(scope.range)
        }
    }

    /// Jump directly to a specific scope level.
    public func selectScope(
        _ level: ScopeLevel,
        in textView: NSTextView,
        source: String,
        format: DocumentFormat
    ) {
        Task {
            let cursorPosition = textView.selectedRange().location
            let scopes = await analyzer.scopes(in: source, at: cursorPosition, format: format)

            self.availableScopes = scopes
            guard let scope = scopes.first(where: { $0.level == level }) else { return }
            self.activeScope = scope
            textView.setSelectedRange(scope.range)
            textView.scrollRangeToVisible(scope.range)
        }
    }

    /// Clear the active scope (e.g., when user types or moves cursor).
    public func clearActiveScope() {
        activeScope = nil
    }
}
