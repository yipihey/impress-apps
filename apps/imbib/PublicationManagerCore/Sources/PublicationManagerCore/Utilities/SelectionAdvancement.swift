//
//  SelectionAdvancement.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

import Foundation
import CoreData

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
    ///   - currentSelection: Currently selected publication (optional)
    /// - Returns: The UUID of the next publication to select, or nil if none remain
    public static func findNextSelection(
        removing idsToRemove: Set<UUID>,
        from publications: [CDPublication],
        currentSelection: CDPublication? = nil
    ) -> UUID? {
        guard !idsToRemove.isEmpty else { return nil }

        // Filter to only valid publications (not deleted, has context)
        let validPublications = publications.filter { pub in
            !pub.isDeleted && pub.managedObjectContext != nil
        }

        // If current selection is not being removed, keep it
        if let current = currentSelection,
           !current.isDeleted,
           current.managedObjectContext != nil,
           !idsToRemove.contains(current.id) {
            return current.id
        }

        // Find indices of selected papers
        let selectedIndices = validPublications.enumerated()
            .filter { idsToRemove.contains($0.element.id) }
            .map { $0.offset }
            .sorted()

        guard let lastIndex = selectedIndices.last else { return nil }

        // Try next paper after the last selected
        let nextIndex = lastIndex + 1
        if nextIndex < validPublications.count {
            let nextPub = validPublications[nextIndex]
            if !idsToRemove.contains(nextPub.id) {
                return nextPub.id
            }
        }

        // Try paper before the first selected
        if let firstIndex = selectedIndices.first, firstIndex > 0 {
            let prevPub = validPublications[firstIndex - 1]
            if !idsToRemove.contains(prevPub.id) {
                return prevPub.id
            }
        }

        // Find any remaining paper not in the selection
        for pub in validPublications where !idsToRemove.contains(pub.id) {
            return pub.id
        }

        return nil
    }

    /// Calculate the next selection and update bindings atomically.
    ///
    /// Use this before modifying the publications array for smooth transitions.
    ///
    /// - Parameters:
    ///   - idsToRemove: Set of publication IDs being removed
    ///   - publications: Current list of publications
    ///   - selectedPublicationIDs: Binding to multi-selection set
    ///   - selectedPublication: Binding to single selection
    /// - Returns: The next publication to select (for updating bindings)
    public static func advanceSelection(
        removing idsToRemove: Set<UUID>,
        from publications: [CDPublication],
        currentSelection: CDPublication?
    ) -> (nextID: UUID?, nextPublication: CDPublication?) {
        let nextID = findNextSelection(
            removing: idsToRemove,
            from: publications,
            currentSelection: currentSelection
        )

        let nextPublication = nextID.flatMap { id in
            publications.first { pub in
                !pub.isDeleted && pub.managedObjectContext != nil && pub.id == id
            }
        }

        return (nextID, nextPublication)
    }
}
