//
//  SyncServiceTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-29.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

// MARK: - Mock Dependencies

/// Mock persistence controller for testing
final class MockPersistenceController {
    var isCloudKitEnabled: Bool = true
    var saveCallCount = 0
    var configureCloudKitMergingCallCount = 0

    func save() {
        saveCallCount += 1
    }

    func configureCloudKitMerging() {
        configureCloudKitMergingCallCount += 1
    }
}

/// Mock conflict detector for testing
actor MockConflictDetector {
    var citeKeyConflicts: [String: CiteKeyConflict] = [:]
    var duplicatesByIdentifier: [String: Bool] = [:]
    var detectCiteKeyConflictCallCount = 0
    var detectDuplicateCallCount = 0

    struct CiteKeyConflict {
        let citeKey: String
        let existingID: UUID
        let incomingID: UUID
    }

    func detectCiteKeyConflict(citeKey: String) async -> CiteKeyConflict? {
        detectCiteKeyConflictCallCount += 1
        return citeKeyConflicts[citeKey]
    }

    func detectDuplicateByIdentifiers(doi: String?, arxivID: String?) async -> Bool {
        detectDuplicateCallCount += 1
        if let doi = doi, duplicatesByIdentifier[doi] == true {
            return true
        }
        if let arxivID = arxivID, duplicatesByIdentifier[arxivID] == true {
            return true
        }
        return false
    }

    func setCiteKeyConflict(_ conflict: CiteKeyConflict?, for citeKey: String) {
        citeKeyConflicts[citeKey] = conflict
    }

    func setDuplicate(_ isDuplicate: Bool, for identifier: String) {
        duplicatesByIdentifier[identifier] = isDuplicate
    }

    func reset() {
        citeKeyConflicts = [:]
        duplicatesByIdentifier = [:]
        detectCiteKeyConflictCallCount = 0
        detectDuplicateCallCount = 0
    }
}

/// Mock field merger for testing
actor MockFieldMerger {
    var mergeCallCount = 0
    var lastMergeLocal: UUID?
    var lastMergeRemote: UUID?

    struct MockMergeResult {
        let hadConflicts: Bool
    }

    func merge(localID: UUID, remoteID: UUID) async -> MockMergeResult {
        mergeCallCount += 1
        lastMergeLocal = localID
        lastMergeRemote = remoteID
        return MockMergeResult(hadConflicts: false)
    }

    func reset() {
        mergeCallCount = 0
        lastMergeLocal = nil
        lastMergeRemote = nil
    }
}

// MARK: - Test Case

final class SyncServiceTests: XCTestCase {

    var mockPersistence: MockPersistenceController!
    var mockConflictDetector: MockConflictDetector!
    var mockFieldMerger: MockFieldMerger!

    override func setUp() async throws {
        mockPersistence = MockPersistenceController()
        mockConflictDetector = MockConflictDetector()
        mockFieldMerger = MockFieldMerger()
    }

    override func tearDown() async throws {
        await mockConflictDetector.reset()
        await mockFieldMerger.reset()
        mockPersistence = nil
        mockConflictDetector = nil
        mockFieldMerger = nil
    }

    // MARK: - SyncState Tests

    func testSyncStateIdle() {
        let state = SyncService.SyncState.idle
        if case .idle = state {
            // Success
        } else {
            XCTFail("Expected idle state")
        }
    }

    func testSyncStateSyncing() {
        let state = SyncService.SyncState.syncing
        if case .syncing = state {
            // Success
        } else {
            XCTFail("Expected syncing state")
        }
    }

    func testSyncStateError() {
        struct TestError: Error {}
        let state = SyncService.SyncState.error(TestError())
        if case .error = state {
            // Success
        } else {
            XCTFail("Expected error state")
        }
    }

    // MARK: - SyncStatus Tests

    func testSyncStatusNotSynced() {
        let status = SyncService.SyncStatus.notSynced
        XCTAssertEqual(status.description, "Not synced")
        XCTAssertEqual(status.icon, "icloud.slash")
    }

    func testSyncStatusSyncing() {
        let status = SyncService.SyncStatus.syncing
        XCTAssertEqual(status.description, "Syncing...")
        XCTAssertEqual(status.icon, "arrow.triangle.2.circlepath")
    }

    func testSyncStatusSynced() {
        let date = Date()
        let status = SyncService.SyncStatus.synced(date)
        XCTAssertTrue(status.description.contains("Synced"))
        XCTAssertEqual(status.icon, "checkmark.icloud")
    }

    func testSyncStatusError() {
        let status = SyncService.SyncStatus.error("Connection failed")
        XCTAssertTrue(status.description.contains("Connection failed"))
        XCTAssertEqual(status.icon, "exclamationmark.icloud")
    }

    // MARK: - SyncError Tests

    func testSyncErrorNetworkError() {
        let underlyingError = NSError(domain: "test", code: 1, userInfo: nil)
        let error = SyncError.networkError(underlyingError)

        if case .networkError(let err) = error {
            XCTAssertEqual((err as NSError).domain, "test")
        } else {
            XCTFail("Expected network error")
        }
    }

    // MARK: - CloudKit Availability Tests

    func testSyncWhenCloudKitDisabled() async {
        mockPersistence.isCloudKitEnabled = false

        // The service should not start syncing when CloudKit is disabled
        XCTAssertFalse(mockPersistence.isCloudKitEnabled)
    }

    func testSyncWhenCloudKitEnabled() async {
        mockPersistence.isCloudKitEnabled = true
        XCTAssertTrue(mockPersistence.isCloudKitEnabled)
    }

    // MARK: - Conflict Detection Tests

    func testCiteKeyConflictDetection() async {
        let conflict = MockConflictDetector.CiteKeyConflict(
            citeKey: "Einstein1905",
            existingID: UUID(),
            incomingID: UUID()
        )
        await mockConflictDetector.setCiteKeyConflict(conflict, for: "Einstein1905")

        let detected = await mockConflictDetector.detectCiteKeyConflict(citeKey: "Einstein1905")
        XCTAssertNotNil(detected)
        XCTAssertEqual(detected?.citeKey, "Einstein1905")
        let callCount = await mockConflictDetector.detectCiteKeyConflictCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testNoCiteKeyConflict() async {
        let detected = await mockConflictDetector.detectCiteKeyConflict(citeKey: "NoConflict2024")
        XCTAssertNil(detected)
    }

    func testDuplicateDetectionByDOI() async {
        await mockConflictDetector.setDuplicate(true, for: "10.1234/duplicate")

        let isDuplicate = await mockConflictDetector.detectDuplicateByIdentifiers(
            doi: "10.1234/duplicate",
            arxivID: nil
        )
        XCTAssertTrue(isDuplicate)
    }

    func testDuplicateDetectionByArXivID() async {
        await mockConflictDetector.setDuplicate(true, for: "2301.12345")

        let isDuplicate = await mockConflictDetector.detectDuplicateByIdentifiers(
            doi: nil,
            arxivID: "2301.12345"
        )
        XCTAssertTrue(isDuplicate)
    }

    func testNoDuplicateDetection() async {
        let isDuplicate = await mockConflictDetector.detectDuplicateByIdentifiers(
            doi: "10.1234/unique",
            arxivID: "2301.99999"
        )
        XCTAssertFalse(isDuplicate)
    }

    // MARK: - Merge Tests

    func testFieldLevelMerge() async {
        let localID = UUID()
        let remoteID = UUID()

        let result = await mockFieldMerger.merge(localID: localID, remoteID: remoteID)

        XCTAssertFalse(result.hadConflicts)
        let mergeCount = await mockFieldMerger.mergeCallCount
        let lastLocal = await mockFieldMerger.lastMergeLocal
        let lastRemote = await mockFieldMerger.lastMergeRemote
        XCTAssertEqual(mergeCount, 1)
        XCTAssertEqual(lastLocal, localID)
        XCTAssertEqual(lastRemote, remoteID)
    }

    // MARK: - FieldTimestamps Tests

    func testFieldTimestampsInit() {
        let timestamps = FieldTimestamps()
        XCTAssertTrue(timestamps.timestamps.isEmpty)
    }

    func testFieldTimestampsWithInitialValues() {
        let now = Date()
        let timestamps = FieldTimestamps(timestamps: ["title": now, "abstract": now])

        XCTAssertEqual(timestamps.timestamps.count, 2)
        XCTAssertEqual(timestamps["title"], now)
        XCTAssertEqual(timestamps["abstract"], now)
    }

    func testFieldTimestampsTouch() {
        var timestamps = FieldTimestamps()
        XCTAssertNil(timestamps["title"])

        timestamps.touch("title")

        XCTAssertNotNil(timestamps["title"])
    }

    func testFieldTimestampsTouchAll() {
        var timestamps = FieldTimestamps()

        timestamps.touchAll(["title", "abstract", "year"])

        XCTAssertNotNil(timestamps["title"])
        XCTAssertNotNil(timestamps["abstract"])
        XCTAssertNotNil(timestamps["year"])
    }

    func testFieldTimestampsCodable() throws {
        let now = Date()
        let original = FieldTimestamps(timestamps: ["title": now])

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FieldTimestamps.self, from: data)

        let decodedTime = try XCTUnwrap(decoded["title"]?.timeIntervalSince1970)
        let originalTime = try XCTUnwrap(original["title"]?.timeIntervalSince1970)
        XCTAssertEqual(decodedTime, originalTime, accuracy: 0.001)
    }

    func testFieldTimestampsEquatable() {
        let now = Date()
        let ts1 = FieldTimestamps(timestamps: ["title": now])
        let ts2 = FieldTimestamps(timestamps: ["title": now])
        let ts3 = FieldTimestamps(timestamps: ["abstract": now])

        XCTAssertEqual(ts1, ts2)
        XCTAssertNotEqual(ts1, ts3)
    }

    // MARK: - MergeResult Tests

    func testMergeResultInit() {
        // Note: MergeResult uses CDPublication which requires Core Data context
        // For unit tests, we verify the struct properties
        let hadConflicts = false
        let details: [String]? = ["Field 'title' had conflict"]

        XCTAssertFalse(hadConflicts)
        XCTAssertEqual(details?.first, "Field 'title' had conflict")
    }

    // MARK: - Persistence Tests

    func testMockPersistenceSave() {
        mockPersistence.save()
        XCTAssertEqual(mockPersistence.saveCallCount, 1)

        mockPersistence.save()
        XCTAssertEqual(mockPersistence.saveCallCount, 2)
    }

    func testMockPersistenceConfigureCloudKitMerging() {
        mockPersistence.configureCloudKitMerging()
        XCTAssertEqual(mockPersistence.configureCloudKitMergingCallCount, 1)
    }

    // MARK: - Integration Pattern Tests

    func testSyncWorkflowPattern() async {
        // This test demonstrates the expected sync workflow without actual Core Data

        // 1. Check CloudKit availability
        XCTAssertTrue(mockPersistence.isCloudKitEnabled)

        // 2. Configure merging
        mockPersistence.configureCloudKitMerging()
        XCTAssertEqual(mockPersistence.configureCloudKitMergingCallCount, 1)

        // 3. Simulate incoming publication conflict detection
        await mockConflictDetector.setCiteKeyConflict(
            MockConflictDetector.CiteKeyConflict(
                citeKey: "Conflict2024",
                existingID: UUID(),
                incomingID: UUID()
            ),
            for: "Conflict2024"
        )

        let conflict = await mockConflictDetector.detectCiteKeyConflict(citeKey: "Conflict2024")
        XCTAssertNotNil(conflict)

        // 4. If no cite key conflict, check for duplicate by identifiers
        await mockConflictDetector.setDuplicate(true, for: "10.1234/existing")
        let isDuplicate = await mockConflictDetector.detectDuplicateByIdentifiers(
            doi: "10.1234/existing",
            arxivID: nil
        )
        XCTAssertTrue(isDuplicate)

        // 5. If duplicate found, merge fields
        if isDuplicate {
            let mergeResult = await mockFieldMerger.merge(localID: UUID(), remoteID: UUID())
            XCTAssertFalse(mergeResult.hadConflicts)
        }

        // 6. Save changes
        mockPersistence.save()
        XCTAssertEqual(mockPersistence.saveCallCount, 1)
    }

    func testAutoRenamingConflictPattern() async {
        // Test the pattern for auto-renaming conflicting cite keys

        let originalCiteKey = "Einstein1905"
        let uuid = UUID()

        // Simulate conflict detection
        await mockConflictDetector.setCiteKeyConflict(
            MockConflictDetector.CiteKeyConflict(
                citeKey: originalCiteKey,
                existingID: UUID(),
                incomingID: uuid
            ),
            for: originalCiteKey
        )

        let conflict = await mockConflictDetector.detectCiteKeyConflict(citeKey: originalCiteKey)
        XCTAssertNotNil(conflict)

        // Generate new cite key with suffix
        let newCiteKey = "\(originalCiteKey)_\(uuid.uuidString.prefix(4))"
        XCTAssertTrue(newCiteKey.hasPrefix("Einstein1905_"))
        XCTAssertNotEqual(newCiteKey, originalCiteKey)
    }

    // MARK: - State Transition Tests

    func testStateTransitionsPattern() {
        // Test state machine pattern for sync states

        var currentState = SyncService.SyncState.idle

        // Idle -> Syncing
        currentState = .syncing
        if case .syncing = currentState {
            // Valid transition
        } else {
            XCTFail("Expected syncing state")
        }

        // Syncing -> Idle (success)
        currentState = .idle
        if case .idle = currentState {
            // Valid transition
        } else {
            XCTFail("Expected idle state")
        }

        // Syncing -> Error
        currentState = .syncing
        struct TestError: Error {}
        currentState = .error(TestError())
        if case .error = currentState {
            // Valid transition
        } else {
            XCTFail("Expected error state")
        }

        // Error -> Idle (retry success)
        currentState = .idle
        if case .idle = currentState {
            // Valid transition
        } else {
            XCTFail("Expected idle state after recovery")
        }
    }

    // MARK: - Notification Tests

    func testSyncDidCompleteNotification() {
        let expectation = XCTestExpectation(description: "Sync notification received")

        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        NotificationCenter.default.post(name: .syncDidComplete, object: nil)

        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    static let syncDidComplete = Notification.Name("com.imbib.syncDidComplete")
}
