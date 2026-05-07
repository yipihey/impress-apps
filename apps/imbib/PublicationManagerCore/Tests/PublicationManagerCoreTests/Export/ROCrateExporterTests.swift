//
//  ROCrateExporterTests.swift
//  PublicationManagerCoreTests
//
//  Phase 5.2 tests: RO-Crate export of a manuscript-revision.
//  Verifies the directory structure and metadata.json contents.
//

import XCTest
@testable import PublicationManagerCore

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

final class ROCrateExporterTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ROCrateExporterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Build an isolated bridge + a manuscript-revision pair to export.
    private func freshBridge() throws -> (ManuscriptBridge, String) {
        let dbPath = tempDir.appendingPathComponent("test.sqlite").path
        let bridge = try ManuscriptBridge(testStorePath: dbPath)
        return (bridge, dbPath)
    }

    private func seedManuscriptWithRevision(
        bridge: ManuscriptBridge,
        dbPath: String,
        title: String,
        revisionTag: String,
        contentHash: String
    ) async throws -> (manuscriptID: String, revisionID: String) {
        let manuscriptID = try await bridge.createManuscript(title: title)
        // Seed a revision directly via SharedStore.
        let store = try SharedStore.open(path: dbPath)
        let revisionID = UUID().uuidString.lowercased()
        let payload: [String: Any] = [
            "parent_manuscript_ref": manuscriptID,
            "revision_tag": revisionTag,
            "content_hash": contentHash,
            "pdf_artifact_ref": "00000000-0000-0000-0000-000000000001",
            "source_archive_ref": "blob:sha256:\(contentHash)",
            "snapshot_reason": "manual",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try store.upsertItem(
            id: revisionID,
            schemaRef: "manuscript-revision",
            payloadJson: String(data: data, encoding: .utf8)!
        )
        return (manuscriptID, revisionID)
    }

    // MARK: - Tests

    func testExportProducesExpectedDirectoryStructure() async throws {
        let (bridge, dbPath) = try freshBridge()
        let pair = try await seedManuscriptWithRevision(
            bridge: bridge,
            dbPath: dbPath,
            title: "Test Manuscript",
            revisionTag: "submitted",
            contentHash: String(repeating: "a", count: 64)
        )

        let outputDir = tempDir.appendingPathComponent("output", isDirectory: true)
        let exporter = ROCrateExporter(bridge: bridge)
        let result = try await exporter.export(
            manuscriptID: pair.manuscriptID,
            revisionID: pair.revisionID,
            outputDirectory: outputDir
        )

        // Directory exists.
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.crateDirectory.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)

        // ro-crate-metadata.json exists.
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.metadataPath.path))

        // Subdirectories exist.
        let subdirs = ["sources", "pdfs", "bibliography", "reviews", "revision-notes"]
        for sub in subdirs {
            let path = result.crateDirectory.appendingPathComponent(sub).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "missing subdirectory: \(sub)")
        }

        // Source + PDF placeholders exist.
        let sourcePath = result.crateDirectory.appendingPathComponent("sources/submitted.tex").path
        let pdfPath = result.crateDirectory.appendingPathComponent("pdfs/submitted.pdf").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourcePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfPath))
    }

    func testMetadataJSONIsROCrate11Compliant() async throws {
        let (bridge, dbPath) = try freshBridge()
        let pair = try await seedManuscriptWithRevision(
            bridge: bridge,
            dbPath: dbPath,
            title: "Two-Point Function",
            revisionTag: "v1",
            contentHash: String(repeating: "b", count: 64)
        )

        let outputDir = tempDir.appendingPathComponent("output", isDirectory: true)
        let exporter = ROCrateExporter(bridge: bridge)
        let result = try await exporter.export(
            manuscriptID: pair.manuscriptID,
            revisionID: pair.revisionID,
            outputDirectory: outputDir
        )

        let data = try Data(contentsOf: result.metadataPath)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // @context must point at RO-Crate 1.1 spec.
        XCTAssertEqual(json["@context"] as? String, "https://w3id.org/ro/crate/1.1/context")

        // @graph must contain the metadata descriptor and root entity.
        let graph = try XCTUnwrap(json["@graph"] as? [[String: Any]])
        XCTAssertGreaterThan(graph.count, 2)

        // Metadata descriptor.
        let descriptor = graph.first { $0["@id"] as? String == "ro-crate-metadata.json" }
        XCTAssertNotNil(descriptor)
        XCTAssertEqual(descriptor?["@type"] as? String, "CreativeWork")

        // Root entity should be a Dataset with the manuscript title.
        let root = graph.first { $0["@id"] as? String == "./" }
        XCTAssertNotNil(root)
        XCTAssertEqual(root?["@type"] as? String, "Dataset")
        XCTAssertEqual(root?["name"] as? String, "Two-Point Function")

        // hasPart should reference each payload file.
        let hasPart = root?["hasPart"] as? [[String: Any]]
        XCTAssertNotNil(hasPart)
        XCTAssertGreaterThanOrEqual(hasPart?.count ?? 0, 3)  // source, pdf, bib at minimum
    }

    func testExportFailsForMissingManuscript() async throws {
        let (bridge, _) = try freshBridge()
        let outputDir = tempDir.appendingPathComponent("output", isDirectory: true)
        let exporter = ROCrateExporter(bridge: bridge)
        do {
            _ = try await exporter.export(
                manuscriptID: UUID().uuidString.lowercased(),
                revisionID: UUID().uuidString.lowercased(),
                outputDirectory: outputDir
            )
            XCTFail("expected manuscriptNotFound")
        } catch ROCrateExportError.manuscriptNotFound { /* ok */ }
        catch { XCTFail("unexpected error: \(error)") }
    }

    func testExportRequiresRevisionToBelongToManuscript() async throws {
        let (bridge, dbPath) = try freshBridge()
        let mA = try await bridge.createManuscript(title: "A")
        let pair = try await seedManuscriptWithRevision(
            bridge: bridge,
            dbPath: dbPath,
            title: "B",
            revisionTag: "v1",
            contentHash: String(repeating: "c", count: 64)
        )

        let outputDir = tempDir.appendingPathComponent("output", isDirectory: true)
        let exporter = ROCrateExporter(bridge: bridge)
        do {
            _ = try await exporter.export(
                manuscriptID: mA,                      // wrong parent
                revisionID: pair.revisionID,
                outputDirectory: outputDir
            )
            XCTFail("expected revisionNotFound (revision belongs to a different manuscript)")
        } catch ROCrateExportError.revisionNotFound { /* ok */ }
        catch { XCTFail("unexpected error: \(error)") }
    }
}
