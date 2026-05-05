//
//  StoreEvent.swift
//  ImpressStoreKit
//
//  The event vocabulary that the store gateway emits and that snapshot
//  maintainers subscribe to. Replaces the app-wide NotificationCenter
//  fan-out (`.storeDidMutate`, `.tagDidChange`, `.readStatusDidChange`,
//  `.flagDidChange`, `.fieldDidChange`) with a single typed AsyncStream.
//
//  Every mutation that the store performs emits exactly one event. A
//  snapshot maintainer reads the event stream on a background actor and
//  updates its in-memory snapshot incrementally — views never query the
//  store during body evaluation.
//
//  Events are deliberately *coarse-grained*. A view that cares about the
//  set of unread papers in a specific feed responds to
//  `.readStateChanged(publicationIDs:)` by asking: "does any of those IDs
//  belong to my feed?". Fine-grained per-feed events would create a
//  combinatorial explosion and push domain knowledge into the store layer.
//

import Foundation

// MARK: - Store event

/// An event emitted by `ImpressStore` in response to a mutation.
///
/// The variants partition mutations by the surfaces they affect, so a
/// subscriber can cheaply skip events that do not touch its surface:
///
/// - `.structural` — the shape of the item graph changed (new library,
///   renamed collection, deleted item, created feed). A snapshot that
///   caches the tree structure rebuilds from scratch.
///
/// - `.itemsMutated(kind:, ids:)` — one or more existing items had their
///   fields mutated in a way that *does* affect display. `kind` narrows
///   the set of fields; `ids` lists the affected items. A snapshot that
///   indexes by item id can do an O(k) update for k ids.
///
/// - `.collectionMembershipChanged(collectionID:)` — the set of items
///   referenced by a specific collection (smart search / feed / SciX
///   library) changed. A snapshot that caches per-collection counts
///   invalidates only that collection.
public enum StoreEvent: Sendable, Equatable {

    /// The shape of the item graph changed (insert, delete, reparent,
    /// rename). Subscribers that cache tree structure must rebuild.
    case structural

    /// One or more items had their mutable fields changed. `kind` narrows
    /// the set of fields; `ids` is the exact set of affected items.
    case itemsMutated(kind: MutationKind, ids: Set<UUID>)

    /// The membership of a specific collection changed — items were added
    /// to or removed from a smart search, feed, or SciX library.
    /// Subscribers that cache per-collection counts invalidate only that
    /// collection.
    case collectionMembershipChanged(collectionID: UUID)
}

// MARK: - Mutation kind

/// Which class of field changed in an `itemsMutated` event.
///
/// This is a narrow enumeration on purpose — adding new kinds forces a
/// deliberate decision about which snapshots need to observe them.
public enum MutationKind: Sendable, Equatable {
    case readState
    case starred
    case flag
    case tag
    /// A catch-all for field mutations that don't fit a narrower kind
    /// (title edits, abstract rewrites, cite key changes, etc.).
    /// Subscribers that don't care about any particular field should
    /// treat this like `.structural` — invalidate the row and re-fetch.
    case otherField
}

// MARK: - Store event publisher

/// A lightweight, thread-safe multicaster for `StoreEvent`s.
///
/// The gateway actor owns a single `StoreEventPublisher`. Subscribers
/// call `subscribe()` to receive an `AsyncStream<StoreEvent>`. Events
/// emitted via `emit()` fan out to every live subscriber; dropped
/// subscribers are cleaned up on the next emit.
///
/// Why not `NotificationCenter`: notifications are `@MainActor` in Swift
/// 6 and re-entering the main thread for every mutation is exactly the
/// fan-out pattern we are trying to replace. An `AsyncStream` runs on
/// the subscriber's executor, which is typically a background actor.
public final class StoreEventPublisher: @unchecked Sendable {

    // Guarded by `lock`. Each subscription has a continuation we push
    // events into; when a continuation is finished (subscriber dropped)
    // we prune it.
    private final class Subscription {
        let id: UUID
        var continuation: AsyncStream<StoreEvent>.Continuation?
        init(id: UUID, continuation: AsyncStream<StoreEvent>.Continuation) {
            self.id = id
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var subscriptions: [Subscription] = []

    public init() {}

    /// Emit an event to every live subscriber. Safe to call from any
    /// thread — this is the primary entry point for mutation notifications.
    public func emit(_ event: StoreEvent) {
        lock.lock()
        let active = subscriptions.filter { $0.continuation != nil }
        self.subscriptions = active
        let targets = active
        lock.unlock()

        for sub in targets {
            sub.continuation?.yield(event)
        }
    }

    /// Subscribe to the event stream. The returned stream stays open
    /// until the caller cancels or the subscription is finished.
    public func subscribe() -> AsyncStream<StoreEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let id = UUID()
            let sub = Subscription(id: id, continuation: continuation)

            self.lock.lock()
            self.subscriptions.append(sub)
            self.lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscriptions.removeAll { $0.id == id }
                self.lock.unlock()
            }
        }
    }

    /// Drop all subscribers and prevent further emissions. Used in tests
    /// and during app shutdown.
    public func close() {
        lock.lock()
        let toFinish = subscriptions
        subscriptions.removeAll()
        lock.unlock()
        for sub in toFinish {
            sub.continuation?.finish()
        }
    }
}
