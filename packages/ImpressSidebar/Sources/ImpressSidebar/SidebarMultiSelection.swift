//
//  SidebarMultiSelection.swift
//  ImpressSidebar
//
//  Multi-selection state with modifier key support for sidebar items.
//

import SwiftUI

/// Result of a multi-selection click operation.
public enum MultiSelectionAction<ID: Hashable & Sendable>: Sendable {
    /// Single item selected (replaces any existing selection).
    case single(ID)
    /// Item toggled in/out of existing selection (Option+click).
    case toggled(ID)
    /// Range selected from last selected to this item (Shift+click).
    case rangeSelected(ClosedRange<Int>)
}

/// Modifier keys relevant to multi-selection.
public struct SelectionModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Option/Alt key held — toggle individual selection.
    public static let option = SelectionModifiers(rawValue: 1 << 0)
    /// Shift key held — range selection.
    public static let shift = SelectionModifiers(rawValue: 1 << 1)

    #if os(macOS)
    /// Read current modifier flags from NSEvent.
    public static var current: SelectionModifiers {
        let flags = NSEvent.modifierFlags
        var result = SelectionModifiers()
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
    #endif
}

/// Manages multi-selection state for sidebar items with modifier key support.
///
/// Supports three selection modes (macOS):
/// - **Option+click**: Toggle individual items in/out of selection
/// - **Shift+click**: Range select from last selected to clicked item
/// - **Plain click**: Replace selection with single item
///
/// On iOS, only single selection is supported.
@MainActor @Observable
public final class SidebarMultiSelection<ID: Hashable & Sendable> {

    /// Currently selected item IDs.
    public var selectedIDs: Set<ID> = []

    /// Last selected item ID, used as the anchor for range selection.
    public var lastSelectedID: ID?

    public init() {}

    /// Handle a click on an item, auto-detecting modifier keys (macOS).
    ///
    /// - Parameters:
    ///   - id: The ID of the clicked item.
    ///   - orderedIDs: All item IDs in display order, used for range selection.
    /// - Returns: The selection action that was performed.
    @discardableResult
    public func handleClick(_ id: ID, orderedIDs: [ID]) -> MultiSelectionAction<ID> {
        #if os(macOS)
        return handleClick(id, orderedIDs: orderedIDs, modifiers: .current)
        #else
        return handleClick(id, orderedIDs: orderedIDs, modifiers: [])
        #endif
    }

    /// Handle a click on an item with explicit modifier keys.
    ///
    /// Use this overload directly in tests or when you have modifier flags from another source.
    ///
    /// - Parameters:
    ///   - id: The ID of the clicked item.
    ///   - orderedIDs: All item IDs in display order, used for range selection.
    ///   - modifiers: Which modifier keys are held.
    /// - Returns: The selection action that was performed.
    @discardableResult
    public func handleClick(_ id: ID, orderedIDs: [ID], modifiers: SelectionModifiers) -> MultiSelectionAction<ID> {
        if modifiers.contains(.option) {
            // Option+click: Toggle selection
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
            lastSelectedID = id
            return .toggled(id)
        } else if modifiers.contains(.shift) {
            // Shift+click: Range selection
            if let range = rangeSelect(to: id, orderedIDs: orderedIDs) {
                return .rangeSelected(range)
            }
            // Fallback when no anchor: treat as single selection
            selectedIDs = [id]
            lastSelectedID = id
            return .single(id)
        }

        // Normal click: Replace selection
        selectedIDs = [id]
        lastSelectedID = id
        return .single(id)
    }

    /// Clear all selection state.
    public func clear() {
        selectedIDs.removeAll()
        lastSelectedID = nil
    }

    /// Check if an item is selected.
    public func isSelected(_ id: ID) -> Bool {
        selectedIDs.contains(id)
    }

    // MARK: - Private

    /// Perform range selection from lastSelectedID to the target ID.
    /// Returns the range of indices that were selected, or nil if range selection was not possible.
    private func rangeSelect(to targetID: ID, orderedIDs: [ID]) -> ClosedRange<Int>? {
        guard let lastID = lastSelectedID,
              let lastIndex = orderedIDs.firstIndex(of: lastID),
              let currentIndex = orderedIDs.firstIndex(of: targetID) else {
            // No previous selection anchor — just add this one
            selectedIDs.insert(targetID)
            lastSelectedID = targetID
            return nil
        }

        let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
        for i in range {
            selectedIDs.insert(orderedIDs[i])
        }
        return range
    }
}
