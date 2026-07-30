//
//  PublicationListOrder.swift
//  PublicationManagerCore
//
//  Stage 5d (SPLIT rule) — one visual order, one selection-advance rule.
//
//  ## What was duplicated, and what it cost
//
//  Rapid triage depends on a single question: after S or D removes the selected
//  papers, which row does the selection land on? Answering it needs the order
//  the user is LOOKING at, computed synchronously, before the mutation. Both
//  hosts had a `computeVisualOrder()` and a `computeNextSelection(removing:)`
//  for exactly that, and the two pairs disagreed on both halves:
//
//  * **Order.** macOS's returns `publications` unchanged for every sort except
//    `.recommended`, because rows arrive pre-sorted from SQL (`ORDER BY` via
//    `LibrarySortOrder.sortKey`) and re-sorting in Swift can only fight it. It
//    has a full `ComparisonResult` comparator for the recommended case with an
//    explicit `.orderedSame` rung and a final `id.uuidString` tie-break, so the
//    order is total. iOS re-sorted ALL rows client-side with a `Bool`
//    comparator — one that is not a strict weak ordering for `.starred`
//    (`lhs.isStarred && !rhs.isStarred` reports "equal" for two starred papers
//    AND for two unstarred ones, which `sorted(by:)` may order arbitrarily).
//  * **Advance.** macOS takes the LAST selected row in visual order and walks
//    down from there, so triaging a multi-row block lands below the block.
//    iOS took `ids.first` — an unordered `Set`'s first element — and walked
//    down from *that*, so triaging a block landed in the middle of it, on a
//    row picked by set iteration order.
//
//  This file is macOS's pair, moved without edits. macOS's own behaviour is
//  therefore unchanged by construction; iOS gets a total order and a
//  deterministic advance.
//
//  A third defect went with them: iOS never used its visual order for display.
//  `PublicationListView` sorts only for `.recommended`, iOS loaded rows once at
//  the store's default `created DESC` and had no `onChange(of: sortOrder)`, so
//  picking a sort in the iOS sort menu changed nothing on screen while
//  `computeVisualOrder()` quietly sorted a copy nobody rendered — and in
//  `handleSaveToLibrary` the result was discarded outright (`_ =
//  computeVisualOrder()`). `PublicationListCore` closes that half by reloading
//  from SQL on a sort change, the way macOS always has.
//

import Foundation

/// The order the user sees, and where selection goes when rows leave it.
///
/// Stateless on purpose: both hosts already own `sortOrder` / `sortAscending` /
/// `recommendationScores` as view state (the wrapper owns them so triage can
/// read them synchronously), so this takes them as arguments rather than
/// becoming a second home for them.
public enum PublicationListOrder {

    /// The visual order of `rows` under the given sort.
    ///
    /// Data arrives pre-sorted from SQL. Only `.recommended` needs client-side
    /// ordering, because the scores are computed in Swift.
    public static func visualOrder(
        _ rows: [PublicationRowData],
        sortOrder: LibrarySortOrder,
        ascending: Bool,
        recommendationScores: [UUID: Double]
    ) -> [PublicationRowData] {
        guard sortOrder == .recommended else { return rows }
        return rows.sorted { lhs, rhs in
            let primaryResult = primaryComparison(
                lhs, rhs,
                sortOrder: sortOrder,
                ascending: ascending,
                recommendationScores: recommendationScores
            )
            if primaryResult != .orderedSame { return primaryResult == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Primary sort comparison — returns `.orderedSame` when items are equal on
    /// the sort key, so the caller can apply a stable tie-break.
    public static func primaryComparison(
        _ lhs: PublicationRowData,
        _ rhs: PublicationRowData,
        sortOrder: LibrarySortOrder,
        ascending sortAscending: Bool,
        recommendationScores: [UUID: Double]
    ) -> ComparisonResult {
        let ascending = sortAscending == sortOrder.defaultAscending

        switch sortOrder {
        case .recommended:
            let lhsScore = recommendationScores[lhs.id] ?? 0
            let rhsScore = recommendationScores[rhs.id] ?? 0
            if lhsScore != rhsScore {
                let result: ComparisonResult = lhsScore > rhsScore ? .orderedAscending : .orderedDescending
                return ascending ? result : result.flipped
            }
            if lhs.dateAdded != rhs.dateAdded {
                let result: ComparisonResult = lhs.dateAdded > rhs.dateAdded ? .orderedAscending : .orderedDescending
                return ascending ? result : result.flipped
            }
            return .orderedSame
        case .dateAdded:
            if lhs.dateAdded == rhs.dateAdded { return .orderedSame }
            let result: ComparisonResult = lhs.dateAdded > rhs.dateAdded ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .dateModified:
            if lhs.dateModified == rhs.dateModified { return .orderedSame }
            let result: ComparisonResult = lhs.dateModified > rhs.dateModified ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .title:
            let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if cmp == .orderedSame { return .orderedSame }
            let result: ComparisonResult = cmp == .orderedAscending ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .year:
            let ly = lhs.year ?? 0, ry = rhs.year ?? 0
            if ly == ry { return .orderedSame }
            let result: ComparisonResult = ly > ry ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .citeKey:
            let cmp = lhs.citeKey.localizedCaseInsensitiveCompare(rhs.citeKey)
            if cmp == .orderedSame { return .orderedSame }
            let result: ComparisonResult = cmp == .orderedAscending ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .citationCount:
            if lhs.citationCount == rhs.citationCount { return .orderedSame }
            let result: ComparisonResult = lhs.citationCount > rhs.citationCount ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .starred:
            if lhs.isStarred != rhs.isStarred {
                let result: ComparisonResult = lhs.isStarred ? .orderedAscending : .orderedDescending
                return ascending ? result : result.flipped
            }
            if lhs.dateAdded == rhs.dateAdded { return .orderedSame }
            let result: ComparisonResult = lhs.dateAdded > rhs.dateAdded ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        case .recentActivity:
            // nil stamp = never touched = distant past. This matches SQLite's
            // NULL ordering (last under DESC, first under ASC) so the local
            // re-sort never fights the server-side ORDER BY.
            let la = lhs.lastActivityAt ?? .distantPast
            let ra = rhs.lastActivityAt ?? .distantPast
            if la != ra {
                let result: ComparisonResult = la > ra ? .orderedAscending : .orderedDescending
                return ascending ? result : result.flipped
            }
            if lhs.dateAdded == rhs.dateAdded { return .orderedSame }
            let result: ComparisonResult = lhs.dateAdded > rhs.dateAdded ? .orderedAscending : .orderedDescending
            return ascending ? result : result.flipped
        }
    }

    /// Where selection goes after `ids` leave the list.
    ///
    /// Advances DOWNWARD from the bottom of the selected block, so triaging a
    /// multi-row selection lands below it rather than inside it; falls back to
    /// the row above the block, then to nil when the list is emptied.
    public static func nextSelection(
        removing ids: Set<UUID>,
        from visualOrder: [PublicationRowData]
    ) -> UUID? {
        // Find the last selected item in visual order (bottom of the selection
        // block). This ensures we advance "downward" from where it ends.
        guard let lastSelectedIndex = visualOrder.lastIndex(where: { ids.contains($0.id) }) else {
            return nil
        }

        // Try the item immediately after the last selected item
        for i in (lastSelectedIndex + 1)..<visualOrder.count {
            if !ids.contains(visualOrder[i].id) {
                return visualOrder[i].id
            }
        }

        // If no next item, try before the first selected item
        if let firstSelectedIndex = visualOrder.firstIndex(where: { ids.contains($0.id) }) {
            for i in (0..<firstSelectedIndex).reversed() {
                if !ids.contains(visualOrder[i].id) {
                    return visualOrder[i].id
                }
            }
        }

        return nil
    }
}
