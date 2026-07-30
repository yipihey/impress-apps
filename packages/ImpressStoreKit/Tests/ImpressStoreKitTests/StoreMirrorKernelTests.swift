//
//  StoreMirrorKernelTests.swift
//  ImpressStoreKitTests
//
//  The mirror kernel's contract, tested against an in-memory fake backend.
//
//  These are NEW tests, not moved ones: in its original home
//  (`MessageManagerCore.MailStoreMirror`) this logic had none, because it could
//  only be exercised through a real UniFFI store handle and a real 90-second
//  wall clock. Making the backend a protocol and the launch date injectable is
//  what buys the coverage — the startup embargo, the ordering guarantee and the
//  batch split are now assertions instead of comments.
//

import Foundation
import Testing
@testable import ImpressStoreKit

// MARK: - Fake backend

/// Records every call in order, and can be told to fail for specific ids.
private final class FakeMirrorBackend: StoreMirrorBackend, @unchecked Sendable {

    enum Call: Equatable {
        case batch([String])            // ids, in batch order
        case one(String)                // id
        case read(String, Bool)
        case parent(String, String?)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private let failingIDs: Set<String>

    init(failingIDs: Set<String> = []) {
        self.failingIDs = failingIDs
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    /// Every row id that actually reached the store, in order.
    var upsertedIDs: [String] {
        calls.flatMap { call -> [String] in
            switch call {
            case .batch(let ids): return ids
            case .one(let id): return [id]
            default: return []
            }
        }
    }

    private func record(_ call: Call) {
        lock.lock()
        _calls.append(call)
        lock.unlock()
    }

    struct Boom: Error {}

    func upsertBatch(_ rows: [StoreMirrorUpsert]) throws -> StoreMirrorBatchOutcome {
        if rows.contains(where: { failingIDs.contains($0.id) }) { throw Boom() }
        record(.batch(rows.map(\.id)))
        return StoreMirrorBatchOutcome(inserted: rows.count, updated: 0)
    }

    func upsertOne(_ row: StoreMirrorUpsert) throws {
        if failingIDs.contains(row.id) { throw Boom() }
        record(.one(row.id))
    }

    func setRead(id: String, isRead: Bool) throws {
        if failingIDs.contains(id) { throw Boom() }
        record(.read(id, isRead))
    }

    func setParent(id: String, parentId: String?) throws {
        if failingIDs.contains(id) { throw Boom() }
        record(.parent(id, parentId))
    }
}

private func row(_ id: String, schemaRef: String = "thing") -> StoreMirrorUpsert {
    StoreMirrorUpsert(id: id, schemaRef: schemaRef, payloadJson: "{}")
}

/// A gate whose grace window is already over.
private func openGate(
    backend: StoreMirrorBackend,
    maxBatchRows: Int = 500,
    onApplied: @escaping @Sendable (Int) -> Void = { _ in }
) -> StoreMirrorWriteGate {
    StoreMirrorWriteGate(
        startupGraceSeconds: 90,
        maxBatchRows: maxBatchRows,
        launchDate: Date(timeIntervalSinceNow: -1_000),
        backend: { backend },
        onApplied: onApplied
    )
}

/// A gate still inside its grace window, and far enough from the edge that the
/// scheduled drain cannot fire during the test.
private func embargoedGate(
    backend: StoreMirrorBackend,
    maxBatchRows: Int = 500,
    onApplied: @escaping @Sendable (Int) -> Void = { _ in }
) -> StoreMirrorWriteGate {
    StoreMirrorWriteGate(
        startupGraceSeconds: 3_600,
        maxBatchRows: maxBatchRows,
        launchDate: Date(),
        backend: { backend },
        onApplied: onApplied
    )
}

// MARK: - Startup embargo

@Suite("Store mirror — startup embargo")
struct StoreMirrorEmbargoTests {

    @Test("Ops dispatched inside the grace window do not reach the store")
    func embargoBuffers() {
        let backend = FakeMirrorBackend()
        let gate = embargoedGate(backend: backend)

        gate.dispatch(ops: [.upsert(row("a")), .upsert(row("b"))])

        #expect(backend.calls.isEmpty)
        #expect(gate.pendingCount == 2)
        #expect(gate.isPastStartupGrace == false)
    }

    @Test("Ops dispatched after the window apply immediately, one row at a time")
    func liveDispatchAppliesPerRow() {
        let backend = FakeMirrorBackend()
        let gate = openGate(backend: backend)

        gate.dispatch(ops: [.upsert(row("a")), .upsert(row("b"))])

        // Live path is upsertOne, not a batch: latency over throughput.
        #expect(backend.calls == [.one("a"), .one("b")])
        #expect(gate.pendingCount == 0)
    }

    @Test("An explicit flush drains the buffer in one batch")
    func flushDrainsAsBatch() {
        let backend = FakeMirrorBackend()
        let gate = embargoedGate(backend: backend)

        gate.dispatch(ops: [.upsert(row("a")), .upsert(row("b"))])
        gate.flushPendingOps()

        #expect(backend.calls == [.batch(["a", "b"])])
        #expect(gate.pendingCount == 0)
    }

    @Test("Flushing an empty buffer does nothing at all")
    func flushEmptyIsNoop() {
        let backend = FakeMirrorBackend()
        let gate = openGate(backend: backend)
        gate.flushPendingOps()
        #expect(backend.calls.isEmpty)
    }

    @Test("Dispatching an empty op list does nothing at all")
    func dispatchEmptyIsNoop() {
        let backend = FakeMirrorBackend()
        let gate = embargoedGate(backend: backend)
        gate.dispatch(ops: [])
        #expect(gate.pendingCount == 0)
        #expect(backend.calls.isEmpty)
    }
}

// MARK: - Ordering

@Suite("Store mirror — ordering")
struct StoreMirrorOrderingTests {

    /// The invariant that matters for mirrors: a row dispatched EARLIER must
    /// never land after a row dispatched LATER, even when the earlier one was
    /// caught by the embargo and the later one was not. Parents are dispatched
    /// before children; violating this orphans them.
    @Test("A live dispatch drains the buffer before applying its own ops")
    func liveDispatchDrainsBufferFirst() {
        let backend = FakeMirrorBackend()
        // Grace window is over, but the buffer already holds an earlier op —
        // exactly the situation at the moment the window closes.
        let gate = openGate(backend: backend)
        gate.dispatch(ops: [.upsert(row("early"))])
        #expect(backend.upsertedIDs == ["early"])

        // Now prove the drain-first path with a gate we can seed.
        let backend2 = FakeMirrorBackend()
        let seeded = StoreMirrorWriteGate(
            startupGraceSeconds: 0.35,
            maxBatchRows: 500,
            launchDate: Date(),
            backend: { backend2 }
        )
        seeded.dispatch(ops: [.upsert(row("parent"))])   // buffered (embargoed)
        #expect(backend2.calls.isEmpty)

        // Wait out the (short) window, then dispatch a child live.
        let deadline = Date().addingTimeInterval(1.5)
        while !seeded.isPastStartupGrace && Date() < deadline {
            usleep(10_000)
        }
        #expect(seeded.isPastStartupGrace)
        seeded.dispatch(ops: [.upsert(row("child"))])

        // The parent must appear before the child, whichever call shapes were
        // used to get there.
        let ids = backend2.upsertedIDs
        let parentIndex = ids.firstIndex(of: "parent")
        let childIndex = ids.firstIndex(of: "child")
        #expect(parentIndex != nil)
        #expect(childIndex != nil)
        if let parentIndex, let childIndex { #expect(parentIndex < childIndex) }
    }

    @Test("A non-upsert op flushes the pending batch, so op order survives batching")
    func nonUpsertOpsActAsBatchBoundaries() {
        let backend = FakeMirrorBackend()
        let gate = embargoedGate(backend: backend)

        gate.dispatch(ops: [
            .upsert(row("a")),
            .upsert(row("b")),
            .setRead(id: "a", read: true),
            .upsert(row("c")),
            .setParent(id: "c", parentId: "b"),
        ])
        gate.flushPendingOps()

        #expect(backend.calls == [
            .batch(["a", "b"]),
            .read("a", true),
            .batch(["c"]),
            .parent("c", "b"),
        ])
    }
}

// MARK: - Batching

@Suite("Store mirror — batching")
struct StoreMirrorBatchingTests {

    @Test("Consecutive upserts split at maxBatchRows")
    func batchSplitsAtLimit() {
        let backend = FakeMirrorBackend()
        let gate = embargoedGate(backend: backend, maxBatchRows: 2)

        gate.dispatch(ops: (1...5).map { .upsert(row("r\($0)")) })
        gate.flushPendingOps()

        #expect(backend.calls == [
            .batch(["r1", "r2"]),
            .batch(["r3", "r4"]),
            .batch(["r5"]),
        ])
    }

    @Test("Every row still reaches the store exactly once when batches split")
    func batchSplitLosesNothing() {
        let backend = FakeMirrorBackend()
        let gate = embargoedGate(backend: backend, maxBatchRows: 3)
        let ids = (1...10).map { "r\($0)" }

        gate.dispatch(ops: ids.map { .upsert(row($0)) })
        gate.flushPendingOps()

        #expect(backend.upsertedIDs == ids)
    }
}

// MARK: - Resilience

@Suite("Store mirror — resilience")
struct StoreMirrorResilienceTests {

    /// A mirror that abandons the run on the first bad row leaves the store
    /// half-mirrored, which is indistinguishable from missing data.
    @Test("A throwing op is skipped and the run continues")
    func throwingOpDoesNotAbortTheRun() {
        let backend = FakeMirrorBackend(failingIDs: ["bad"])
        let gate = openGate(backend: backend)

        gate.dispatch(ops: [.upsert(row("a")), .upsert(row("bad")), .upsert(row("c"))])

        #expect(backend.upsertedIDs == ["a", "c"])
    }

    @Test("A missing row for setRead is tolerated, not fatal")
    func setReadOnUnknownRowIsTolerated() {
        let backend = FakeMirrorBackend(failingIDs: ["ghost"])
        let gate = openGate(backend: backend)

        gate.dispatch(ops: [.setRead(id: "ghost", read: true), .upsert(row("a"))])

        #expect(backend.upsertedIDs == ["a"])
    }

    @Test("No backend means the ops are dropped, not queued forever")
    func noBackendDropsOps() {
        let gate = StoreMirrorWriteGate(
            startupGraceSeconds: 90,
            maxBatchRows: 500,
            launchDate: Date(timeIntervalSinceNow: -1_000),
            backend: { nil }
        )
        gate.dispatch(ops: [.upsert(row("a"))])
        #expect(gate.pendingCount == 0)
    }
}

// MARK: - Applied signal

@Suite("Store mirror — applied signal")
struct StoreMirrorAppliedSignalTests {

    @Test("onApplied reports only the ops that succeeded")
    func appliedReportsSuccesses() {
        let recorder = Locked<[Int]>([])
        let backend = FakeMirrorBackend(failingIDs: ["bad"])
        let gate = openGate(backend: backend, onApplied: { n in recorder.mutate { $0.append(n) } })

        gate.dispatch(ops: [.upsert(row("a")), .upsert(row("bad")), .upsert(row("c"))])

        #expect(recorder.value == [2])
    }

    @Test("onApplied does not fire when nothing succeeded")
    func appliedSilentOnTotalFailure() {
        let recorder = Locked<[Int]>([])
        let backend = FakeMirrorBackend(failingIDs: ["bad"])
        let gate = openGate(backend: backend, onApplied: { n in recorder.mutate { $0.append(n) } })

        gate.dispatch(ops: [.upsert(row("bad"))])

        #expect(recorder.value.isEmpty)
    }
}

/// Minimal lock box, so the test closures can accumulate across isolation.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

// MARK: - LazyStoreHandle

@Suite("Lazy store handle")
struct LazyStoreHandleTests {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    struct OpenFailed: Error, LocalizedError {
        var errorDescription: String? { "no database" }
    }

    @Test("The handle opens once and is cached")
    func opensOnce() {
        let opens = Counter()
        let handle = LazyStoreHandle<String> {
            opens.bump()
            return "store"
        }
        #expect(handle.get() == "store")
        #expect(handle.get() == "store")
        #expect(handle.get() == "store")
        #expect(opens.count == 1)
    }

    /// The bug this class exists to kill: impel's hand-rolled version retried
    /// the open on EVERY call, so a missing database cost an exception per
    /// query for the life of the process.
    @Test("A failed open is attempted once, then remembered")
    func failedOpenIsNotRetried() {
        let opens = Counter()
        let handle = LazyStoreHandle<String> {
            opens.bump()
            throw OpenFailed()
        }
        #expect(handle.get() == nil)
        #expect(handle.get() == nil)
        #expect(opens.count == 1)
        #expect(handle.lastError == "no database")
        #expect(handle.isReady == false)
    }

    @Test("onOpen runs exactly once, on the first successful open")
    func onOpenRunsOnce() {
        let hooks = Counter()
        let handle = LazyStoreHandle<String>(onOpen: { _ in hooks.bump() }, open: { "store" })
        _ = handle.get()
        _ = handle.get()
        #expect(hooks.count == 1)
    }

    @Test("An adopted handle bypasses the opener entirely")
    func adoptBypassesOpen() {
        let opens = Counter()
        let handle = LazyStoreHandle<String> {
            opens.bump()
            return "opened"
        }
        handle.adopt("injected")
        #expect(handle.get() == "injected")
        #expect(opens.count == 0)
        #expect(handle.lastError == nil)
    }
}

// MARK: - Payload encoding

@Suite("Store mirror payload")
struct StoreMirrorPayloadTests {

    /// Sorted keys are load-bearing: mirrors re-upsert the same logical row on
    /// every source change, and unsorted output would make byte-identical
    /// payloads look different and churn `modified` on every sync.
    @Test("Keys are sorted, so the same payload encodes identically every time")
    func keysAreSorted() {
        let json = StoreMirrorPayload.encodeJSON(["z": 1, "a": 2, "m": 3])
        #expect(json == #"{"a":2,"m":3,"z":1}"#)
    }

    @Test("Nil values are omitted, not written as null")
    func nilValuesAreOmitted() {
        let json = StoreMirrorPayload.encodeJSON(["a": "x", "b": nil, "c": 3] as [String: Any?])
        #expect(json == #"{"a":"x","c":3}"#)
    }

    @Test("An unencodable payload yields an empty object rather than throwing")
    func unencodablePayloadDegrades() {
        let json = StoreMirrorPayload.encodeJSON(["bad": Date()])
        #expect(json == "{}")
    }

    @Test("An empty payload is a valid empty object")
    func emptyPayload() {
        #expect(StoreMirrorPayload.encodeJSON([:]) == "{}")
    }

    /// `encodeJSON` returning `"{}"` and `encodeJSONIfValid` returning `nil` are
    /// two different policies for the same failure, and the difference matters:
    /// writing `{}` over a figure's metadata replaces it with silence, whereas
    /// skipping the write leaves the previous version and lets the next sync
    /// retry. Callers choose.
    @Test("encodeJSONIfValid returns nil instead of an empty object")
    func ifValidReturnsNilOnFailure() {
        #expect(StoreMirrorPayload.encodeJSONIfValid(["bad": Date()]) == nil)
        #expect(StoreMirrorPayload.encodeJSONIfValid(["a": 1]) == #"{"a":1}"#)
    }

    @Test("encodeJSONIfValid also compacts nil values")
    func ifValidCompactsNils() {
        let json = StoreMirrorPayload.encodeJSONIfValid(["a": "x", "b": nil] as [String: Any?])
        #expect(json == #"{"a":"x"}"#)
    }
}

// MARK: - Mutation signal

@Suite("Store mutation signal")
struct StoreMutationSignalTests {

    @MainActor
    @Test("didMutate bumps the version monotonically")
    func versionIsMonotonic() {
        let signal = StoreMutationSignal()
        #expect(signal.version == 0)
        signal.didMutate()
        signal.didMutate()
        #expect(signal.version == 2)
    }

    @MainActor
    @Test("The classification reaches the fan-out verbatim")
    func classificationIsForwarded() {
        final class Box { var calls: [(Bool, Set<UUID>?, MutationKind?)] = [] }
        let box = Box()
        let signal = StoreMutationSignal { structural, ids, kind in
            box.calls.append((structural, ids, kind))
        }

        let id = UUID()
        signal.didMutate()
        signal.didMutate(structural: false, affectedIDs: [id], kind: .readState)

        #expect(box.calls.count == 2)
        #expect(box.calls[0].0 == true)
        #expect(box.calls[0].1 == nil)
        #expect(box.calls[1].0 == false)
        #expect(box.calls[1].1 == [id])
        #expect(box.calls[1].2 == .readState)
    }
}
