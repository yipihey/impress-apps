//
//  SelectionAdvancement.swift
//  PublicationManagerCore
//
//  Utility for calculating next selection after removing publications from a list.
//

import Foundation

/// Utility for calculating next selection after removing publications from a list.
///
/// This provides consistent behavior across iOS and macOS when triaging papers -
/// the next paper is automatically selected (like Mail's archive behavior).
public struct SelectionAdvancement {

    // MARK: - Public API

    /// Find the next publication ID to select after removing the given IDs.
    ///
    /// Selection logic:
    /// 1. Try to select the paper immediately after the last removed paper
    /// 2. If at end of list, select the paper before the first removed paper
    /// 3. If no papers remain, return nil
    ///
    /// - Parameters:
    ///   - idsToRemove: Set of publication IDs being removed
    ///   - publications: Current list of publications (in display order)
    ///   - currentSelectionID: Currently selected publication ID (optional)
    /// - Returns: The UUID of the next publication to select, or nil if none remain
    public static func findNextSelection(
        removing idsToRemove: Set<UUID>,
        from publications: [PublicationRowData],
        currentSelectionID: UUID? = nil
    ) -> UUID? {
        guard !idsToRemove.isEmpty else { return nil }

        // If current selection is not being removed, keep it
        if let currentID = currentSelectionID,
           !idsToRemove.contains(currentID) {
            return currentID
        }

        // Find indices of selected papers
        let selectedIndices = publications.enumerated()
            .filter { idsToRemove.contains($0.element.id) }
            .map { $0.offset }
            .sorted()

        guard let lastIndex = selectedIndices.last else { return nil }

        // Try next paper after the last selected
        let nextIndex = lastIndex + 1
        if nextIndex < publications.count {
            let nextPub = publications[nextIndex]
            if !idsToRemove.contains(nextPub.id) {
                return nextPub.id
            }
        }

        // Try paper before the first selected
        if let firstIndex = selectedIndices.first, firstIndex > 0 {
            let prevPub = publications[firstIndex - 1]
            if !idsToRemove.contains(prevPub.id) {
                return prevPub.id
            }
        }

        // Find any remaining paper not in the selection
        for pub in publications where !idsToRemove.contains(pub.id) {
            return pub.id
        }

        return nil
    }

    /// Calculate the next selection and return the ID.
    ///
    /// Use this before modifying the publications array for smooth transitions.
    ///
    /// - Parameters:
    ///   - idsToRemove: Set of publication IDs being removed
    ///   - publications: Current list of publications
    ///   - currentSelectionID: Currently selected publication ID
    /// - Returns: The next publication ID to select, or nil if none remain
    public static func advanceSelection(
        removing idsToRemove: Set<UUID>,
        from publications: [PublicationRowData],
        currentSelectionID: UUID?
    ) -> UUID? {
        findNextSelection(
            removing: idsToRemove,
            from: publications,
            currentSelectionID: currentSelectionID
        )
    }
}
