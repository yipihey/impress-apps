//
//  EInkConnectionMonitorTests.swift
//  PublicationManagerCoreTests
//
//  The cable watcher (ADR-025 P7): nothing is probed without a device, and
//  the false→true edge is reported exactly once however many probes agree.
//  Probes and the device list are injected; no store, no NWPathMonitor.
//

import Foundation
import XCTest
@testable import PublicationManagerCore

@MainActor
final class EInkConnectionMonitorTests: XCTestCase {

    /// Scripted probe answers; the last one repeats.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Bool]
        private(set) var probes = 0
        init(_ answers: [Bool]) { self.answers = answers }
        func next() -> Bool {
            lock.lock(); defer { lock.unlock() }
            probes += 1
            if answers.count > 1 { return answers.removeFirst() }
            return answers.first ?? false
        }
    }

    final class DeviceList: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String]
        init(_ ids: [String]) { self.ids = ids }
        var current: [String] {
            lock.lock(); defer { lock.unlock() }
            return ids
        }
        func set(_ ids: [String]) {
            lock.lock(); defer { lock.unlock() }
            self.ids = ids
        }
    }

    private func makeMonitor(devices: DeviceList, script: Script, connected: CountBox, interval: Duration = .milliseconds(20)) -> EInkConnectionMonitor {
        EInkConnectionMonitor(interval: interval, environment: EInkConnectionEnvironment(
            enabledDeviceIDs: { devices.current },
            probe: { _ in script.next() },
            onConnected: { id in connected.record(id) },
            observesStore: false,
            usesPathMonitor: false
        ))
    }

    func testNoDeviceMeansNoProbeAndNoLoop() async throws {
        let script = Script([true])
        let connected = CountBox()
        let monitor = makeMonitor(devices: DeviceList([]), script: script, connected: connected)

        monitor.start()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertNil(monitor.deviceID)
        XCTAssertEqual(script.probes, 0, "a probe without a device is a bug")
        XCTAssertEqual(monitor.probeCount, 0)
        XCTAssertNil(monitor.lastProbeAt)
        XCTAssertTrue(connected.lines.isEmpty)
        monitor.stop()
    }

    func testProbeNowIsInertWithoutADevice() async {
        let script = Script([true])
        let monitor = makeMonitor(devices: DeviceList([]), script: script, connected: CountBox())
        let answer = await monitor.probeNow()
        XCTAssertFalse(answer)
        XCTAssertEqual(script.probes, 0)
    }

    func testTheFalseToTrueEdgeIsReportedOnce() async throws {
        let script = Script([false, false, true, true, true])
        let connected = CountBox()
        let monitor = makeMonitor(devices: DeviceList(["dev-1"]), script: script, connected: connected)

        monitor.start()
        XCTAssertTrue(monitor.isMonitoring)
        XCTAssertEqual(monitor.deviceID, "dev-1")
        let settled = try await EInkTestSupport.waitUntil { await MainActor.run { monitor.probeCount >= 5 } }

        XCTAssertTrue(settled, "the loop keeps probing at its interval")
        XCTAssertTrue(monitor.isConnected)
        XCTAssertNotNil(monitor.lastProbeAt)
        XCTAssertEqual(connected.lines, ["dev-1"], "one edge, one report — however many probes say true")
        monitor.stop()
        XCTAssertFalse(monitor.isMonitoring)
    }

    func testADisconnectAndReconnectReportsASecondEdge() async throws {
        let script = Script([true, false, true, true])
        let connected = CountBox()
        let monitor = makeMonitor(devices: DeviceList(["dev-1"]), script: script, connected: connected)

        monitor.start()
        _ = try await EInkTestSupport.waitUntil { await MainActor.run { monitor.probeCount >= 4 } }

        XCTAssertEqual(connected.lines, ["dev-1", "dev-1"])
        monitor.stop()
    }

    func testTheGapWidensWhileTheTabletIsAwayAndSnapsBackWhenItAnswers() {
        let base: Duration = .seconds(25)
        // Nothing about asking a sleeping tablet sooner makes it answer.
        XCTAssertEqual(EInkConnectionMonitor.interval(base: base, failures: 0), .seconds(25))
        XCTAssertEqual(EInkConnectionMonitor.interval(base: base, failures: 1), .seconds(25))
        XCTAssertEqual(EInkConnectionMonitor.interval(base: base, failures: 2), .seconds(50))
        XCTAssertEqual(EInkConnectionMonitor.interval(base: base, failures: 3), .seconds(100))
        XCTAssertEqual(EInkConnectionMonitor.interval(base: base, failures: 4), .seconds(200))
        // Capped, and stays capped however long it has been away.
        XCTAssertEqual(EInkConnectionMonitor.interval(base: base, failures: 5), EInkConnectionMonitor.maxInterval)
        XCTAssertEqual(EInkConnectionMonitor.interval(base: base, failures: 500), EInkConnectionMonitor.maxInterval)
    }

    func testAnAnsweringTabletResetsTheGapAndAStopResetsTheCount() async throws {
        let script = Script([false, false, false, true])
        let monitor = makeMonitor(devices: DeviceList(["dev-1"]), script: script, connected: CountBox())

        monitor.start()
        _ = try await EInkTestSupport.waitUntil { await MainActor.run { monitor.probeCount >= 3 } }
        let widened = await MainActor.run { monitor.currentInterval }
        XCTAssertGreaterThan(widened, monitor.probeInterval, "three failures widen the gap")

        _ = try await EInkTestSupport.waitUntil { await MainActor.run { monitor.isConnected } }
        let afterAnswer = await MainActor.run { (monitor.consecutiveFailures, monitor.currentInterval) }
        XCTAssertEqual(afterAnswer.0, 0)
        XCTAssertEqual(afterAnswer.1, monitor.probeInterval, "an answer snaps the gap back")

        monitor.stop()
        XCTAssertEqual(monitor.consecutiveFailures, 0, "a fresh start begins at the base interval")
    }

    func testReconcileStopsProbingWhenTheDeviceGoesAway() async throws {
        let script = Script([true])
        let devices = DeviceList(["dev-1"])
        let monitor = makeMonitor(devices: devices, script: script, connected: CountBox())

        monitor.start()
        _ = try await EInkTestSupport.waitUntil { await MainActor.run { monitor.probeCount >= 1 } }
        XCTAssertTrue(monitor.isConnected)

        devices.set([])
        monitor.reconcile()
        let probesAtStop = script.probes
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertFalse(monitor.isConnected, "no device, no connection")
        XCTAssertEqual(script.probes, probesAtStop, "no probe after the device is removed")
        monitor.stop()
    }

    func testReconcileStartsProbingWhenADeviceAppears() async throws {
        let script = Script([true])
        let devices = DeviceList([])
        let connected = CountBox()
        let monitor = makeMonitor(devices: devices, script: script, connected: connected)

        monitor.start()
        XCTAssertFalse(monitor.isMonitoring)
        devices.set(["dev-9"])
        monitor.reconcile()
        let probed = try await EInkTestSupport.waitUntil { await MainActor.run { monitor.probeCount >= 1 } }

        XCTAssertTrue(probed)
        XCTAssertEqual(monitor.deviceID, "dev-9")
        XCTAssertEqual(connected.lines, ["dev-9"])
        monitor.stop()
    }
}
