#if os(macOS)
// Kit file (ImpressLayout) — macOS-only. ADR-0031 work package L6 (D6).
//
//  PaneSessionRegistry.swift
//  ImpressLayout
//
//  Where a session-bearing pane's session lives: OUTSIDE the view tree.
//
//  ADR-0031 D6 generalizes `ManuscriptSessionRegistry` — an editor, a compose
//  window and a plot canvas all own state that must survive re-layout (an
//  `NSTextView` and its undo stack, an in-flight compile, an unsaved draft).
//  Such a view kind declares itself session-bearing, the pane spec carries a
//  `SessionId`, and **no layout mutation ever tears a session down**. Closing
//  the pane releases the session through this LRU, never through view
//  identity.
//
//  THE INVARIANT THIS EXISTS TO PROTECT:
//
//      The tree view must never put `.id(tile)` on a session-bearing pane's
//      host.
//
//  That is ADR-0018 D4's rule ("the manuscript detail pane must never acquire
//  `.id(manuscriptID)`") restated as a property of every session-bearing
//  pane. `.id` is exactly the thing that destroys and rebuilds an
//  `NSViewRepresentable`'s AppKit view, and rebuilding an `NSTextView` per
//  selection is what made imbib's manuscript list feel sluggish before the
//  session moved out of the view. `LayoutPaneHost` carries the same statement
//  at the one place it could be violated.
//
//  L6 shipped the SHAPE — the protocol, the LRU and its test. W4 pass B
//  gives it its first user: the `source` view kind's `SourcePaneSession`,
//  which owns a pane's editor (`TypstEditorHost`).
//

import Foundation
import ImpressLogging

// MARK: - Session

/// What a session-bearing view kind's session must be able to do.
///
/// Deliberately tiny: the registry's job is lifetime, not behaviour. Anything
/// richer belongs on the concrete session (`ManuscriptEditorSession` and its
/// CAS save are the worked example).
@MainActor
public protocol PaneSession: AnyObject {

    /// The handle the pane spec carries (`PaneSpec.session`). Stable for the
    /// life of the session; the registry keys on it.
    var sessionID: String { get }

    /// Persist whatever is buffered. Called on eviction — a session that
    /// leaves the LRU with unsaved work would lose it, which is the one way
    /// this registry can destroy something.
    func flush()

    /// Drop buffered work WITHOUT persisting. Called when the underlying
    /// record is being deleted: flushing there would write the body back and
    /// resurrect the deleted item (the bug
    /// `ManuscriptSessionRegistry.discard(id:)` exists for).
    func abandon()

    /// Is the session on screen right now? A pinned session is never
    /// evicted: eviction drops the registry's reference, and a pane still
    /// showing the session would then get a SECOND one on its next lookup —
    /// a new editor under the user's hands.
    var isPinned: Bool { get }
}

public extension PaneSession {
    func abandon() {}
    var isPinned: Bool { false }
}

// MARK: - Registry

/// A small LRU of live sessions, keyed by session id.
///
/// `ManuscriptSessionRegistry`'s shape, generic over the session type and
/// over a STRING id (the tree's `SessionId` is a string newtype, and a pane's
/// session need not be a record UUID — a scratch buffer has no record at
/// all).
@MainActor
public final class PaneSessionRegistry<Session: PaneSession> {

    private var sessions: [String: Session] = [:]
    /// Most-recently-used LAST, like the manuscript registry's.
    private var lru: [String] = []
    private let capacity: Int
    private let label: String

    public init(capacity: Int = 3, label: String = "pane") {
        self.capacity = max(1, capacity)
        self.label = label
        // Known to the kit, so a verb that closes a pane releases its
        // session here, and app termination flushes it (SK-K23) — with no
        // host code, for every registry any host makes.
        PaneSessionRegistries.add(self)
    }

    public var count: Int { sessions.count }

    public var liveSessionIDs: [String] { lru }

    /// Every live session, least recently used first.
    public var liveSessions: [Session] { lru.compactMap { sessions[$0] } }

    public func contains(_ id: String) -> Bool { sessions[id] != nil }

    /// The cached session, or one built by `make` — the single entry point,
    /// so a caller cannot accidentally create a second session for one id.
    @discardableResult
    public func session(for id: String, make: () -> Session?) -> Session? {
        if let existing = sessions[id] {
            touch(id)
            return existing
        }
        guard let created = make() else { return nil }
        sessions[id] = created
        lru.append(id)
        evictIfNeeded()
        logInfo("\(label) session \(id) opened (\(sessions.count) live)", category: "layout")
        return created
    }

    /// The cached session without creating one.
    public func existingSession(for id: String) -> Session? {
        guard let existing = sessions[id] else { return nil }
        touch(id)
        return existing
    }

    /// Release a session, flushing it first. A CLOSED pane releases this way
    /// — `LayoutController` names the sessions a verb removed from the tree
    /// and the kit calls this on every registry — while any other layout
    /// mutation (a split, a move, a resize) never does.
    public func release(id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.flush()
        lru.removeAll { $0 == id }
        logInfo("\(label) session \(id) released", category: "layout")
    }

    /// Drop a session whose record is being DELETED: no flush, so a pending
    /// save cannot resurrect the row.
    public func discard(id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.abandon()
        lru.removeAll { $0 == id }
        logInfo("\(label) session \(id) discarded (record deleted)", category: "layout")
    }

    /// Flush everything. The kit calls it when the app terminates.
    public func flushAll() {
        for session in sessions.values { session.flush() }
    }

    private func touch(_ id: String) {
        lru.removeAll { $0 == id }
        lru.append(id)
    }

    private func evictIfNeeded() {
        while sessions.count > capacity {
            // The least recently used session that is not on screen. When
            // every one is, the registry runs over capacity rather than take
            // an editor out from under a visible pane.
            guard let victim = lru.first(where: { sessions[$0]?.isPinned != true }) else { return }
            sessions[victim]?.flush()
            sessions.removeValue(forKey: victim)
            lru.removeAll { $0 == victim }
            logInfo("\(label) session \(victim) evicted (LRU)", category: "layout")
        }
    }
}
#endif
