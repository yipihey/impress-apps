import Foundation
import ImpressLogging

/// Observable store tracking the session's undo history.
///
/// Apps record actions via `recordAction(_:)` and notify undo/redo via
/// `didUndo()` / `didRedo()`. The store maintains a linear timeline with
/// a current-state pointer (`currentIndex`).
@MainActor @Observable
public final class UndoHistoryStore {
    public static let shared = UndoHistoryStore()

    /// All entries in the history. Index 0 is the oldest action.
    public private(set) var entries: [UndoHistoryEntry] = []

    /// Index of the current state. -1 means "session start" (no actions performed).
    /// Entries at indices <= currentIndex are "past" (can be undone).
    /// Entries at indices > currentIndex are "future" (can be redone).
    public private(set) var currentIndex: Int = -1

    /// Maximum number of entries to keep. Configurable from app settings.
    public var maxEntries: Int = 50 {
        didSet { trimIfNeeded() }
    }

    /// Record a new undoable action. Clears any redo history beyond the current point.
    public func recordAction(_ entry: UndoHistoryEntry) {
        // If we're not at the end of the timeline, discard future entries (redo history)
        if currentIndex < entries.count - 1 {
            entries.removeSubrange((currentIndex + 1)...)
        }

        entries.append(entry)
        currentIndex = entries.count - 1

        trimIfNeeded()

        logInfo("Undo history: recorded '\(entry.actionName)' (index \(currentIndex), total \(entries.count))", category: "undo")
    }

    /// Notify that an undo was performed (moves pointer back one step).
    public func didUndo() {
        guard currentIndex >= 0 else { return }
        currentIndex -= 1
        logInfo("Undo history: did undo → index \(currentIndex)", category: "undo")
    }

    /// Notify that a redo was performed (moves pointer forward one step).
    public func didRedo() {
        guard currentIndex < entries.count - 1 else { return }
        currentIndex += 1
        logInfo("Undo history: did redo → index \(currentIndex)", category: "undo")
    }

    /// Whether there are actions that can be undone.
    public var canUndo: Bool { currentIndex >= 0 }

    /// Whether there are actions that can be redone.
    public var canRedo: Bool { currentIndex < entries.count - 1 }

    /// Jump to a specific state by index. Calls the provided closure for each
    /// undo or redo step needed. Returns the number of steps taken.
    @discardableResult
    public func jumpToState(index: Int, performUndo: () -> Void, performRedo: () -> Void) -> Int {
        guard index >= -1, index < entries.count else { return 0 }

        let steps = abs(index - currentIndex)
        if index < currentIndex {
            // Need to undo (walk backwards)
            for _ in 0..<steps {
                performUndo()
            }
        } else if index > currentIndex {
            // Need to redo (walk forwards)
            for _ in 0..<steps {
                performRedo()
            }
        }
        return steps
    }

    /// Reload entries from a Rust store query (for apps with durable operation logs).
    /// This replaces the in-memory entries with the store-sourced ones.
    public func reloadFromStore(_ groups: [UndoHistoryEntry]) {
        entries = groups
        currentIndex = entries.count - 1
        trimIfNeeded()
        logInfo("Undo history: reloaded \(entries.count) entries from store", category: "undo")
    }

    /// Clear all history.
    public func clear() {
        entries.removeAll()
        currentIndex = -1
    }

    // MARK: - Private

    private func trimIfNeeded() {
        guard entries.count > maxEntries else { return }
        let excess = entries.count - maxEntries
        entries.removeFirst(excess)
        currentIndex = max(-1, currentIndex - excess)
    }

    private init() {}
}
