#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  FigureDragSession.swift
//  PublicationManagerCore
//
//  In-process record of which figures are being dragged — the twin of
//  ManuscriptDragSession (see that file for WHY: SwiftUI `.itemProvider`
//  registers its data representation lazily, and the NSOutlineView sidebar's
//  synchronous `acceptDrop` pasteboard read can come back nil, so the drop
//  handler falls back to this record).
//

import Foundation

@MainActor
public final class FigureDragSession {
    public static let shared = FigureDragSession()

    /// Figure IDs in the drag currently in flight, if any.
    public private(set) var draggedIDs: [UUID] = []

    private init() {}

    public func begin(ids: [UUID]) {
        draggedIDs = ids
    }

    /// Consume the in-flight payload (a drop or a cancelled drag ends it).
    public func take() -> [UUID] {
        let ids = draggedIDs
        draggedIDs = []
        return ids
    }
}
#endif
