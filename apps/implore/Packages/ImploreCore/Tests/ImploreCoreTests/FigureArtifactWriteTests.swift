//
//  FigureArtifactWriteTests.swift
//  ImploreCoreTests
//
//  The one figure write path (`ImploreStoreAdapter.storeFigure`) against a
//  real store — the unit-test process gets a per-process temp workspace
//  (`SharedWorkspace`), so this touches no user data. A figure's row and its
//  artifact blob stay in step through create, edit, export and delete, and a
//  blob another row still names is never taken.
//

import CryptoKit
import XCTest

@testable import ImploreCore

@MainActor
final class FigureArtifactWriteTests: XCTestCase {

    private let adapter = ImploreStoreAdapter.shared

    private func viewState(title: String) -> String {
        #"{"type":"scatter","title":"\#(title)","width":200,"height":100,"xColumn":"m","yColumn":"r","series":[{"x":[1,2,3],"y":[3,1,2]}]}"#
    }

    private func blobURL(_ hash: String) -> URL {
        adapter.contentStoreDirectory.appendingPathComponent(hash)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testCreateEditExportDeleteKeepRowAndBlobInStep() throws {
        try XCTSkipUnless(adapter.isReady, "store did not open")
        let id = UUID().uuidString

        // Create: the row names a PNG that is really in the workspace CAS.
        let created = adapter.storeFigure(
            figureID: id, title: "t", caption: nil, viewStateJSON: viewState(title: "one"))
        XCTAssertTrue(created.saved)
        let first = try XCTUnwrap(created.artifact, created.renderError ?? "")
        XCTAssertEqual(first.format, "png")
        XCTAssertEqual([first.width, first.height], [200, 100])
        XCTAssertEqual(adapter.figureDataHash(figureID: id), first.dataHash)
        let bytes = try Data(contentsOf: blobURL(first.dataHash))
        XCTAssertEqual(Array(bytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "a PNG")
        XCTAssertEqual(sha256(bytes), first.dataHash, "content-addressed by sha256")
        XCTAssertEqual(
            adapter.contentStoreDirectory.standardizedFileURL.path,
            adapter.workspaceDirectory.appendingPathComponent("content").standardizedFileURL.path,
            "the store's own blob root, next to the database")

        // Re-storing the unchanged figure is the same artifact.
        let again = adapter.storeFigure(
            figureID: id, title: "t", caption: nil, viewStateJSON: viewState(title: "one"))
        XCTAssertEqual(again.artifact?.dataHash, first.dataHash)
        XCTAssertNil(again.releasedHash)

        // Edit: a new artifact, and the superseded blob goes.
        let edited = adapter.storeFigure(
            figureID: id, title: "t", caption: nil, viewStateJSON: viewState(title: "two"))
        let second = try XCTUnwrap(edited.artifact)
        XCTAssertNotEqual(second.dataHash, first.dataHash)
        XCTAssertEqual(edited.releasedHash, first.dataHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobURL(first.dataHash).path))
        XCTAssertEqual(adapter.figureDataHash(figureID: id), second.dataHash)

        // Export: a real file; a default PNG is the stored artifact itself.
        let png = try adapter.exportFigure(
            figureID: id, viewStateJSON: viewState(title: "two"), format: "png")
        XCTAssertEqual(png.sha256, second.dataHash)
        XCTAssertTrue(png.path.hasSuffix("/exports/figures/\(id.lowercased()).png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path))
        let svg = try adapter.exportFigure(
            figureID: id, viewStateJSON: viewState(title: "two"), format: "svg")
        XCTAssertTrue(try String(contentsOfFile: svg.path, encoding: .utf8).contains("<svg"))
        XCTAssertThrowsError(try adapter.exportFigure(
            figureID: id, viewStateJSON: viewState(title: "two"), format: "pdf"))

        // Delete: row, blob and exports all go.
        let deletion = adapter.deleteFigure(figureID: id)
        XCTAssertTrue(deletion.rowDeleted)
        XCTAssertEqual(deletion.dataHash, second.dataHash)
        XCTAssertTrue(deletion.blobReleased)
        XCTAssertEqual(deletion.exportsRemoved, 2)
        XCTAssertNil(adapter.figureDataHash(figureID: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobURL(second.dataHash).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: png.path))
    }

    /// Two figures drawn identically share one blob; deleting one leaves it
    /// for the other.
    func testDeleteKeepsABlobAnotherFigureStillNames() throws {
        try XCTSkipUnless(adapter.isReady, "store did not open")
        let (a, b) = (UUID().uuidString, UUID().uuidString)
        let vs = viewState(title: "shared \(UUID().uuidString.prefix(8))")
        let hashA = try XCTUnwrap(adapter.storeFigure(
            figureID: a, title: "a", caption: nil, viewStateJSON: vs).artifact?.dataHash)
        let hashB = try XCTUnwrap(adapter.storeFigure(
            figureID: b, title: "b", caption: nil, viewStateJSON: vs).artifact?.dataHash)
        XCTAssertEqual(hashA, hashB)

        let first = adapter.deleteFigure(figureID: a)
        XCTAssertTrue(first.rowDeleted)
        XCTAssertFalse(first.blobReleased)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobURL(hashA).path))

        let second = adapter.deleteFigure(figureID: b)
        XCTAssertTrue(second.blobReleased)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobURL(hashA).path))
    }

    /// A view state Rust cannot parse still writes the row, names why, and
    /// never invents a `data_hash`.
    func testAnUnrenderableViewStateIsNamedNotStored() throws {
        try XCTSkipUnless(adapter.isReady, "store did not open")
        let id = UUID().uuidString
        let write = adapter.storeFigure(
            figureID: id, title: "bad", caption: nil, viewStateJSON: "{not json")
        XCTAssertNil(write.artifact)
        XCTAssertNotNil(write.renderError)
        XCTAssertNil(adapter.figureDataHash(figureID: id))
        adapter.deleteFigure(figureID: id)
    }
}
