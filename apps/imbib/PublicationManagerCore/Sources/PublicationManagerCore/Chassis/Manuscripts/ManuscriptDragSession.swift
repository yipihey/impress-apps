#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  ManuscriptDragSession.swift
//  PublicationManagerCore
//
//  In-process record of which manuscripts are being dragged.
//
//  Why this exists: a SwiftUI `List` row's `.itemProvider` registers its data
//  representation LAZILY. When the drop lands on the AppKit `NSOutlineView`
//  sidebar, `acceptDrop` reads the pasteboard synchronously — and a promised
//  representation can come back nil there, so the drop is accepted visually
//  and then silently does nothing. The drag source records its payload here;
//  the drop handler falls back to it when the pasteboard read comes up empty.
//  (imprint's pre-chassis sidebar carried the same workaround.)
//

import Foundation

/// The pasteboard-fallback contract the sidebar's generic folder-drop handler
/// needs (ADR-0022 D3), so it does not have to name a per-kind singleton.
@MainActor
public protocol RecordDragSessionProviding: AnyObject {
    /// Consume the in-flight payload (a drop or a cancelled drag ends it).
    func take() -> [UUID]
}

@MainActor
public final class ManuscriptDragSession: RecordDragSessionProviding {
    public static let shared = ManuscriptDragSession()

    /// Manuscript IDs in the drag currently in flight, if any.
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
