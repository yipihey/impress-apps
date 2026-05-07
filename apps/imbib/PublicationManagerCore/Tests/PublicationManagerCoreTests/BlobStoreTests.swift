//
//  BlobStoreTests.swift
//  PublicationManagerCoreTests
//
//  Phase 0 of the journal pipeline (per docs/plan-journal-pipeline.md §3.1).
//  Verifies content-addressed storage, idempotency, two-level path layout,
//  and the unreferenced-sweep tombstone behavior.
//

import XCTest
@testable import PublicationManagerCore

final class BlobStoreTests: XCTestCase {

    var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlobStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Round trip

    func testStoreThenLocateRoundTrip() async throws {
        let store = BlobStore(rootURL: tempRoot)
        let payload = "hello journal pipeline".data(using: .utf8)!

        let (sha, url) = try await store.store(data: payload, ext: "pdf")

        XCTAssertEqual(sha.count, 64, "SHA-256 hex must be 64 chars")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let located = await store.locate(sha256: sha, ext: "pdf")
        XCTAssertEqual(located?.path, url.path)

        let readBack = try Data(contentsOf: url)
        XCTAssertEqual(readBack, payload)

        // Locating a missing blob should return nil.
        let missing = await store.locate(sha256: sha, ext: "tar.zst")
        XCTAssertNil(missing)
    }

    // MARK: - Idempotency

    func testStoreIsIdempotent() async throws {
        let store = BlobStore(rootURL: tempRoot)
        let payload = Data(repeating: 0x42, count: 4096)

        let (sha1, url1) = try await store.store(data: payload, ext: "pdf")
        let firstMtime = try url1.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate

        // Sleep briefly so a re-write would produce a different mtime.
        try await Task.sleep(nanoseconds: 50_000_000)

        let (sha2, url2) = try await store.store(data: payload, ext: "pdf")
        let secondMtime = try url2.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate

        XCTAssertEqual(sha1, sha2)
        XCTAssertEqual(url1.path, url2.path)
        XCTAssertEqual(
            firstMtime, secondMtime,
            "second store call must NOT re-write an existing blob"
        )
    }

    // MARK: - Distinct extensions produce distinct files

    func testStoreDifferentExtensions() async throws {
        let store = BlobStore(rootURL: tempRoot)
        let payload = "shared content".data(using: .utf8)!

        let (shaPdf, urlPdf) = try await store.store(data: payload, ext: "pdf")
        let (shaArchive, urlArchive) = try await store.store(data: payload, ext: "tar.zst")

        XCTAssertEqual(shaPdf, shaArchive, "same data → same hash regardless of ext")
        XCTAssertNotEqual(urlPdf.path, urlArchive.path, "different ext → different file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlPdf.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlArchive.path))
    }

    // MARK: - Two-level path prefix

    func testTwoLevelPathPrefix() async throws {
        let store = BlobStore(rootURL: tempRoot)
        let payload = "layout test".data(using: .utf8)!

        let (sha, url) = try await store.store(data: payload, ext: "pdf")
        let prefix1 = String(sha.prefix(2))
        let prefix2 = String(sha.dropFirst(2).prefix(2))
        let expected = tempRoot
            .appendingPathComponent(prefix1, isDirectory: true)
            .appendingPathComponent(prefix2, isDirectory: true)
            .appendingPathComponent("\(sha).pdf")
        XCTAssertEqual(url.path, expected.path)
    }

    // MARK: - Unreferenced sweep

    func testUnreferencedSweepMovesOrphans() async throws {
        let store = BlobStore(rootURL: tempRoot)
        let a = Data("alpha".utf8)
        let b = Data("beta".utf8)
        let c = Data("gamma".utf8)

        let (shaA, urlA) = try await store.store(data: a, ext: "pdf")
        let (shaB, urlB) = try await store.store(data: b, ext: "pdf")
        let (shaC, urlC) = try await store.store(data: c, ext: "pdf")

        // Only `a` is still referenced.
        let referenced: Set<String> = [shaA]
        let moved = try await store.unreferencedSweep(referencedHashes: referenced)

        XCTAssertEqual(moved.count, 2, "expected b and c to be tombstoned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path), "a must remain in place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: urlB.path), "b must be moved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: urlC.path), "c must be moved")

        // All moved files must be under .tombstones/{date}/
        for tombstoned in moved {
            XCTAssertTrue(
                tombstoned.path.contains("/.tombstones/"),
                "tombstoned file must live under .tombstones: \(tombstoned.path)"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: tombstoned.path))
        }

        // Sweeping again with `a` still referenced should be a no-op.
        let secondSweep = try await store.unreferencedSweep(referencedHashes: referenced)
        XCTAssertTrue(secondSweep.isEmpty, "second sweep should find no new orphans")

        _ = shaB; _ = shaC // silence unused warnings
    }

    // MARK: - parseSHA256(fromFilename:) helper

    func testParseSHA256RecognizesValidFilenames() {
        let sha = String(repeating: "a", count: 64)
        XCTAssertEqual(BlobStore.parseSHA256(fromFilename: "\(sha).pdf"), sha)
        XCTAssertEqual(BlobStore.parseSHA256(fromFilename: "\(sha).tar.zst"), sha)
        XCTAssertNil(BlobStore.parseSHA256(fromFilename: "no-extension"))
        XCTAssertNil(BlobStore.parseSHA256(fromFilename: "tooshort.pdf"))
        XCTAssertNil(BlobStore.parseSHA256(fromFilename: "\(String(repeating: "g", count: 64)).pdf"),
                     "non-hex chars must fail")
    }
}
