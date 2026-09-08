//
//  EInkSyncCoordinator.swift
//  PublicationManagerCore
//
//  Decides WHEN the reMarkable mirror engine runs (ADR-025 P7). The engine
//  itself is Rust (`imbib-core::eink`, reached through
//  `RustStoreAdapter.einkSync`); this actor only turns events into runs:
//
//  - reasons: `connected` (the monitor saw the tablet appear), `marked`,
//    `sourceArrived` (the fetcher got a PDF), `settingsChanged` — automatic;
//    `manual` ("Sync now") and `importOnly` ("Import annotations now") — a
//    person asked;
//  - automatic reasons are coalesced (2 s) into one run, held back while the
//    tablet is not connected, and IGNORED until the shared startup gate
//    opens (queued: the one gate-wait task replays the last queued reason
//    when the 90 s are up), because a sync mutates the store;
//  - manual reasons bypass the gate and the coalescing;
//  - runs are strictly serial: each request chains behind the previous
//    task, so two "Sync now" clicks are two runs in order, never two at once.
//
//  After a run whose imports carry ink still to be read, the OCR pass is
//  kicked (`EInkSyncEnvironment.afterRun`). The store event for the run's
//  changes is posted by the adapter wrapper (`notifyMutationFromBackground`
//  inside `einkSync`), so this file posts nothing.
//
//  Every step is a closure in `EInkSyncEnvironment` so the gate, coalescing
//  and serialisation are unit-tested with a fake runner; `.live` is the
//  production wiring (`EInkServices` builds it).
//

import Foundation
import ImpressLogging
import OSLog

// MARK: - Reasons

public enum EInkSyncReason: String, Sendable, Hashable, CaseIterable {
    /// The connection monitor saw a false→true edge.
    case connected
    /// Publications were marked / unmarked.
    case marked
    /// The source fetcher put a PDF on disk for an `awaiting_source` row.
    case sourceArrived
    /// The device record changed (mode, folders, import toggles).
    case settingsChanged
    /// Paper ▸ Sync reMarkable Now, `POST /api/eink/sync`.
    case manual
    /// Paper ▸ Import reMarkable Annotations, `POST /api/eink/import`.
    case importOnly

    /// Automatic reasons honour the startup gate and the coalescing window.
    public var isAutomatic: Bool {
        switch self {
        case .connected, .marked, .sourceArrived, .settingsChanged: return true
        case .manual, .importOnly: return false
        }
    }
}

// MARK: - Targets

/// What a run needs to know about one device — a slice of `EInkDeviceRecord`
/// small enough for tests to build by hand.
public struct EInkSyncTarget: Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let autoImportOnConnect: Bool

    public init(id: String, name: String, autoImportOnConnect: Bool) {
        self.id = id
        self.name = name
        self.autoImportOnConnect = autoImportOnConnect
    }

    public init(_ device: EInkDeviceRecord) {
        self.init(id: device.id, name: device.name, autoImportOnConnect: device.autoImportOnConnect)
    }
}

// MARK: - Environment

public struct EInkSyncEnvironment: Sendable {
    /// The enabled devices a run works through (usually one).
    public var targets: @Sendable () async -> [EInkSyncTarget]
    /// Whether the tablet answers — automatic runs are skipped when it does
    /// not (the next `connected` edge brings them back). Manual runs never ask.
    public var isConnected: @Sendable () async -> Bool
    /// One engine pass for one device.
    public var sync: @Sendable (_ deviceId: String, _ importAnnotations: Bool) async throws -> EInkSyncReport
    /// The import-only pass for one device (`.importOnly`): nothing goes up.
    /// nil = `sync(deviceId, true)`, which is what the fake runners in the
    /// tests observe; the live wiring supplies `einkImport` (P8), the pass
    /// that is import-only in Rust rather than a full sync with import on.
    public var importOnly: (@Sendable (_ deviceId: String) async throws -> EInkSyncReport)?
    /// Runs once when the gate opens, before any automatic run (the
    /// settings migration lives here).
    public var onGateOpened: @Sendable () async -> Void
    /// Runs after every completed engine pass (OCR kick, status refresh).
    public var afterRun: @Sendable (_ report: EInkSyncReport, _ reason: EInkSyncReason) async -> Void
    /// Runs when a run starts (`true`) and when it ends (`false`), so a
    /// surface can show "syncing" without polling the actor.
    public var onRunStateChanged: @Sendable (_ running: Bool, _ reason: EInkSyncReason) async -> Void

    public init(
        targets: @escaping @Sendable () async -> [EInkSyncTarget],
        isConnected: @escaping @Sendable () async -> Bool = { true },
        sync: @escaping @Sendable (String, Bool) async throws -> EInkSyncReport,
        importOnly: (@Sendable (String) async throws -> EInkSyncReport)? = nil,
        onGateOpened: @escaping @Sendable () async -> Void = {},
        afterRun: @escaping @Sendable (EInkSyncReport, EInkSyncReason) async -> Void = { _, _ in },
        onRunStateChanged: @escaping @Sendable (Bool, EInkSyncReason) async -> Void = { _, _ in }
    ) {
        self.targets = targets
        self.isConnected = isConnected
        self.sync = sync
        self.importOnly = importOnly
        self.onGateOpened = onGateOpened
        self.afterRun = afterRun
        self.onRunStateChanged = onRunStateChanged
    }
}

// MARK: - Coordinator

public actor EInkSyncCoordinator {

    public struct RunSummary: Sendable, Equatable {
        public let reason: EInkSyncReason
        public let startedAt: Date
        public let finishedAt: Date
        public let reports: [EInkSyncReport]
        public let error: String?
    }

    public let gate: EInkStartupGate
    private let coalesce: Duration
    private let environment: EInkSyncEnvironment

    /// Automatic reasons that arrived before the gate opened; replayed once.
    public private(set) var queuedBeforeGate: Set<EInkSyncReason> = []
    /// Automatic reasons waiting for the coalescing window to close.
    public private(set) var pendingAutomatic: Set<EInkSyncReason> = []
    public private(set) var runCount = 0
    public private(set) var isRunning = false
    public private(set) var lastRun: RunSummary?

    private var coalesceTask: Task<Void, Never>?
    private var gateTask: Task<Void, Never>?
    /// The tail of the serial chain: every new run awaits this first.
    private var tail: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    public init(
        gate: EInkStartupGate,
        coalesce: Duration = .seconds(2),
        environment: EInkSyncEnvironment
    ) {
        self.gate = gate
        self.coalesce = coalesce
        self.environment = environment
    }

    // MARK: Lifecycle

    /// Install the menu / palette observers and the ONE gate-wait task.
    public func start(observeNotifications: Bool = true) {
        guard !started else { return }
        started = true
        Logger.library.infoCapture(
            "eink.coordinator started; automatic runs allowed in \(Int(gate.remaining)) s",
            category: "eink")

        if observeNotifications {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .einkSyncNow, object: nil, queue: nil) { [weak self] _ in
                Task { await self?.nudge(.manual) }
            })
            observers.append(center.addObserver(forName: .einkImportAnnotations, object: nil, queue: nil) { [weak self] _ in
                Task { await self?.nudge(.importOnly) }
            })
        }

        // One sleep for the remaining grace, never a loop (see EInkStartupGate).
        gateTask = Task { [weak self, gate] in
            guard await gate.waitUntilOpen() else { return }
            await self?.gateOpened()
        }
    }

    public func stop() {
        gateTask?.cancel()
        gateTask = nil
        coalesceTask?.cancel()
        coalesceTask = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        started = false
    }

    // MARK: Nudges

    /// Ask for a run. Automatic reasons wait for the gate and the coalescing
    /// window; `manual` / `importOnly` run as soon as the previous run ends.
    public func nudge(_ reason: EInkSyncReason) {
        guard reason.isAutomatic else {
            _ = enqueue(reason: reason, importOverride: nil)
            return
        }
        guard gate.isOpen else {
            queuedBeforeGate.insert(reason)
            Logger.library.infoCapture(
                "eink.coordinator \(reason.rawValue) queued: startup gate opens in \(Int(gate.remaining)) s",
                category: "eink")
            return
        }
        pendingAutomatic.insert(reason)
        guard coalesceTask == nil else { return }
        coalesceTask = Task { [weak self, coalesce] in
            // One bounded wait; a cancelled window runs nothing.
            do {
                try await Task.sleep(for: coalesce)
            } catch {
                return
            }
            await self?.coalescingWindowClosed()
        }
    }

    /// Run now and wait for the reports — the automation routes' entry point.
    /// Bypasses the gate and the coalescing like every non-automatic reason.
    /// `importOverride` replaces the device's own import decision.
    @discardableResult
    public func runNow(reason: EInkSyncReason = .manual, importOverride: Bool? = nil) async throws -> [EInkSyncReport] {
        try await enqueue(reason: reason, importOverride: importOverride).value
    }

    // MARK: Internals

    private func gateOpened() async {
        Logger.library.infoCapture("eink.coordinator startup gate open", category: "eink")
        await environment.onGateOpened()
        guard !queuedBeforeGate.isEmpty else { return }
        let queued = queuedBeforeGate
        queuedBeforeGate = []
        Logger.library.infoCapture(
            "eink.coordinator replaying queued reason(s): \(queued.map(\.rawValue).sorted().joined(separator: ","))",
            category: "eink")
        nudge(Self.primary(of: queued))
    }

    private func coalescingWindowClosed() async {
        coalesceTask = nil
        let reasons = pendingAutomatic
        pendingAutomatic = []
        guard !reasons.isEmpty else { return }
        let reason = Self.primary(of: reasons)
        guard await environment.isConnected() else {
            Logger.library.infoCapture(
                "eink.coordinator \(reason.rawValue) skipped: tablet not connected (will run on the next connect)",
                category: "eink")
            return
        }
        _ = enqueue(reason: reason, importOverride: nil)
    }

    /// The reason a coalesced run is reported under: the most specific one.
    static func primary(of reasons: Set<EInkSyncReason>) -> EInkSyncReason {
        for candidate in [EInkSyncReason.settingsChanged, .sourceArrived, .marked, .connected] where reasons.contains(candidate) {
            return candidate
        }
        return reasons.first ?? .connected
    }

    /// Chain a run behind the current tail. Strictly serial by construction:
    /// the new task first awaits the previous one, whatever its outcome.
    private func enqueue(reason: EInkSyncReason, importOverride: Bool?) -> Task<[EInkSyncReport], Error> {
        let previous = tail
        let run = Task<[EInkSyncReport], Error> { [weak self] in
            await previous?.value
            guard let self else { throw CancellationError() }
            return try await self.perform(reason: reason, importOverride: importOverride)
        }
        tail = Task { _ = try? await run.value }
        return run
    }

    private func perform(reason: EInkSyncReason, importOverride: Bool?) async throws -> [EInkSyncReport] {
        let targets = await environment.targets()
        guard !targets.isEmpty else {
            Logger.library.infoCapture("eink.coordinator \(reason.rawValue): no enabled device, nothing to run", category: "eink")
            return []
        }
        isRunning = true
        defer { isRunning = false }
        await environment.onRunStateChanged(true, reason)
        runCount += 1
        let runNumber = runCount
        let startedAt = Date()
        var reports: [EInkSyncReport] = []
        var firstError: Error?

        for target in targets {
            let importAnnotations = importOverride ?? (target.autoImportOnConnect || reason == .importOnly)
            // Mutation: what was asked.
            Logger.library.infoCapture(
                "eink.coordinator run #\(runNumber) reason=\(reason.rawValue) device=\(target.id) '\(target.name)' import=\(importAnnotations)",
                category: "eink")
            do {
                let report: EInkSyncReport
                if reason == .importOnly, let importOnly = environment.importOnly {
                    // Import-only in Rust: nothing uploads, whatever the device's switches say.
                    report = try await importOnly(target.id)
                } else {
                    report = try await environment.sync(target.id, importAnnotations)
                }
                reports.append(report)
                // Save: what the engine did (the wrapper already posted the store event).
                let pendingOCR = report.imports.reduce(0) { $0 + $1.inkPendingOCR }
                Logger.library.infoCapture(
                    "eink.coordinator run #\(runNumber) device=\(target.id) reachable=\(report.reachable) "
                        + "uploaded=\(report.uploaded.count) failed=\(report.failed.count) "
                        + "imports=\(report.imports.count) pendingImports=\(report.pendingImports) "
                        + "folderNeeds=\(report.folderNeeds.count) inkPendingOCR=\(pendingOCR)",
                    category: "eink")
                await environment.afterRun(report, reason)
            } catch {
                Logger.library.errorCapture(
                    "eink.coordinator run #\(runNumber) device=\(target.id) failed: \(error.localizedDescription)",
                    category: "eink")
                if firstError == nil { firstError = error }
            }
        }

        await environment.onRunStateChanged(false, reason)
        lastRun = RunSummary(
            reason: reason, startedAt: startedAt, finishedAt: Date(),
            reports: reports, error: firstError?.localizedDescription)
        if let firstError, reports.isEmpty {
            throw firstError
        }
        return reports
    }
}
