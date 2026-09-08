//
//  EInkStartupGate.swift
//  PublicationManagerCore
//
//  The ONE startup gate the e-ink services share (ADR-025 P7). Background
//  services that mutate the store during the first ~90 s of launch trigger
//  the perpetual-render-loop bug the root CLAUDE.md describes, so every
//  automatic e-ink action — a sync, a source fetch, an OCR sweep, the
//  settings migration — waits for this gate; only a person's "Sync now" /
//  "Import now" bypasses it.
//
//  It is a timestamp, not a timer: `isOpen` is a comparison, and
//  `waitUntilOpen()` is ONE `Task.sleep` for the remaining interval — never
//  a chunked loop, whose `try?` would swallow `CancellationError` and make
//  the sleeper uncancellable. A cancelled wait reports `false` so the caller
//  can stop instead of pretending the gate opened.
//

import Foundation

public struct EInkStartupGate: Sendable, Equatable {

    /// The suite-wide startup grace (matches InboxScheduler / FeedScheduler).
    public static let defaultInterval: TimeInterval = 90

    /// When automatic work may begin.
    public let opensAt: Date

    public init(start: Date = Date(), interval: TimeInterval = EInkStartupGate.defaultInterval) {
        opensAt = start.addingTimeInterval(interval)
    }

    /// A gate that is already open — for on-demand callers and tests.
    public static let open = EInkStartupGate(start: .distantPast, interval: 0)

    public var isOpen: Bool { Date() >= opensAt }

    /// Seconds until the gate opens (0 when open).
    public var remaining: TimeInterval { max(0, opensAt.timeIntervalSinceNow) }

    /// Suspend until the gate opens. Returns `false` if the task was
    /// cancelled first — the caller must then do nothing.
    public func waitUntilOpen() async -> Bool {
        let remaining = self.remaining
        guard remaining > 0 else { return !Task.isCancelled }
        do {
            try await Task.sleep(for: .seconds(remaining))
        } catch {
            return false
        }
        return !Task.isCancelled
    }
}
