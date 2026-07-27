#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  RecordDragSession.swift
//  PublicationManagerCore
//
//  In-process record of which records are being dragged, one instance per
//  collection binding (ADR-0022 D3 / G2 remainder #5 — this replaced the two
//  byte-identical singletons `ManuscriptDragSession` and `FigureDragSession`).
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

/// One in-flight drag payload per collection binding (`CollectionBindingID`).
///
/// Sessions are per-binding rather than global because the sidebar's drop
/// handler resolves the fallback from the target folder's
/// `CollectionCapability.bindingID`: a manuscript drag must never satisfy a
/// figure-folder drop, which a single shared buffer would allow.
@MainActor
public final class RecordDragSession: RecordDragSessionProviding {

    /// Kernel binding this session belongs to (`CollectionBindingID`).
    public let bindingID: String

    /// Record IDs in the drag currently in flight, if any.
    public private(set) var draggedIDs: [UUID] = []

    private static var sessions: [String: RecordDragSession] = [:]

    /// The session for a collection binding, created on first use.
    public static func shared(for bindingID: String) -> RecordDragSession {
        if let existing = sessions[bindingID] { return existing }
        let session = RecordDragSession(bindingID: bindingID)
        sessions[bindingID] = session
        return session
    }

    /// Convenience accessors for the two kinds whose list rows drag today.
    public static var manuscript: RecordDragSession {
        shared(for: CollectionBindingID.manuscript)
    }
    public static var figure: RecordDragSession {
        shared(for: CollectionBindingID.figure)
    }

    private init(bindingID: String) {
        self.bindingID = bindingID
    }

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
