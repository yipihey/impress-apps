//
//  EInkSourceFetcher.swift
//  PublicationManagerCore
//
//  Gets a PDF for every marked paper that has none (ADR-025 P7). Marking a
//  paper without a local PDF/ePUB parks its mirror row in `awaiting_source`;
//  the Rust engine cannot download — only the running app can — so this
//  actor watches for those rows and feeds them to `PDFAcquisitionService`
//  (policy `.background`: never a browser, utility priority, deduped against
//  whatever the PDF tab is already fetching), at most two at a time.
//
//  Triggers: `.itemsMutated(kind: .einkMirror)` (a mark) and `.structural`
//  (a sync, a device change) store events, coalesced to one sweep; a direct
//  `nudge()`. Every sweep is automatic work that ends in an import (a store
//  mutation), so sweeps wait for the shared startup gate — one gate-wait
//  task, one sleep.
//
//  A row is attempted once per session unless it changes (its mirror id,
//  DOI, arXiv id or URL), so an unreachable paper is not hammered on every
//  event. On the first success the coordinator is nudged with
//  `.sourceArrived`, which sends the new file on the next run.
//

import Foundation
import ImpressLogging
import ImpressStoreKit
import OSLog

// MARK: - Environment

public struct EInkSourceFetchEnvironment: Sendable {
    /// At least one enabled device exists (a sweep is pointless otherwise).
    public var isConfigured: @MainActor @Sendable () -> Bool
    /// The `awaiting_source` rows.
    public var awaiting: @MainActor @Sendable () -> [EInkAwaitingSourceRecord]
    /// Fetch one publication's PDF; nil = no source, throws = failed.
    public var acquire: @Sendable (_ publicationId: UUID) async throws -> URL?
    /// At least one PDF arrived this sweep.
    public var onSourceArrived: @Sendable (_ count: Int) async -> Void
    public var observesStore: Bool

    public init(
        isConfigured: @escaping @MainActor @Sendable () -> Bool,
        awaiting: @escaping @MainActor @Sendable () -> [EInkAwaitingSourceRecord],
        acquire: @escaping @Sendable (UUID) async throws -> URL?,
        onSourceArrived: @escaping @Sendable (Int) async -> Void,
        observesStore: Bool = true
    ) {
        self.isConfigured = isConfigured
        self.awaiting = awaiting
        self.acquire = acquire
        self.onSourceArrived = onSourceArrived
        self.observesStore = observesStore
    }
}

// MARK: - Fetcher

public actor EInkSourceFetcher {

    public let gate: EInkStartupGate
    private let maxConcurrent: Int
    private let coalesce: Duration
    private let environment: EInkSourceFetchEnvironment

    /// Publication → fingerprint of the row as last attempted.
    public private(set) var attempted: [UUID: String] = [:]
    public private(set) var sweepCount = 0
    public private(set) var isSweeping = false

    private var rerunRequested = false
    private var coalesceTask: Task<Void, Never>?
    private var gateTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var started = false

    public init(
        gate: EInkStartupGate,
        maxConcurrent: Int = 2,
        coalesce: Duration = .seconds(1),
        environment: EInkSourceFetchEnvironment
    ) {
        self.gate = gate
        self.maxConcurrent = max(1, maxConcurrent)
        self.coalesce = coalesce
        self.environment = environment
    }

    // MARK: Lifecycle

    public func start() {
        guard !started else { return }
        started = true

        if environment.observesStore {
            eventTask = Task { [weak self] in
                for await event in ImbibImpressStore.shared.events.subscribe() {
                    guard let self else { return }
                    switch event {
                    case .structural:
                        await self.nudge()
                    case .itemsMutated(let kind, _) where kind == .einkMirror:
                        await self.nudge()
                    default:
                        break
                    }
                }
            }
        }

        // The launch sweep: one sleep for the remaining grace, then one pass.
        gateTask = Task { [weak self, gate] in
            guard await gate.waitUntilOpen() else { return }
            await self?.sweepIfConfigured()
        }
    }

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        gateTask?.cancel()
        gateTask = nil
        coalesceTask?.cancel()
        coalesceTask = nil
        started = false
    }

    /// Ask for a sweep (coalesced; ignored before the gate opens, because the
    /// launch sweep covers everything queued until then).
    public func nudge() {
        guard gate.isOpen else { return }
        guard coalesceTask == nil else { return }
        coalesceTask = Task { [weak self, coalesce] in
            do {
                try await Task.sleep(for: coalesce)
            } catch {
                return
            }
            guard let self else { return }
            await self.clearCoalesce()
            await self.sweepIfConfigured()
        }
    }

    /// Forget which rows were attempted (the Settings pane's "Try again").
    public func resetAttempts() {
        attempted.removeAll()
    }

    // MARK: Sweep

    private func clearCoalesce() {
        coalesceTask = nil
    }

    private func sweepIfConfigured() async {
        guard await environment.isConfigured() else { return }
        await sweep()
    }

    /// Fetch every `awaiting_source` row not yet attempted in this session.
    /// Returns the number of PDFs that arrived.
    @discardableResult
    public func sweep() async -> Int {
        if isSweeping {
            rerunRequested = true
            return 0
        }
        isSweeping = true
        defer { isSweeping = false }
        sweepCount += 1

        let rows = await environment.awaiting()
        let due = rows.filter { attempted[$0.publicationId] != Self.fingerprint($0) }
        guard !due.isEmpty else {
            if !rows.isEmpty {
                Logger.library.debugCapture(
                    "eink.fetch sweep #\(sweepCount): \(rows.count) awaiting, all attempted this session",
                    category: "eink")
            }
            return await finishSweep(arrived: 0)
        }
        // Mutation: what will be fetched.
        Logger.library.infoCapture(
            "eink.fetch sweep #\(sweepCount): \(due.count) of \(rows.count) awaiting-source row(s) to fetch "
                + "(max \(maxConcurrent) at a time)",
            category: "eink")
        for row in due {
            attempted[row.publicationId] = Self.fingerprint(row)
        }

        let acquire = environment.acquire
        let width = maxConcurrent
        let arrived = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            var iterator = due.makeIterator()
            var running = 0
            var total = 0
            func launch(_ row: EInkAwaitingSourceRecord) {
                group.addTask {
                    do {
                        if let url = try await acquire(row.publicationId) {
                            // Save: the file is on disk and linked.
                            Logger.library.infoCapture(
                                "eink.fetch \(row.citeKey): PDF arrived (\(url.lastPathComponent))", category: "eink")
                            return 1
                        }
                        Logger.library.infoCapture(
                            "eink.fetch \(row.citeKey): no direct source; stays awaiting_source", category: "eink")
                    } catch {
                        Logger.library.warningCapture(
                            "eink.fetch \(row.citeKey): \(error.localizedDescription)", category: "eink")
                    }
                    return 0
                }
            }
            while running < width, let row = iterator.next() {
                launch(row)
                running += 1
            }
            for await result in group {
                total += result
                if let row = iterator.next() { launch(row) }
            }
            return total
        }
        return await finishSweep(arrived: arrived)
    }

    private func finishSweep(arrived: Int) async -> Int {
        if arrived > 0 {
            // Display: the coordinator's next run sends the new file(s).
            Logger.library.infoCapture(
                "eink.fetch sweep #\(sweepCount): \(arrived) PDF(s) arrived, nudging sync", category: "eink")
            await environment.onSourceArrived(arrived)
        }
        if rerunRequested {
            rerunRequested = false
            isSweeping = false
            return arrived + (await sweep())
        }
        return arrived
    }

    /// What "the row changed" means: a new mirror row or a new identifier.
    static func fingerprint(_ row: EInkAwaitingSourceRecord) -> String {
        [row.mirrorId, row.doi ?? "", row.arxivId ?? "", row.url ?? ""].joined(separator: "|")
    }
}
