//
//  DirectoryScannerTests.swift
//  PublicationManagerCoreTests
//
//  ADR-0023 D6/D7 — the bounded walk that backs the fallback engine and the
//  probe that proves a Spotlight blind spot.
//
//  Every test builds its own temp tree and removes it. Nothing here touches a
//  real user directory.
//

import XCTest

@testable import PublicationManagerCore

final class DirectoryScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-watch-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ relativePath: String, contents: String = "x") throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Extension filter first, UTI filter second — so a file both could claim
    /// attributes to the extension filter deterministically.
    private static let filters = [
        FileDiscoveryFilter(id: "bibtex", filenameExtensions: ["bib", "ris"]),
        FileDiscoveryFilter(id: "text", contentTypeIdentifiers: ["public.plain-text"]),
    ]

    // MARK: - Initial gather

    func testFindsNestedMatchesByExtension() throws {
        try write("top.bib")
        try write("nested/mid.ris")
        try write("nested/deeper/bottom.bib")
        try write("nested/deeper/ignored.png")

        let result = DirectoryScanner.scan(
            directory: root, filters: [Self.filters[0]], bounds: .default)

        XCTAssertEqual(result.files.count, 3)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(Set(result.files.map { $0.url.lastPathComponent }),
                       ["top.bib", "mid.ris", "bottom.bib"])
        XCTAssertTrue(result.files.allSatisfy { $0.filterID == "bibtex" })
    }

    func testFindsNestedMatchesByUTIConformanceWithNoExtensionDeclared() throws {
        // The UTI filter declares NO extensions, so every hit below is a
        // content-type conformance match — the half that catches a file whose
        // extension the app never listed.
        try write("notes.txt")
        try write("nested/deeper/readme.txt")
        try write("nested/binary.png", contents: "not really a png")

        let result = DirectoryScanner.scan(
            directory: root, filters: [Self.filters[1]], bounds: .default)

        let names = Set(result.files.map { $0.url.lastPathComponent })
        XCTAssertTrue(names.contains("notes.txt"))
        XCTAssertTrue(names.contains("readme.txt"))
        XCTAssertFalse(names.contains("binary.png"))
        XCTAssertTrue(result.files.allSatisfy { $0.filterID == "text" })
    }

    func testExtensionAndUTIFiltersCoexistAndAttributeIndependently() throws {
        try write("a.bib")
        try write("nested/b.bib")
        try write("nested/notes.txt")

        let result = DirectoryScanner.scan(
            directory: root, filters: Self.filters, bounds: .default)

        XCTAssertEqual(result.files.count, 3)
        let byFilter = Dictionary(grouping: result.files, by: \.filterID)
            .mapValues(\.count)
        XCTAssertEqual(byFilter["bibtex"], 2)
        XCTAssertEqual(byFilter["text"], 1)
    }

    func testResultsAreOrderedSoTwoRunsAgreeByteForByte() throws {
        for name in ["z.bib", "a.bib", "m/n.bib", "b/c.bib"] { try write(name) }

        let first = DirectoryScanner.scan(directory: root, filters: Self.filters)
        let second = DirectoryScanner.scan(directory: root, filters: Self.filters)

        XCTAssertEqual(first.files, second.files)
        XCTAssertEqual(
            first.files.map(\.url.path),
            first.files.map(\.url.path).sorted {
                $0.caseInsensitiveCompare($1) == .orderedAscending
            },
            "unordered output makes every re-scan diff look like churn")
    }

    func testCarriesModificationDateAndSize() throws {
        try write("a.bib", contents: "@article{x,}")
        let result = DirectoryScanner.scan(directory: root, filters: Self.filters)
        let file = try XCTUnwrap(result.files.first)
        XCTAssertNotNil(file.modificationDate)
        XCTAssertEqual(file.byteSize, 12)
    }

    // MARK: - Bounds (D7)

    func testDepthBoundStopsDescendingAndSaysSo() throws {
        try write("level0.bib")
        try write("one/level1.bib")
        try write("one/two/level2.bib")

        let result = DirectoryScanner.scan(
            directory: root, filters: Self.filters,
            bounds: FolderWalkBounds(maxDepth: 1))

        XCTAssertEqual(Set(result.files.map { $0.url.lastPathComponent }),
                       ["level0.bib", "level1.bib"])
        XCTAssertTrue(result.hitLimit, "a truncated walk must say it is truncated")
        XCTAssertFalse(result.isComplete)
    }

    func testFileBoundCapsTheResultAndFlagsIt() throws {
        for index in 0..<10 { try write("f\(index).bib") }

        let result = DirectoryScanner.scan(
            directory: root, filters: Self.filters,
            bounds: FolderWalkBounds(maxDepth: 4, maxFiles: 4))

        XCTAssertEqual(result.files.count, 4)
        XCTAssertTrue(result.hitLimit)
        XCTAssertFalse(result.isComplete)
    }

    func testHiddenDirectoriesAreSkippedByDefault() throws {
        try write("visible.bib")
        try write(".git/objects/hidden.bib")

        let result = DirectoryScanner.scan(directory: root, filters: Self.filters)
        XCTAssertEqual(result.files.map { $0.url.lastPathComponent }, ["visible.bib"])
    }

    func testAnEmptyFilterSetScansNothingRatherThanEverything() throws {
        try write("a.bib")
        XCTAssertEqual(
            DirectoryScanner.scan(directory: root, filters: []).files.count, 0)
        XCTAssertEqual(
            DirectoryScanner.scan(
                directory: root, filters: [FileDiscoveryFilter(id: "x")]).files.count, 0)
    }

    // MARK: - The probe (D6's counterexample)

    func testProbeStopsAtTheFirstMatch() throws {
        for index in 0..<20 { try write("f\(index).bib") }
        XCTAssertEqual(
            DirectoryScanner.probeForMatches(directory: root, filters: Self.filters), 1)
    }

    func testProbeFindsAMatchOneLevelDown() throws {
        try write("nested/only.bib")
        XCTAssertEqual(
            DirectoryScanner.probeForMatches(directory: root, filters: Self.filters), 1)
    }

    func testProbeReturnsZeroForAGenuinelyEmptyFolder() throws {
        try write("nested/unrelated.png")
        XCTAssertEqual(
            DirectoryScanner.probeForMatches(directory: root, filters: [Self.filters[0]]), 0)
    }

    func testIsReadableDirectoryRejectsAFile() throws {
        let file = try write("a.bib")
        XCTAssertTrue(DirectoryScanner.isReadableDirectory(root))
        XCTAssertFalse(DirectoryScanner.isReadableDirectory(file))
        XCTAssertFalse(DirectoryScanner.isReadableDirectory(
            root.appendingPathComponent("does-not-exist")))
    }

    // MARK: - Diffing

    func testDiffIsByURLSoATouchedFileIsNotANewOne() {
        let url = URL(fileURLWithPath: "/tmp/a.bib")
        let old = [DiscoveredFile(url: url, filterID: "bibtex", modificationDate: .distantPast)]
        let new = [DiscoveredFile(url: url, filterID: "bibtex", modificationDate: Date())]

        let diff = DiscoveryDiff.between(old: old, new: new)
        XCTAssertTrue(
            diff.isEmpty,
            "re-scan diffing is hash-keyed in Rust (D4); republishing every touched "
                + "file as an add would make incremental ingest impossible")
    }

    func testDiffReportsAddsAndRemovesOrdered() {
        let a = DiscoveredFile(url: URL(fileURLWithPath: "/tmp/a.bib"), filterID: "b")
        let b = DiscoveredFile(url: URL(fileURLWithPath: "/tmp/b.bib"), filterID: "b")
        let c = DiscoveredFile(url: URL(fileURLWithPath: "/tmp/c.bib"), filterID: "b")

        let diff = DiscoveryDiff.between(old: [a, b], new: [b, c])
        XCTAssertEqual(diff.added.map(\.url), [c.url])
        XCTAssertEqual(diff.removed, [a.url])
    }

    func testDiscoveredFileURLsAreStandardisedSoTwoEnginesAgree() {
        // A Spotlight result arrives as `/private/var/...`; a walk of the same
        // tree from `/var/...` would otherwise look like a remove plus an add.
        let viaSymlink = DiscoveredFile(
            url: URL(fileURLWithPath: "/tmp/./sub/../a.bib"), filterID: "b")
        XCTAssertEqual(viaSymlink.url, URL(fileURLWithPath: "/tmp/a.bib").standardizedFileURL)
    }
}
