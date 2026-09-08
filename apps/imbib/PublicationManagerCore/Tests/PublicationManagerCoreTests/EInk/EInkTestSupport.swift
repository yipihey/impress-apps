//
//  EInkTestSupport.swift
//  PublicationManagerCoreTests
//
//  Builders for the Rust-shaped records the P7 services consume, and a
//  polling helper. The records only have `init(from:)` over the UniFFI
//  rows, so tests build the FFI row and convert — the same path the app
//  takes, which is the point.
//

import Foundation
import ImbibRustCore
import XCTest
@testable import PublicationManagerCore

enum EInkTestSupport {

    static func syncReport(device: String = "dev-1", uploaded: [UUID] = [], inkPendingOCR: [(UUID, Int)] = []) -> PublicationManagerCore.EInkSyncReport {
        let summary = PlanSummary(
            toUpload: 0, awaitingSource: 0, awaitingFolder: 0, stale: 0, removed: 0,
            toImport: 0, unchanged: 0, skippedNoSource: 0, skippedScope: 0, foldersToCreate: 0)
        let imports = inkPendingOCR.map { id, pending in
            ImportedDocument(
                publicationId: id.uuidString, remoteId: "r-\(id.uuidString.prefix(4))",
                annotatedPdf: "/tmp/a.pdf", rmdoc: nil, annotatedFileId: nil,
                created: 0, updated: 0, deleted: 0, inkPendingOcr: UInt32(pending))
        }
        let row = ImbibRustCore.EinkSyncReport(
            deviceId: device, reachable: true, dryRun: false, summary: summary,
            uploaded: uploaded.map(\.uuidString), failed: [], folderNeeds: [], foldersCreated: [],
            imports: imports, pendingImports: 0, pendingUploads: 0, trace: [], durationMs: 1)
        return PublicationManagerCore.EInkSyncReport(from: row)
    }

    static func deviceRecord(id: String = "dev-1", enabled: Bool = true, autoImportOnConnect: Bool = false) -> EInkDeviceRecord {
        EInkDeviceRecord(from: EinkDeviceRow(
            id: id, name: "reMarkable", transport: "usb", baseUrl: "http://10.11.99.1",
            mirrorMode: "individual", rootFolderName: "imbib", mirrorCollections: true,
            includeLibraryLevel: true, includeInbox: true, folderStrategy: "rmdoc", uploadFormat: "rmdoc",
            autoFetchSource: true, importAnnotatedPdf: true, importRmdoc: true, importHighlights: true,
            importInk: true, importTypedText: true, runOcr: true, autoImportOnConnect: autoImportOnConnect,
            enabled: enabled, lastSyncAtMs: nil, lastSeenAtMs: nil, syncStartedAtMs: nil, lastError: nil,
            createdMs: 0))
    }

    static func awaiting(publicationId: UUID, mirrorId: String = UUID().uuidString, doi: String? = nil) -> EInkAwaitingSourceRecord {
        EInkAwaitingSourceRecord(from: EinkAwaitingSource(
            mirrorId: mirrorId, publicationId: publicationId.uuidString, citeKey: "Key2026",
            title: "A paper", doi: doi, arxivId: nil, url: nil))!
    }

    /// Poll until `condition` holds or `timeout` passes. Throwing sleeps only:
    /// a cancelled test task must not spin.
    static func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

/// A thread-safe counter for closures that run off any actor.
final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    private var records: [String] = []

    func bump(_ key: String = "count") {
        lock.lock(); defer { lock.unlock() }
        values[key, default: 0] += 1
    }

    func record(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        records.append(line)
    }

    subscript(key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return values[key, default: 0]
    }

    var count: Int { self["count"] }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return records
    }
}
