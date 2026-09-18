//
//  PendingPublicationReveal.swift
//  PublicationManagerCore
//
//  A publication that a reveal (a search result, an `imbib://` link, Spotlight)
//  is about to select in the main list.
//
//  Revealing a paper in another library switches the sidebar, which rebuilds the
//  publication list for the new source. The rebuilt list restores ITS saved
//  selection from `ListViewStateStore` as soon as its state loads — and that
//  restore could land after the reveal's own delayed write, silently replacing
//  the paper the user asked for with whatever they last looked at in that
//  library. The list now honours a pending reveal first.
//

import Foundation

@MainActor
public enum PendingPublicationReveal {
    private static var target: (id: UUID, expires: Date)?

    /// Mark `id` as the paper the next list load should select. Expires after a
    /// few seconds so a reveal that never completes cannot hijack a later,
    /// unrelated list load.
    public static func set(_ id: UUID, lifetime: TimeInterval = 5) {
        target = (id, Date().addingTimeInterval(lifetime))
    }

    /// The pending id if it is still fresh and `isInList(id)`; consumed on read.
    public static func take(ifIn isInList: (UUID) -> Bool) -> UUID? {
        guard let current = target, current.expires > Date(), isInList(current.id) else {
            return nil
        }
        target = nil
        return current.id
    }
}
