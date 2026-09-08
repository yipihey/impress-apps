//
//  EInkSettingsMigrationTests.swift
//  PublicationManagerCoreTests
//
//  The one-shot move of the legacy `eink.*` / `remarkable.*` preferences
//  into the device record (ADR-025 P7): the keys map onto
//  `EInkDeviceConfigInput`, are removed after a successful write, stay when
//  the write fails, and a second run is a no-op. Per-process UserDefaults
//  isolation via a throwaway suite, as the other settings tests do.
//

import Foundation
import XCTest
@testable import PublicationManagerCore

@MainActor
final class EInkSettingsMigrationTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "EInkSettingsMigrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// The writes the fake store saw.
    final class Writes: @unchecked Sendable {
        var inputs: [EInkDeviceConfigInput] = []
        var accept = true
    }

    private func migration(devices: [EInkDeviceRecord], writes: Writes) -> EInkSettingsMigration {
        EInkSettingsMigration(environment: .init(
            defaults: defaults,
            devices: { devices },
            configure: { input in
                writes.inputs.append(input)
                return writes.accept
            }))
    }

    private func seedLegacyKeys() {
        defaults.set("Papers", forKey: "remarkable.rootFolderName")
        defaults.set(false, forKey: "remarkable.createFoldersByCollection")
        defaults.set(true, forKey: "eink.useReadingQueueFolder")
        defaults.set(false, forKey: "eink.importHighlights")
        defaults.set(true, forKey: "remarkable.importInkNotes")
        defaults.set(false, forKey: "eink.enableOCR")
        defaults.set(true, forKey: "eink.autoSyncEnabled")
        defaults.set("auto", forKey: "eink.annotationImportMode")
        defaults.set(3600.0, forKey: "remarkable.syncInterval")
        defaults.set("ask", forKey: "eink.conflictResolution")
    }

    // MARK: - Mapping

    func testLegacyKeysMapOntoTheDeviceConfigInput() {
        seedLegacyKeys()
        let input = EInkSettingsMigration.input(from: defaults, deviceId: "dev-1")

        XCTAssertEqual(input.id, "dev-1")
        XCTAssertEqual(input.rootFolderName, "Papers")
        XCTAssertEqual(input.mirrorCollections, false)
        XCTAssertEqual(input.includeInbox, true)
        XCTAssertEqual(input.importHighlights, false)
        XCTAssertEqual(input.importInk, true)
        XCTAssertEqual(input.runOCR, false)
        XCTAssertEqual(input.autoImportOnConnect, true)
        XCTAssertNil(input.enabled, "the migration never flips an existing device on or off")
        XCTAssertNil(input.mirrorMode)
    }

    func testEinkKeysWinOverRemarkableKeysAndAbsentKeysStayNil() {
        defaults.set("A", forKey: "eink.rootFolderName")
        defaults.set("B", forKey: "remarkable.rootFolderName")
        defaults.set(true, forKey: "remarkable.enableOCR")
        let input = EInkSettingsMigration.input(from: defaults, deviceId: nil)

        XCTAssertEqual(input.rootFolderName, "A")
        XCTAssertEqual(input.runOCR, true)
        XCTAssertNil(input.importHighlights)
        XCTAssertNil(input.autoImportOnConnect)
    }

    func testReviewImportModeTurnsAutoImportOff() {
        defaults.set(true, forKey: "remarkable.autoSyncEnabled")
        defaults.set("review", forKey: "eink.annotationImportMode")
        XCTAssertEqual(EInkSettingsMigration.input(from: defaults, deviceId: nil).autoImportOnConnect, false)

        defaults.set("auto", forKey: "eink.annotationImportMode")
        defaults.set(false, forKey: "remarkable.autoSyncEnabled")
        XCTAssertEqual(EInkSettingsMigration.input(from: defaults, deviceId: nil).autoImportOnConnect, false)
    }

    // MARK: - Run

    func testLegacyKeysAreWrittenToTheDeviceThenRemovedAndTheSecondRunIsANoOp() {
        seedLegacyKeys()
        let writes = Writes()
        let device = EInkTestSupport.deviceRecord(id: "dev-1")
        let migration = migration(devices: [device], writes: writes)
        XCTAssertFalse(migration.isDone)
        XCTAssertEqual(migration.presentLegacyKeys.count, 10)

        let first = migration.runIfNeeded()

        XCTAssertEqual(first, .migrated(deviceId: "dev-1", created: false))
        XCTAssertEqual(writes.inputs.count, 1)
        XCTAssertEqual(writes.inputs.first?.id, "dev-1")
        XCTAssertEqual(writes.inputs.first?.rootFolderName, "Papers")
        XCTAssertTrue(migration.isDone)
        XCTAssertTrue(migration.presentLegacyKeys.isEmpty, "every legacy key is gone")
        XCTAssertTrue(defaults.bool(forKey: EInkSettingsMigration.markerKey))

        // Re-seeding after the marker must not re-migrate.
        seedLegacyKeys()
        let second = migration.runIfNeeded()
        XCTAssertEqual(second, .nothingToDo)
        XCTAssertEqual(writes.inputs.count, 1, "the marker makes the second run a no-op")
    }

    func testTheEnabledDeviceIsPreferredOverADisabledOne() {
        seedLegacyKeys()
        let writes = Writes()
        let disabled = EInkTestSupport.deviceRecord(id: "old", enabled: false)
        let enabled = EInkTestSupport.deviceRecord(id: "new", enabled: true)
        XCTAssertEqual(migration(devices: [disabled, enabled], writes: writes).runIfNeeded(), .migrated(deviceId: "new", created: false))
    }

    func testAFailedWriteKeepsTheKeysForTheNextAttempt() {
        seedLegacyKeys()
        let writes = Writes()
        writes.accept = false
        let migration = migration(devices: [EInkTestSupport.deviceRecord()], writes: writes)

        XCTAssertEqual(migration.runIfNeeded(), .failed)
        XCTAssertFalse(migration.isDone)
        XCTAssertEqual(migration.presentLegacyKeys.count, 10, "nothing is dropped until the store has it")

        writes.accept = true
        XCTAssertEqual(migration.runIfNeeded(), .migrated(deviceId: "dev-1", created: false))
        XCTAssertTrue(migration.isDone)
    }

    func testALegacyRemarkableWithoutARecordCreatesOneDisabledUnlessItWasUSB() {
        seedLegacyKeys()
        defaults.set(true, forKey: "remarkable.isAuthenticated")
        defaults.set("Tom's reMarkable", forKey: "remarkable.deviceName")
        defaults.set("cloud", forKey: "remarkable.activeBackendID")
        let writes = Writes()

        XCTAssertEqual(migration(devices: [], writes: writes).runIfNeeded(), .migrated(deviceId: nil, created: true))

        let created = writes.inputs.first
        XCTAssertNil(created?.id, "a nil id creates the record")
        XCTAssertEqual(created?.name, "Tom's reMarkable")
        XCTAssertEqual(created?.transport, EInkUSBTransport.rustName)
        XCTAssertEqual(EInkUSBTransport.rustName, "usb-web", "must match imbib_core::eink::TRANSPORT_USB_WEB — the engine rejects any other spelling")
        XCTAssertEqual(created?.enabled, false, "a cloud-paired tablet is not probed over USB until the person says so")
        XCTAssertEqual(created?.rootFolderName, "Papers")
        XCTAssertNotNil(defaults.string(forKey: "remarkable.deviceName"), "connection keys are not this migration's to remove")
    }

    func testALegacyUSBDeviceIsCreatedEnabled() {
        seedLegacyKeys()
        defaults.set("rm-1", forKey: "remarkable.deviceID")
        defaults.set("usb-web", forKey: "remarkable.activeBackendID")
        let writes = Writes()

        XCTAssertEqual(migration(devices: [], writes: writes).runIfNeeded(), .migrated(deviceId: nil, created: true))
        XCTAssertEqual(writes.inputs.first?.enabled, true)
        XCTAssertEqual(writes.inputs.first?.name, "reMarkable")
    }

    func testKeysWithNoDeviceAnywhereAreDroppedAndTheMarkerSet() {
        seedLegacyKeys()
        let writes = Writes()
        let migration = migration(devices: [], writes: writes)

        XCTAssertEqual(migration.runIfNeeded(), .droppedNoDevice)
        XCTAssertTrue(writes.inputs.isEmpty)
        XCTAssertTrue(migration.presentLegacyKeys.isEmpty)
        XCTAssertTrue(migration.isDone)
    }

    func testNothingLegacyJustSetsTheMarker() {
        let writes = Writes()
        let migration = migration(devices: [EInkTestSupport.deviceRecord()], writes: writes)
        XCTAssertEqual(migration.runIfNeeded(), .nothingToDo)
        XCTAssertTrue(migration.isDone)
        XCTAssertTrue(writes.inputs.isEmpty)
    }
}
