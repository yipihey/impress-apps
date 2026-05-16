//
//  BackupUtilitiesTests.swift
//  ImpressBackup
//

import XCTest
@testable import ImpressBackup

final class BackupUtilitiesTests: XCTestCase {

    func testFormatTimestamp() {
        let date = Date(timeIntervalSince1970: 0) // 1970-01-01T00:00:00Z
        let timestamp = BackupDirectoryManager.formatTimestamp(date)

        XCTAssertTrue(timestamp.contains("1970"))
        XCTAssertFalse(timestamp.contains(":")) // Colons should be replaced
    }

    func testBackupProgress() {
        enum TestPhase: BackupPhase {
            case copying
            var displayName: String { "Copying files..." }
        }

        let progress = BackupProgress(
            phase: TestPhase.copying,
            current: 5,
            total: 10,
            currentItem: "file.pdf"
        )

        XCTAssertEqual(progress.fractionComplete, 0.5)
        XCTAssertEqual(progress.currentItem, "file.pdf")
    }

    func testBackupProgressZeroTotal() {
        enum TestPhase: BackupPhase {
            case idle
            var displayName: String { "Idle" }
        }

        let progress = BackupProgress(
            phase: TestPhase.idle,
            current: 0,
            total: 0,
            currentItem: nil
        )

        XCTAssertEqual(progress.fractionComplete, 0.0)
    }

    func testBackupInfoSizeString() {
        let info = BackupInfo(
            url: URL(fileURLWithPath: "/tmp/test"),
            name: "test-backup",
            createdAt: Date(),
            sizeBytes: 1024 * 1024 // 1 MB
        )

        XCTAssertFalse(info.sizeString.isEmpty)
        // ByteCountFormatter will return something like "1 MB"
    }

    func testChecksumConsistency() {
        let data1 = "Hello, World!".data(using: .utf8)!
        let data2 = "Hello, World!".data(using: .utf8)!
        let data3 = "Goodbye, World!".data(using: .utf8)!

        let checksum1 = ChecksumUtilities.computeChecksum(for: data1)
        let checksum2 = ChecksumUtilities.computeChecksum(for: data2)
        let checksum3 = ChecksumUtilities.computeChecksum(for: data3)

        // Same data should produce same checksum
        XCTAssertEqual(checksum1, checksum2)

        // Different data should produce different checksum
        XCTAssertNotEqual(checksum1, checksum3)

        // Checksum should be hex string of length 64 (32 bytes * 2)
        XCTAssertEqual(checksum1.count, 64)
    }
}
