//
//  EInkSyncCoordinatorTests.swift
//  PublicationManagerCoreTests
//
//  When the mirror engine runs (ADR-025 P7): automatic reasons wait for the
//  startup gate (queued, replayed once it opens), manual reasons bypass it,
//  a burst of nudges is one run, and runs never overlap. A fake runner
//  records every engine call; the coordinator never touches the store here.
//

import Foundation
import XCTest
@testable import PublicationManagerCore

final class EInkSyncCoordinatorTests: XCTestCase {

    /// Records engine calls and how many overlapped.
    actor RunLog {
        struct Call: Equatable { let device: String; let importAnnotations: Bool }
        private(set) var calls: [Call] = []
        private(set) var active = 0
        private(set) var maxActive = 0
        var delay: Duration = .zero

        func begin(_ device: String, _ importAnnotations: Bool) {
            calls.append(Call(device: device, importAnnotations: importAnnotations))
            active += 1
            maxActive = max(maxActive, active)
        }

        func end() { active -= 1 }

        func setDelay(_ delay: Duration) { self.delay = delay }
    }

    private func makeCoordinator(
        gate: EInkStartupGate,
        coalesce: Duration = .milliseconds(80),
        targets: [EInkSyncTarget] = [EInkSyncTarget(id: "dev-1", name: "reMarkable", autoImportOnConnect: false)],
        isConnected: Bool = true,
        log: RunLog,
        gateOpened: CountBox = CountBox(),
        afterRun: CountBox = CountBox()
    ) -> EInkSyncCoordinator {
        EInkSyncCoordinator(gate: gate, coalesce: coalesce, environment: EInkSyncEnvironment(
            targets: { targets },
            isConnected: { isConnected },
            sync: { device, importAnnotations in
                await log.begin(device, importAnnotations)
                let delay = await log.delay
                if delay > .zero { try? await Task.sleep(for: delay) }
                await log.end()
                return EInkTestSupport.syncReport(device: device)
            },
            onGateOpened: { gateOpened.bump() },
            afterRun: { _, reason in afterRun.bump(reason.rawValue) }
        ))
    }

    // MARK: - Startup gate

    func testAutomaticReasonsAreQueuedWhileTheGateIsClosed() async throws {
        let log = RunLog()
        let closed = EInkStartupGate(interval: 1000)
        let coordinator = makeCoordinator(gate: closed, log: log)
        await coordinator.start(observeNotifications: false)

        await coordinator.nudge(.marked)
        await coordinator.nudge(.connected)
        try await Task.sleep(for: .milliseconds(250))

        let awaited1 = await log.calls.count
        XCTAssertEqual(awaited1, 0, "no automatic run inside the gate")
        let awaited2 = await coordinator.queuedBeforeGate
        XCTAssertEqual(awaited2, [.marked, .connected])
        let awaited3 = await coordinator.pendingAutomatic.isEmpty
        XCTAssertTrue(awaited3)
        await coordinator.stop()
    }

    func testManualBypassesTheGateAndTheCoalescing() async throws {
        let log = RunLog()
        let coordinator = makeCoordinator(gate: EInkStartupGate(interval: 1000), log: log)
        await coordinator.start(observeNotifications: false)

        let reports = try await coordinator.runNow(reason: .manual)

        XCTAssertEqual(reports.count, 1)
        let awaited4 = await log.calls
        XCTAssertEqual(awaited4, [.init(device: "dev-1", importAnnotations: false)])
        let awaited5 = await coordinator.runCount
        XCTAssertEqual(awaited5, 1)
        let awaited6 = await coordinator.lastRun?.reason
        XCTAssertEqual(awaited6, .manual)
        await coordinator.stop()
    }

    func testTheGateOpeningRunsTheHookThenReplaysTheQueuedReason() async throws {
        let log = RunLog()
        let gateOpened = CountBox()
        let afterRun = CountBox()
        let gate = EInkStartupGate(interval: 0.3)
        let coordinator = makeCoordinator(gate: gate, coalesce: .milliseconds(30), log: log, gateOpened: gateOpened, afterRun: afterRun)
        await coordinator.start(observeNotifications: false)
        await coordinator.nudge(.connected)
        let awaited7 = await log.calls.count
        XCTAssertEqual(awaited7, 0)

        let ran = try await EInkTestSupport.waitUntil { await log.calls.count == 1 }

        XCTAssertTrue(ran, "the queued reason runs once the gate opens")
        XCTAssertEqual(gateOpened.count, 1, "the migration hook runs exactly once, when the gate opens")
        let awaited8 = await coordinator.lastRun?.reason
        XCTAssertEqual(awaited8, .connected)
        XCTAssertEqual(afterRun["connected"], 1)
        let awaited9 = await coordinator.queuedBeforeGate.isEmpty
        XCTAssertTrue(awaited9)
        await coordinator.stop()
    }

    // MARK: - Coalescing

    func testABurstOfNudgesIsOneRunUnderTheMostSpecificReason() async throws {
        let log = RunLog()
        let coordinator = makeCoordinator(gate: .open, coalesce: .milliseconds(100), log: log)
        await coordinator.start(observeNotifications: false)

        for reason in [EInkSyncReason.connected, .marked, .connected, .marked, .marked] {
            await coordinator.nudge(reason)
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try await EInkTestSupport.waitUntil { await log.calls.count >= 1 }
        try await Task.sleep(for: .milliseconds(250))

        let awaited10 = await log.calls.count
        XCTAssertEqual(awaited10, 1, "five nudges inside one window are one run")
        let awaited11 = await coordinator.lastRun?.reason
        XCTAssertEqual(awaited11, .marked)
        await coordinator.stop()
    }

    func testAutomaticRunsWaitForTheTabletWhenItIsNotConnected() async throws {
        let log = RunLog()
        let coordinator = makeCoordinator(gate: .open, coalesce: .milliseconds(30), isConnected: false, log: log)
        await coordinator.start(observeNotifications: false)

        await coordinator.nudge(.marked)
        try await Task.sleep(for: .milliseconds(200))

        let awaited12 = await log.calls.count
        XCTAssertEqual(awaited12, 0, "no point syncing into a missing cable")
        // A person's request still goes through.
        _ = try await coordinator.runNow(reason: .manual)
        let awaited13 = await log.calls.count
        XCTAssertEqual(awaited13, 1)
        await coordinator.stop()
    }

    // MARK: - Serial runs

    func testRunsAreStrictlySerial() async throws {
        let log = RunLog()
        await log.setDelay(.milliseconds(120))
        let coordinator = makeCoordinator(gate: .open, log: log)
        await coordinator.start(observeNotifications: false)

        // Sequential nudges pin the FIFO order; the runs themselves overlap in
        // time only if the coordinator lets them.
        await coordinator.nudge(.manual)
        await coordinator.nudge(.importOnly)
        await coordinator.nudge(.manual)
        let finished = try await EInkTestSupport.waitUntil {
            let count = await coordinator.runCount
            let running = await coordinator.isRunning
            return count == 3 && !running
        }
        XCTAssertTrue(finished)

        let awaited14 = await log.maxActive
        XCTAssertEqual(awaited14, 1, "two engine passes must never overlap")
        let awaited15 = await log.calls.map(\.importAnnotations)
        XCTAssertEqual(awaited15, [false, true, false], "FIFO order is kept")
        await coordinator.stop()
    }

    // MARK: - Import flag

    func testImportFlagFollowsTheDeviceTheReasonOrTheOverride() async throws {
        let log = RunLog()
        let autoImport = EInkSyncTarget(id: "dev-2", name: "rM", autoImportOnConnect: true)
        let coordinator = makeCoordinator(gate: .open, targets: [autoImport], log: log)
        await coordinator.start(observeNotifications: false)

        _ = try await coordinator.runNow(reason: .manual)                          // device says import
        _ = try await coordinator.runNow(reason: .manual, importOverride: false)   // the API said no
        let noAuto = makeCoordinator(gate: .open, log: log)                        // device says no
        _ = try await noAuto.runNow(reason: .manual)
        _ = try await noAuto.runNow(reason: .importOnly)                           // the reason forces it

        let awaited17 = await log.calls.map(\.importAnnotations)
        XCTAssertEqual(awaited17, [true, false, false, true])
        await coordinator.stop()
    }

    func testNoEnabledDeviceMeansNoRun() async throws {
        let log = RunLog()
        let coordinator = makeCoordinator(gate: .open, targets: [], log: log)
        let reports = try await coordinator.runNow(reason: .manual)
        XCTAssertTrue(reports.isEmpty)
        let awaited18 = await log.calls.count
        XCTAssertEqual(awaited18, 0)
        let awaited19 = await coordinator.runCount
        XCTAssertEqual(awaited19, 0)
    }

    // MARK: - Notifications

    func testTheMenuNotificationsDriveManualAndImportOnlyRuns() async throws {
        let log = RunLog()
        let coordinator = makeCoordinator(gate: EInkStartupGate(interval: 1000), log: log)
        await coordinator.start(observeNotifications: true)

        NotificationCenter.default.post(name: .einkSyncNow, object: nil)
        let awaited20 = try await EInkTestSupport.waitUntil { await log.calls.count == 1 }
        XCTAssertTrue(awaited20)
        NotificationCenter.default.post(name: .einkImportAnnotations, object: nil)
        let awaited21 = try await EInkTestSupport.waitUntil { await log.calls.count == 2 }
        XCTAssertTrue(awaited21)

        let awaited22 = await log.calls.map(\.importAnnotations)
        XCTAssertEqual(awaited22, [false, true])
        await coordinator.stop()
    }

    func testPrimaryReasonOrdering() {
        XCTAssertEqual(EInkSyncCoordinator.primary(of: [.connected, .marked]), .marked)
        XCTAssertEqual(EInkSyncCoordinator.primary(of: [.connected, .sourceArrived, .marked]), .sourceArrived)
        XCTAssertEqual(EInkSyncCoordinator.primary(of: [.settingsChanged, .sourceArrived]), .settingsChanged)
        XCTAssertEqual(EInkSyncCoordinator.primary(of: [.connected]), .connected)
    }
}
