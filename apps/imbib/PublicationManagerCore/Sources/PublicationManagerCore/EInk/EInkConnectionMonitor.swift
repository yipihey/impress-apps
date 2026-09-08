//
//  EInkConnectionMonitor.swift
//  PublicationManagerCore
//
//  Is the tablet on the cable? (ADR-025 P7.) The reMarkable's USB web
//  interface answers a probe in well under 2 s when the cable is in and the
//  interface is on; otherwise the connect fails. This model asks every 25 s
//  while at least one enabled device record exists, and again whenever
//  `NWPathMonitor` reports an interface change — plugging the tablet in adds
//  an Ethernet-over-USB interface, which is the fastest signal we have.
//
//  Probes are READS: `RustStoreAdapter.einkReachable` never writes, so the
//  monitor runs from launch (no startup gate), and only the false→true edge
//  is reported onward (`environment.onConnected` → the coordinator's
//  `.connected`, which the gate holds until 90 s).
//
//  Inert without a device: `start()` reconciles against the store; with no
//  enabled device there is no loop, no probe and no path monitor — just a
//  suspended subscription to `.structural` store events so a device added
//  later (the Settings pane, P8) starts the loop without a relaunch.
//  Pattern: `Inbox/FeedScheduler.swift` (sleep-in-`do/catch`, never `try?`).
//

import Foundation
import ImpressLogging
import ImpressStoreKit
import Network
import OSLog

// MARK: - Environment

public struct EInkConnectionEnvironment: Sendable {
    /// Ids of the enabled devices (empty → the monitor stays inert).
    public var enabledDeviceIDs: @MainActor @Sendable () -> [String]
    /// The 2 s reachability probe, off-main.
    public var probe: @Sendable (_ deviceId: String) async -> Bool
    /// Called once per false→true edge.
    public var onConnected: @Sendable (_ deviceId: String) async -> Void
    /// Subscribe to store `.structural` events to re-read the device list.
    public var observesStore: Bool
    /// Run an `NWPathMonitor` for interface changes (off in tests).
    public var usesPathMonitor: Bool

    public init(
        enabledDeviceIDs: @escaping @MainActor @Sendable () -> [String],
        probe: @escaping @Sendable (String) async -> Bool,
        onConnected: @escaping @Sendable (String) async -> Void,
        observesStore: Bool = true,
        usesPathMonitor: Bool = true
    ) {
        self.enabledDeviceIDs = enabledDeviceIDs
        self.probe = probe
        self.onConnected = onConnected
        self.observesStore = observesStore
        self.usesPathMonitor = usesPathMonitor
    }
}

// MARK: - Monitor

@MainActor
@Observable
public final class EInkConnectionMonitor {

    public static let defaultInterval: Duration = .seconds(25)

    /// The last probe's answer.
    public private(set) var isConnected = false
    public private(set) var lastProbeAt: Date?
    public private(set) var probeCount = 0
    /// The device being probed; nil while inert.
    public private(set) var deviceID: String?
    /// Whether the probe loop is running.
    public private(set) var isMonitoring = false
    /// Bumped on every start/stop; a probe result from an older generation
    /// is discarded.
    private var generation = 0

    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let environment: EInkConnectionEnvironment
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var probeInFlight = false
    @ObservationIgnored private var started = false

    public init(interval: Duration = EInkConnectionMonitor.defaultInterval, environment: EInkConnectionEnvironment) {
        self.interval = interval
        self.environment = environment
    }

    // MARK: Lifecycle

    /// Reconcile against the device records and, when configured, begin probing.
    public func start() {
        guard !started else { return }
        started = true
        reconcile()
        guard environment.observesStore else { return }
        eventTask = Task { [weak self] in
            for await event in ImbibImpressStore.shared.events.subscribe() {
                guard let self else { return }
                if case .structural = event { self.scheduleReconcile() }
            }
        }
    }

    public func stop() {
        stopProbing()
        eventTask?.cancel()
        eventTask = nil
        reconcileTask?.cancel()
        reconcileTask = nil
        started = false
    }

    /// Start or stop the loop according to whether an enabled device exists.
    public func reconcile() {
        let ids = environment.enabledDeviceIDs()
        guard let first = ids.first else {
            if isMonitoring {
                Logger.library.infoCapture("eink.monitor: no enabled device left, probing stopped", category: "eink")
            }
            stopProbing()
            return
        }
        if isMonitoring, deviceID == first { return }
        stopProbing()
        deviceID = first
        startProbing()
    }

    /// Probe now (the "Check now" button, an interface change). Returns the
    /// answer, or the last known state when a probe is already in flight.
    @discardableResult
    public func probeNow() async -> Bool {
        guard let deviceID, !probeInFlight else { return isConnected }
        probeInFlight = true
        defer { probeInFlight = false }

        let generationAtStart = generation
        let reachable = await environment.probe(deviceID)
        // A probe that outlived its device (the device was removed or
        // swapped while the probe was in flight) must not resurrect the
        // connection state `stopProbing()` just cleared.
        guard generation == generationAtStart, self.deviceID == deviceID else {
            Logger.library.debugCapture(
                "eink.monitor: probe result for \(deviceID) discarded (monitor restarted)", category: "eink")
            return isConnected
        }
        lastProbeAt = Date()
        probeCount += 1
        let was = isConnected
        isConnected = reachable
        if !was && reachable {
            Logger.library.infoCapture("eink.monitor: tablet connected (device \(deviceID))", category: "eink")
            await environment.onConnected(deviceID)
        } else if was && !reachable {
            Logger.library.infoCapture("eink.monitor: tablet disconnected (device \(deviceID))", category: "eink")
        } else {
            Logger.library.debugCapture(
                "eink.monitor: probe #\(probeCount) \(reachable ? "reachable" : "unreachable")", category: "eink")
        }
        return reachable
    }

    // MARK: Internals

    private func scheduleReconcile() {
        guard reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in
            // One bounded wait per burst of structural events.
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let self else { return }
            self.reconcileTask = nil
            self.reconcile()
        }
    }

    private func startProbing() {
        guard let deviceID else { return }
        generation &+= 1
        isMonitoring = true
        Logger.library.infoCapture(
            "eink.monitor: probing device \(deviceID) every \(interval)", category: "eink")

        loopTask = Task { [weak self, interval] in
            while !Task.isCancelled {
                guard let self, self.isMonitoring else { return }
                await self.probeNow()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }

        guard environment.usesPathMonitor else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.probeNow()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.imbib.eink.path", qos: .utility))
        pathMonitor = monitor
    }

    private func stopProbing() {
        generation &+= 1
        loopTask?.cancel()
        loopTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        isMonitoring = false
        deviceID = nil
        isConnected = false
    }
}
