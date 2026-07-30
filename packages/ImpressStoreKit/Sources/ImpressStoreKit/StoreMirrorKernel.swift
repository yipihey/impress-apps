//
//  StoreMirrorKernel.swift
//  ImpressStoreKit
//
//  The generic half of a "store mirror" — the pattern every app that keeps its
//  own source of truth (Core Data, a JSON library, a Rust task kernel) uses to
//  MIRROR that truth into the shared impress item store so the other apps can
//  see it.
//
//  Three adapters had grown the same shape independently:
//
//    * `MessageManagerCore.MailStoreMirror`  (impart — Core Data is the truth)
//    * `ImploreCore.ImploreStoreAdapter`     (implore — the JSON library is)
//    * `ImpelCore.ImpelStoreAdapter`         (impel — impel-taskd's rows are)
//
//  What they share is NOT the row mapping — that is irreducibly app-specific
//  and stays in each adapter. What they share is the plumbing around it:
//
//    1. `LazyStoreHandle` — open the shared store once, under a lock, remember
//       the failure instead of retrying forever.
//    2. `StoreMirrorPayload` — `[String: Any]` → deterministic JSON.
//    3. `StoreMirrorUpsert` / `StoreMirrorOp` — a Sendable row and op
//       vocabulary that crosses actor boundaries without dragging the UniFFI
//       types into every signature.
//    4. `StoreMirrorWriteGate` — the startup-embargo buffer, the ordered
//       flush, and the batched apply.
//    5. `StoreMutationSignal` — `didMutate()`: bump a version, fan out a
//       `StoreEvent`.
//
//  ## Why this is a protocol and not a `SharedStore` wrapper
//
//  `StoreMirrorBackend` is deliberately the only thing the gate knows about the
//  store. That buys three things:
//
//    * ImpressStoreKit keeps NO dependency on `ImpressRustCore`, so it does not
//      inherit the XCFramework build requirement. (All three adapters guard
//      their FFI use with `#if canImport(ImpressRustCore)` precisely because
//      that framework is not always present.)
//    * The buffering/ordering/batching logic — which had zero test coverage in
//      its original home, and which enforces a documented startup invariant —
//      becomes testable against an in-memory fake.
//    * A future non-SQLite mirror target costs a conformance, not a fork.
//
//  ## The startup invariant this exists to enforce
//
//  From the root CLAUDE.md: no store mutations may happen in the first ~90
//  seconds after launch. A `.storeDidMutate` during that window triggers
//  SwiftUI body re-evaluations that compound into a perpetual render loop (the
//  spinning beach ball). `StoreMirrorWriteGate` is the enforcement point: every
//  write goes through `dispatch(ops:)`, which buffers during the window and
//  flushes in order once it passes.
//

import Foundation

// MARK: - StoreMirrorUpsert

/// One row to mirror into the shared item store: the payload plus the envelope
/// fields the store keeps outside the payload (parent, tags, created, flags).
///
/// This is a Sendable value type so mapped rows can cross actor boundaries — a
/// Core Data background context mapping messages, an actor running IMAP sync,
/// a `@MainActor` view model — without importing the UniFFI row type into
/// every signature. Adapters convert to their FFI row at the write site, inside
/// their `StoreMirrorBackend` conformance.
///
/// The property names deliberately match the FFI `SharedItemUpsert`'s, so the
/// conversion is field-for-field and reads as a no-op.
public struct StoreMirrorUpsert: Sendable, Equatable {
    /// Stable item id. Mirrors converge only if this is DERIVED (a deterministic
    /// hash of the source's own key), never freshly generated per write.
    public var id: String
    /// The item's schema ref. Matched by EXACT equality by the store — copy the
    /// spelling from the manifest, never from a sibling call site.
    public var schemaRef: String
    /// The item payload as a JSON object string (see `StoreMirrorPayload`).
    public var payloadJson: String
    /// Envelope parent id, or `nil` for a root item.
    public var parentId: String?
    /// Envelope tags.
    public var tags: [String]
    /// Envelope creation time in epoch milliseconds. Carry the SOURCE's real
    /// timestamp here — otherwise every mirrored row sorts by import order.
    public var createdMs: Int64?
    /// Envelope read flag, or `nil` to leave it untouched.
    public var isRead: Bool?
    /// Envelope starred flag, or `nil` to leave it untouched.
    public var isStarred: Bool?

    public init(
        id: String,
        schemaRef: String,
        payloadJson: String,
        parentId: String? = nil,
        tags: [String] = [],
        createdMs: Int64? = nil,
        isRead: Bool? = nil,
        isStarred: Bool? = nil
    ) {
        self.id = id
        self.schemaRef = schemaRef
        self.payloadJson = payloadJson
        self.parentId = parentId
        self.tags = tags
        self.createdMs = createdMs
        self.isRead = isRead
        self.isStarred = isStarred
    }
}

// MARK: - StoreMirrorOp

/// A single mirror mutation, in a form that can sit in a buffer.
///
/// Ops are applied in array order and ORDER IS SEMANTIC: parents must be
/// upserted before their children, and an envelope flag change must land after
/// the row it refers to exists. `StoreMirrorWriteGate` never reorders ops; it
/// only decides *when* they run and how many share a transaction.
public enum StoreMirrorOp: Sendable, Equatable {
    /// Insert or update a row.
    case upsert(StoreMirrorUpsert)
    /// Set the envelope read flag on an existing row.
    case setRead(id: String, read: Bool)
    /// Reparent an existing row (`nil` detaches it to the root).
    case setParent(id: String, parentId: String?)
}

/// What a batched upsert did, for logging and for backfill progress.
public struct StoreMirrorBatchOutcome: Sendable, Equatable {
    public var inserted: Int
    public var updated: Int

    public init(inserted: Int, updated: Int) {
        self.inserted = inserted
        self.updated = updated
    }

    public static let none = StoreMirrorBatchOutcome(inserted: 0, updated: 0)
}

// MARK: - StoreMirrorBackend

/// The four verbs a mirror needs from a store. Conformances are thin — they
/// convert `StoreMirrorUpsert` to the FFI row and forward.
///
/// Every method may throw; the gate logs and CONTINUES rather than abandoning
/// the remaining ops, because a mirror that stops at the first bad row leaves
/// the store in a half-mirrored state that looks like missing data forever.
public protocol StoreMirrorBackend: Sendable {
    /// Upsert many rows in ONE transaction. Used on the flush path, where
    /// throughput matters and the rows are already in hand.
    func upsertBatch(_ rows: [StoreMirrorUpsert]) throws -> StoreMirrorBatchOutcome
    /// Upsert a single row. Used on the live path, where latency matters and
    /// batching would only add a transaction boundary.
    func upsertOne(_ row: StoreMirrorUpsert) throws
    /// Set the envelope read flag. Throwing "not found" is EXPECTED for rows
    /// that have not been mirrored yet and must not be treated as an error.
    func setRead(id: String, isRead: Bool) throws
    /// Reparent a row.
    func setParent(id: String, parentId: String?) throws
}

// MARK: - StoreMirrorLog

/// Where the gate's diagnostics go.
///
/// A struct of closures rather than a protocol so each app keeps its OWN logger,
/// category and capture behaviour (`Logger.impartStore.infoCapture(…,
/// category: "store")`) with byte-identical messages — the console is the
/// primary debugging surface for this code and its log lines are the
/// three-point trace.
public struct StoreMirrorLog: Sendable {
    public var info: @Sendable (String) -> Void
    public var warning: @Sendable (String) -> Void
    public var error: @Sendable (String) -> Void

    public init(
        info: @escaping @Sendable (String) -> Void,
        warning: @escaping @Sendable (String) -> Void,
        error: @escaping @Sendable (String) -> Void
    ) {
        self.info = info
        self.warning = warning
        self.error = error
    }

    /// Discards everything. For tests and for callers that have no console.
    public static let silent = StoreMirrorLog(info: { _ in }, warning: { _ in }, error: { _ in })
}

// MARK: - StoreMirrorWriteGate

/// The gated, ordered, batched write path for a store mirror.
///
/// ## Behaviour contract
///
/// * **Embargo.** Ops dispatched within `startupGraceSeconds` of `init` are
///   buffered, not applied. Exactly one drain is scheduled, for the moment the
///   window closes (+1 s of slack).
/// * **Ordering.** A live dispatch first drains anything still buffered, so an
///   op dispatched later never lands before one dispatched earlier.
/// * **Batching.** The flush path groups CONSECUTIVE upserts into
///   `upsertBatch` calls of at most `maxBatchRows`. A non-upsert op flushes the
///   pending batch first, so op order survives batching. The live path uses
///   `upsertOne`.
/// * **Resilience.** A throwing op is logged and skipped; the run continues.
/// * **Signal.** `onApplied` fires ONCE per apply, with the number of ops that
///   succeeded, and only when that number is > 0.
public final class StoreMirrorWriteGate: @unchecked Sendable {

    // MARK: Configuration

    /// Startup invariant: no store mutations in the first N seconds after
    /// launch. See the file header for what happens if this is violated.
    public let startupGraceSeconds: TimeInterval

    /// Maximum rows per batched transaction. Keep transactions short: the
    /// shared SQLite database is in WAL mode and has other writers (impel-taskd
    /// writes every 5 s), so a long transaction shows up as contention in a
    /// different app.
    public let maxBatchRows: Int

    // MARK: Collaborators

    private let backend: @Sendable () -> StoreMirrorBackend?
    private let log: StoreMirrorLog
    private let onApplied: @Sendable (Int) -> Void

    // MARK: State (lock-guarded)

    private let lock = NSLock()
    private var pendingOps: [StoreMirrorOp] = []
    private var flushScheduled = false
    private let launchDate: Date

    /// - Parameters:
    ///   - startupGraceSeconds: The mutation embargo window.
    ///   - maxBatchRows: Rows per batched transaction on the flush path.
    ///   - launchDate: When the clock started. Injectable so tests can put the
    ///     grace window in the past (or the far future) without sleeping.
    ///   - backend: Resolved lazily on each apply, because the store handle is
    ///     itself opened lazily and may never open at all.
    ///   - log: Diagnostics sink.
    ///   - onApplied: Called with the successfully-applied op count after each
    ///     apply, when that count is > 0. This is where `didMutate()` goes.
    public init(
        startupGraceSeconds: TimeInterval,
        maxBatchRows: Int,
        launchDate: Date = Date(),
        backend: @escaping @Sendable () -> StoreMirrorBackend?,
        log: StoreMirrorLog = .silent,
        onApplied: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.startupGraceSeconds = startupGraceSeconds
        self.maxBatchRows = maxBatchRows
        self.launchDate = launchDate
        self.backend = backend
        self.log = log
        self.onApplied = onApplied
    }

    // MARK: Startup grace gate

    /// Whether the startup mutation embargo has elapsed.
    public var isPastStartupGrace: Bool {
        Date().timeIntervalSince(launchDate) >= startupGraceSeconds
    }

    /// How many ops are waiting for the window to close.
    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingOps.count
    }

    // MARK: Write path

    /// Apply `ops` now, or buffer them until the startup window closes.
    public func dispatch(ops: [StoreMirrorOp]) {
        guard !ops.isEmpty else { return }
        if isPastStartupGrace {
            // Preserve ordering: drain anything still buffered from the
            // grace window before applying the new operations.
            flushPendingOps()
            apply(ops: ops, batched: false)
        } else {
            buffer(ops: ops)
        }
    }

    /// Drain and apply everything buffered (no-op when empty). Exposed so a
    /// caller with its own lifecycle signal — or a test — can force the drain.
    public func flushPendingOps() {
        lock.lock()
        let ops = pendingOps
        pendingOps.removeAll()
        lock.unlock()
        guard !ops.isEmpty else { return }
        log.info("Startup grace over: flushing \(ops.count) buffered store ops")
        apply(ops: ops, batched: true)
    }

    private func buffer(ops: [StoreMirrorOp]) {
        lock.lock()
        pendingOps.append(contentsOf: ops)
        let pendingCount = pendingOps.count
        let needsSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()

        log.info("Startup grace: buffered \(ops.count) store ops (pending: \(pendingCount))")

        if needsSchedule {
            let remaining = max(0, startupGraceSeconds - Date().timeIntervalSince(launchDate)) + 1
            Task.detached { [weak self] in
                // A single sleep, not a loop: `try?` around `Task.sleep` inside
                // a loop swallows CancellationError and makes the loop
                // uncancellable (see CLAUDE.md, Background Services).
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                self?.flushPendingOps()
            }
        }
    }

    /// Apply operations in order. `batched: true` groups consecutive upserts
    /// into `upsertBatch` transactions of at most `maxBatchRows` (the flush
    /// path); `batched: false` uses `upsertOne` (the live path).
    private func apply(ops: [StoreMirrorOp], batched: Bool) {
        guard let backend = backend() else {
            log.warning("store not open — dropping \(ops.count) ops")
            return
        }

        var batch: [StoreMirrorUpsert] = []
        var applied = 0

        func flushBatch() {
            guard !batch.isEmpty else { return }
            do {
                let result = try backend.upsertBatch(batch)
                applied += batch.count
                log.info(
                    "upsertItems: \(batch.count) rows (inserted \(result.inserted), updated \(result.updated))"
                )
            } catch {
                log.error("upsertItems failed for \(batch.count) rows — \(error)")
            }
            batch.removeAll(keepingCapacity: true)
        }

        for op in ops {
            switch op {
            case .upsert(let row):
                if batched {
                    batch.append(row)
                    if batch.count >= maxBatchRows { flushBatch() }
                } else {
                    do {
                        try backend.upsertOne(row)
                        applied += 1
                    } catch {
                        log.error("upsertItemV2 failed for \(row.id) — \(error)")
                    }
                }
            case .setRead(let id, let read):
                flushBatch()   // preserve op ordering across kinds
                do {
                    try backend.setRead(id: id, isRead: read)
                    applied += 1
                } catch {
                    // NotFound is expected for rows not yet mirrored.
                    log.info("setRead skipped for \(id) — \(error)")
                }
            case .setParent(let id, let parentId):
                flushBatch()   // preserve op ordering across kinds
                do {
                    try backend.setParent(id: id, parentId: parentId)
                    applied += 1
                } catch {
                    log.info("setParent skipped for \(id) — \(error)")
                }
            }
        }
        flushBatch()

        if applied > 0 { onApplied(applied) }
    }
}

// MARK: - LazyStoreHandle

/// A store handle opened at most once, under a lock, remembering its failure.
///
/// The three adapters each hand-rolled this, and one of the three (impel's)
/// retried the open on every call — so a missing database meant an exception
/// per query for the life of the process. `openAttempted` is the fix: one
/// attempt, then a cached answer.
///
/// Generic over the handle type so ImpressStoreKit never names the FFI store.
public final class LazyStoreHandle<Handle>: @unchecked Sendable {

    private let lock = NSLock()
    private var handle: Handle?
    private var openAttempted = false
    private var _lastError: String?

    private let open: () throws -> Handle
    private let onOpen: (Handle) -> Void
    private let log: StoreMirrorLog

    /// - Parameters:
    ///   - log: Diagnostics sink.
    ///   - onOpen: Ran once, inside the lock, on the first successful open.
    ///     This is where one-time declarations belong (e.g. registering
    ///     sync-excluded schemas) so they cannot be skipped or repeated.
    ///   - open: Performs the open. Called at most once.
    public init(
        log: StoreMirrorLog = .silent,
        onOpen: @escaping (Handle) -> Void = { _ in },
        open: @escaping () throws -> Handle
    ) {
        self.log = log
        self.onOpen = onOpen
        self.open = open
    }

    /// The handle, opening it on first use. `nil` once an attempt has failed.
    public func get() -> Handle? {
        lock.lock()
        defer { lock.unlock() }
        if let handle { return handle }
        if openAttempted { return nil }
        openAttempted = true
        do {
            let opened = try open()
            handle = opened
            onOpen(opened)
            return opened
        } catch {
            _lastError = error.localizedDescription
            log.error("failed to open store — \(error.localizedDescription)")
            return nil
        }
    }

    /// The failure from the one open attempt, if it failed.
    public var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastError
    }

    /// Whether a handle is available (opening it if it has not been tried).
    public var isReady: Bool { self.get() != nil }

    /// Inject a pre-opened handle — for tests using an in-memory store, and for
    /// UI-test seeding. Marks the open as attempted so `open` never runs.
    public func adopt(_ handle: Handle) {
        lock.lock()
        self.handle = handle
        openAttempted = true
        _lastError = nil
        lock.unlock()
    }
}

// MARK: - StoreMirrorPayload

/// Item payload encoding, in one place because every mirror needs it and the
/// details matter.
public enum StoreMirrorPayload {

    /// Encode a payload object to a JSON string with **sorted keys**.
    ///
    /// Sorted keys are not cosmetic: mirrors re-upsert the same logical row
    /// whenever their source changes, and the store compares payloads to decide
    /// insert-vs-update. Unsorted `JSONSerialization` output varies by
    /// dictionary iteration order, which would make byte-identical payloads
    /// look different and churn `modified` timestamps on every sync.
    ///
    /// Returns `"{}"` rather than throwing: a mirror must never abort a sync
    /// because one row had an unencodable value.
    ///
    /// - Note: the `isValidJSONObject` pre-check is not redundant.
    ///   `JSONSerialization.data(withJSONObject:)` raises an **NSException** —
    ///   not a Swift error — for an object graph containing a non-JSON value
    ///   (a `Date`, a `URL`, an `NSNull`-free custom class). `try?` does not
    ///   catch that, so the process traps. Every one of the hand-rolled copies
    ///   of this helper had the same latent crash; a payload builder that picks
    ///   up a `Date` by accident is an entirely ordinary mistake.
    public static func encodeJSON(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// Encode a payload, or return `nil` if it cannot be encoded.
    ///
    /// Use this where writing an EMPTY payload would be worse than writing
    /// nothing — a mirror that stores `{}` for a figure has replaced the row's
    /// metadata with silence, whereas skipping leaves the previous version
    /// intact and the next sync retries.
    public static func encodeJSONIfValid(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// Encode a payload whose values may be `nil`, dropping the nil entries;
    /// `nil` if the remainder cannot be encoded.
    public static func encodeJSONIfValid(_ object: [String: Any?]) -> String? {
        encodeJSONIfValid(object.compactMapValues { $0 })
    }

    /// Encode a payload whose values may be `nil`, dropping the nil entries.
    ///
    /// Omitting a key is not the same as writing `null`: schema validation and
    /// the payload-equality query (`payloadEq`) both treat an explicit null as a
    /// value. Mirrors want absence.
    public static func encodeJSON(_ object: [String: Any?]) -> String {
        encodeJSON(object.compactMapValues { $0 })
    }
}

// MARK: - StoreMutationSignal

/// `didMutate()` — the observable mutation signal every store adapter owns.
///
/// Five adapters had written this by hand (imbib, imprint, impart, implore, and
/// a test mock), and the two halves are always the same:
///
///   1. bump a monotonic `version` that SwiftUI views observe, and
///   2. fan out a typed `StoreEvent` so snapshot maintainers can do O(k)
///      updates instead of full rebuilds.
///
/// The classification arguments are the interesting part, and the reason not to
/// collapse this into "post a notification": `structural` means the SHAPE of the
/// item graph changed and cached trees must rebuild, whereas
/// `structural: false` + `affectedIDs` + `kind` means specific rows changed
/// specific fields and only those rows need touching.
///
/// `@Observable` and `@MainActor`, because `version` exists to be read from a
/// SwiftUI `body`. An adapter holds one of these and forwards its own
/// `dataVersion` to `signal.version`; Observation tracks the nested read, so
/// views keep updating exactly as they did when the counter was stored directly
/// on the adapter.
@MainActor
@Observable
public final class StoreMutationSignal {

    /// Bumped on every mutation. Views observe this to trigger updates.
    public private(set) var version: Int = 0

    private let emit: (Bool, Set<UUID>?, MutationKind?) -> Void

    /// - Parameter emit: Fans the classified mutation out to the app's store
    ///   gateway (`postMutation`). Defaults to no fan-out, for adapters that
    ///   only have the counter.
    public init(emit: @escaping (Bool, Set<UUID>?, MutationKind?) -> Void = { _, _, _ in }) {
        self.emit = emit
    }

    /// Signal that the store was mutated.
    ///
    /// - Parameters:
    ///   - structural: `true` when items were added, removed or moved (cached
    ///     trees must rebuild). `false` for in-place field changes.
    ///   - affectedIDs: With `structural: false`, the exact rows that changed.
    ///   - kind: With `structural: false`, which fields changed.
    public func didMutate(
        structural: Bool = true,
        affectedIDs: Set<UUID>? = nil,
        kind: MutationKind? = nil
    ) {
        version += 1
        emit(structural, affectedIDs, kind)
    }
}
