//
//  EInkServices.swift
//  PublicationManagerCore
//
//  The composition root for the reMarkable mirror's Swift services
//  (ADR-025 P7): registrar → connection monitor → sync coordinator → source
//  fetcher → OCR launch sweep, wired to each other and to the store here and
//  nowhere else, so `imbibApp.swift` starts them with one call after
//  `AutomationService.configure(...)` and holds no business logic.
//
//  In-memory only: nothing here writes UserDefaults (the settings migration
//  does, once, by design). Inert without a device: the registrar reads the
//  device records once; the monitor stays off its probe loop; the fetcher
//  and the OCR pass check `EInkMirrorModel.isConfigured` before touching
//  the store; the coordinator holds one gate-wait task and observers.
//
//  The automation routes (`POST /api/eink/{sync,import}`) go through
//  `coordinator` so agent-driven runs are serialised with everything else;
//  they fall back to the adapter when the services were never started.
//

import Foundation
import ImpressLogging
import OSLog

@MainActor
public final class EInkServices {

    public static let shared = EInkServices()

    public private(set) var gate: EInkStartupGate?
    public private(set) var monitor: EInkConnectionMonitor?
    public private(set) var coordinator: EInkSyncCoordinator?
    public private(set) var fetcher: EInkSourceFetcher?
    public private(set) var ocr: EInkOCRPass?
    public private(set) var migration: EInkSettingsMigration?

    public var isStarted: Bool { coordinator != nil }

    private init() {}

    /// Build and start everything. Idempotent.
    public func start(gateInterval: TimeInterval = EInkStartupGate.defaultInterval) async {
        guard coordinator == nil else { return }
        let gate = EInkStartupGate(interval: gateInterval)
        self.gate = gate

        let registered = await EInkDeviceRegistrar.registerConfiguredDevices()

        let ocr = EInkOCRPass(gate: gate)
        self.ocr = ocr
        let migration = EInkSettingsMigration()
        self.migration = migration

        let monitor = EInkConnectionMonitor(environment: EInkConnectionEnvironment(
            enabledDeviceIDs: { RustStoreAdapter.shared.einkDevices().filter(\.enabled).map(\.id) },
            probe: { deviceId in await RustStoreAdapter.shared.einkReachable(deviceId: deviceId) },
            onConnected: { [weak self] _ in
                await self?.coordinator?.nudge(.connected)
            }
        ))
        self.monitor = monitor

        let coordinator = EInkSyncCoordinator(gate: gate, environment: EInkSyncEnvironment(
            targets: {
                await MainActor.run { RustStoreAdapter.shared.einkDevices().filter(\.enabled).map(EInkSyncTarget.init) }
            },
            isConnected: { [weak self] in
                guard let monitor = await self?.monitor else { return true }
                if await monitor.isConnected { return true }
                return await monitor.probeNow()
            },
            sync: { deviceId, importAnnotations in
                try await RustStoreAdapter.shared.einkSync(deviceId: deviceId, import: importAnnotations)
            },
            importOnly: { deviceId in
                // "Import annotations now": import-only in Rust, nothing uploads.
                try await RustStoreAdapter.shared.einkImport(publicationId: nil, deviceId: deviceId)
            },
            onGateOpened: {
                await MainActor.run { _ = migration.runIfNeeded() }
            },
            afterRun: { [weak self] report, _ in
                let pending = report.imports.filter { $0.inkPendingOCR > 0 }.compactMap(\.publicationId)
                if !pending.isEmpty {
                    await self?.ocr?.run(publicationIds: pending)
                }
                // Display: the status the panes render, after the run.
                await EInkMirrorModel.shared.refresh()
                if let status = await EInkMirrorModel.shared.status {
                    Logger.library.infoCapture(
                        "eink.coordinator display: queued=\(status.counts.queued) awaitingSource=\(status.counts.awaitingSource) "
                            + "awaitingFolder=\(status.counts.awaitingFolder) uploaded=\(status.counts.uploaded) "
                            + "filedInNearest=\(status.counts.filedInNearest) "
                            + "stale=\(status.counts.stale) failed=\(status.counts.failed) "
                            + "lastError=\(status.lastError ?? "none")",
                        category: "eink")
                }
            },
            onRunStateChanged: { running, reason in
                await MainActor.run { EInkMirrorModel.shared.setSyncing(running, reason: reason) }
            }
        ))
        self.coordinator = coordinator

        let fetcher = EInkSourceFetcher(gate: gate, environment: EInkSourceFetchEnvironment(
            isConfigured: { EInkMirrorModel.shared.isConfigured },
            awaiting: { RustStoreAdapter.shared.einkAwaitingSource() },
            acquire: { id in
                try await PDFAcquisitionService.shared.acquire(publicationID: id, policy: .background)
            },
            onSourceArrived: { [weak self] _ in
                await self?.coordinator?.nudge(.sourceArrived)
            },
            noteOutcome: { id, error in
                await MainActor.run {
                    RustStoreAdapter.shared.einkNoteSourceError(publicationId: id, error: error)
                }
            }
        ))
        self.fetcher = fetcher

        monitor.start()
        await coordinator.start()
        await fetcher.start()
        await ocr.startLaunchSweep()

        Logger.library.infoCapture(
            "eink.services started: \(registered) device(s) registered, monitor \(monitor.isMonitoring ? "probing" : "idle"), "
                + "automatic work after \(Int(gateInterval)) s",
            category: "eink")
    }

    /// Stop everything (tests, shutdown).
    public func stop() async {
        monitor?.stop()
        await coordinator?.stop()
        await fetcher?.stop()
        await ocr?.stop()
        monitor = nil
        coordinator = nil
        fetcher = nil
        ocr = nil
        migration = nil
        gate = nil
    }

    /// Tell the services the device record changed (the Settings pane, P8):
    /// the monitor re-reads the device list; the coordinator gets a nudge.
    public func settingsChanged() async {
        // A device added from the pane after launch has a record but no
        // legacy registration (the registrar ran at start); adopt it so the
        // pane's device list, which still reads `EInkDeviceManager`, sees it.
        if EInkDeviceManager.shared.activeDevice == nil {
            _ = await EInkDeviceRegistrar.registerConfiguredDevices()
        }
        monitor?.reconcile()
        await EInkMirrorModel.shared.refresh()
        await coordinator?.nudge(.settingsChanged)
    }
}
