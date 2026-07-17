//
//  CloudKitDispatcher.swift
//  PublicationManagerCore
//
//  Phase 1H landing point for CloudKit sync orchestration on top of the
//  Rust store. Replaces the never-implemented "CoreDataMirror" placeholder.
//
//  Why a dispatcher, not a Core Data mirror
//  ----------------------------------------
//  The Rust-core migration plan originally called for a `CoreDataMirror`
//  actor that reflected Rust-store mutations into a Core Data shadow used
//  solely as CloudKit transport. The plan was drafted before the audit
//  confirmed that imbib has *zero* `import CoreData` in shipping code —
//  the Core Data layer was deliberately retired (see MEMORY.md
//  "imbib Rust Migration Status — COMPLETE").
//
//  We considered two options:
//   (A) Drop the CoreDataMirror concept. Subscribe a dispatcher actor to
//       `ImbibImpressStore.shared.events` and route mutations to the
//       per-schema `CloudKitEngine`s that already exist
//       (`CommentCloudKitEngine`, future tag/library engines).
//   (B) Re-introduce a `NSPersistentCloudKitContainer` *purely* as a
//       transport, so we get Apple's change-token / conflict / share
//       machinery for free.
//
//  We chose (A) — see git history for the full rationale. tl;dr:
//   • Re-introducing Core Data after a deliberate removal would undo a
//     completed migration.
//   • Apple's container brings dozens of new mutation paths during launch
//     — exactly the render-loop pattern in CLAUDE.md.
//   • The hand-written `CommentCloudKitEngine` already works; adding
//     engines per-schema is incremental.
//   • Option (A) is reversible per-schema; (B) is hard to back out.
//
//  Safety model
//  ------------
//  1. `start()` waits 90s before touching anything (startup-render-loop grace).
//  2. After the grace, `start()` reads `CloudKitSyncSettingsStore.cloudKitDispatcherEnabled`.
//     **Default is OFF.** When off, the dispatcher returns without subscribing.
//     A user must flip the flag in settings (or via HTTP automation) and then
//     verify the SHKSharingServicePicker probe before the dispatcher does anything.
//  3. When on, the dispatcher subscribes to `ImbibImpressStore.shared.events`
//     and forwards events to engines via `route(_:)`. Each engine's `sync()`
//     respects its own `isRunning` guard and feature flag — over-firing is
//     harmless because the underlying push/pull steps no-op when there is
//     nothing to do.
//
//  Mandatory pre-merge verification when enabling the flag:
//
//      log show --process imbib --last 15s | grep -c SHKSharingServicePicker
//
//  must be 0 after 90s of runtime on every persistence-touching change.
//

import Foundation
import ImpressLogging
import ImpressStoreKit
import OSLog

// MARK: - CloudKitSyncStatus

/// Uniform status shape every `CloudKitEngine` reports. Top-level (not nested
/// in the engine) so the dispatcher can aggregate across engines without
/// associated-type gymnastics.
public struct CloudKitSyncStatus: Sendable {
    public let isRunning: Bool
    public let lastSyncDate: Date?
    public let lastError: String?
    public let pendingUploadCount: Int

    public init(
        isRunning: Bool,
        lastSyncDate: Date?,
        lastError: String?,
        pendingUploadCount: Int
    ) {
        self.isRunning = isRunning
        self.lastSyncDate = lastSyncDate
        self.lastError = lastError
        self.pendingUploadCount = pendingUploadCount
    }
}

// MARK: - CloudKitEngine

/// Per-schema CloudKit sync engine. Conformers handle push + pull for one
/// kind of syncable data (comments, tags, share membership, …) and report a
/// uniform status. The dispatcher routes `StoreEvent`s here based on
/// `shouldRespond(to:)`.
public protocol CloudKitEngine: Actor {
    /// Stable identifier matching the schema's name in the Rust store
    /// (e.g. "comments", "tags"). Used by the dispatcher for routing and
    /// for aggregating status across engines.
    nonisolated var schemaID: String { get }

    /// Should this engine react to the given event? Called on every event
    /// from a background task — keep it cheap and nonisolated.
    ///
    /// Default implementation responds to `.structural` and to
    /// `.itemsMutated` events whose kind is `.otherField` or `.tag` (text
    /// and metadata edits — the things engines typically care about). Engines
    /// that care about a narrower set (e.g. a tag engine that only watches
    /// `.tag`) should override.
    nonisolated func shouldRespond(to event: StoreEvent) -> Bool

    /// Full sync cycle: push any pending local changes, then pull remote.
    /// Conformers must respect their feature flag in
    /// `CloudKitSyncSettingsStore` and the global `shouldAttemptSync`.
    func sync() async

    /// Snapshot of current sync state for UI / HTTP-API display.
    func status() -> CloudKitSyncStatus
}

public extension CloudKitEngine {
    nonisolated func shouldRespond(to event: StoreEvent) -> Bool {
        switch event {
        case .structural:
            return true
        case .itemsMutated(let kind, _):
            return kind == .otherField || kind == .tag
        case .collectionMembershipChanged:
            return true
        }
    }
}

// MARK: - CloudKitDispatcher

/// Central router that subscribes to `ImbibImpressStore.shared.events`
/// after the startup grace period elapses and dispatches each mutation to
/// the appropriate `CloudKitEngine`.
///
/// Off by default — see `CloudKitSyncSettingsStore.cloudKitDispatcherEnabled`.
public actor CloudKitDispatcher {

    // MARK: - Singleton

    public static let shared = CloudKitDispatcher()

    // MARK: - State

    private var engines: [String: any CloudKitEngine] = [:]
    private var startupGracePassed = false
    private var subscriptionTask: Task<Void, Never>?

    /// Startup grace period before the dispatcher subscribes. Matches the
    /// other background-service grace periods in the project
    /// (InboxScheduler: 90s, FeedScheduler: 90s, BackgroundScheduler: 120s).
    private static let startupGracePeriod: Duration = .seconds(90)

    private init() {
        // Engine registry. Add new engines here as they ship.
        // `CommentCloudKitEngine` conforms in `CommentCloudKitEngine.swift`.
        self.engines = [
            CommentCloudKitEngine.shared.schemaID: CommentCloudKitEngine.shared,
        ]
    }

    // MARK: - Lifecycle

    /// Wait out the startup grace period, then — if the user has opted in
    /// via `CloudKitSyncSettingsStore.cloudKitDispatcherEnabled` — subscribe
    /// to `ImbibImpressStore.shared.events` and start routing.
    ///
    /// Idempotent: safe to call multiple times; subsequent calls are no-ops
    /// while a subscription is already active.
    ///
    /// Call once from app launch (e.g. from `imbibApp.init()` inside a
    /// detached `Task`). The dispatcher itself sleeps for the grace period
    /// before doing any work, so it's safe to call eagerly.
    public func start() {
        guard subscriptionTask == nil else { return }

        subscriptionTask = Task { [weak self] in
            // Single sleep — not a loop with `try?` — so cancellation works.
            // See CLAUDE.md "Startup Render Loop Prevention".
            try? await Task.sleep(for: Self.startupGracePeriod)

            await self?.markGracePassedAndMaybeSubscribe()
        }
    }

    /// Stop the dispatcher. Cancels any in-flight subscription task.
    public func stop() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    private func markGracePassedAndMaybeSubscribe() async {
        startupGracePassed = true

        guard CloudKitSyncSettingsStore.shared.cloudKitDispatcherEnabled else {
            Logger.sync.info(
                "[CloudKitDispatcher] grace period elapsed; dispatcher disabled by user — not subscribing"
            )
            return
        }

        Logger.sync.info(
            "[CloudKitDispatcher] grace period elapsed; subscribing to store events"
        )

        // Fork an unstructured task for the long-lived subscription loop
        // so it does not hold the actor isolation for hours.
        Task.detached { [weak self] in
            let stream = ImbibImpressStore.shared.events.subscribe()
            for await event in stream {
                guard let self else { return }
                await self.route(event)
            }
        }
    }

    // MARK: - Routing

    /// Route a single store event to every engine that wants it. Engines'
    /// `sync()` methods are fire-and-forget — each engine has its own
    /// `isRunning` guard to coalesce concurrent triggers.
    ///
    /// No-op until the startup grace has passed. Safe to call directly from
    /// tests.
    public func route(_ event: StoreEvent) async {
        guard startupGracePassed else { return }

        for (schemaID, engine) in engines where engine.shouldRespond(to: event) {
            Logger.sync.debug(
                "[CloudKitDispatcher] forwarding \(String(describing: event)) → \(schemaID)"
            )
            Task {
                await engine.sync()
            }
        }
    }

    // MARK: - Status

    /// Aggregate status across every registered engine, keyed by `schemaID`.
    /// Used by HTTP automation and the future "Sync" settings panel.
    public func aggregateStatus() async -> [String: CloudKitSyncStatus] {
        var result: [String: CloudKitSyncStatus] = [:]
        for (id, engine) in engines {
            result[id] = await engine.status()
        }
        return result
    }

    /// Register a new engine. Intended for future engines (tags, etc.) and
    /// for tests that need to inject a mock.
    public func register(_ engine: any CloudKitEngine) {
        engines[engine.schemaID] = engine
    }

    /// Test/debug accessor: has the grace period elapsed yet?
    public var isReady: Bool { startupGracePassed }
}
