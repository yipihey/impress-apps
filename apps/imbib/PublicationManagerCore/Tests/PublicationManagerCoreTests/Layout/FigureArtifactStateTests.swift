//
//  FigureArtifactStateTests.swift
//  PublicationManagerCoreTests
//
//  What `FigureArtifactView` (the figure View tab and the `plot` pane) draws
//  for a `data_hash`, decided FFI-free: the bytes come from a closure, not
//  the store. Each reason it cannot draw has its own name, and when a figure
//  surface re-reads its row: its own id, or `.structural` — the only shape
//  in which a write from another process (implore storing an artifact while
//  impress shows the figure) reaches this one.
//

import ImpressStoreKit
import XCTest

@testable import PublicationManagerCore

final class FigureArtifactStateTests: XCTestCase {

    /// A 1×1 PNG: what implore stores under `data_hash`.
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    private let svg = Data("""
        <?xml version="1.0"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="5"><rect width="10" height="5"/></svg>
        """.utf8)

    private let hash = String(repeating: "ab", count: 32)

    func testNoHashIsNoArtifact() {
        XCTAssertTrue(isNoArtifact(FigureArtifactState.resolve(dataHash: nil, bytes: { _ in nil })))
        XCTAssertTrue(isNoArtifact(FigureArtifactState.resolve(dataHash: "", bytes: { _ in nil })))
    }

    func testAHashWithNoBytesIsNamedMissing() {
        guard case .missingBytes(let h) = FigureArtifactState.resolve(dataHash: hash, bytes: { _ in nil })
        else { return XCTFail("expected missingBytes") }
        XCTAssertEqual(h, hash)
    }

    func testAStoredPNGDraws() {
        var asked: String?
        let state = FigureArtifactState.resolve(dataHash: hash, bytes: { asked = $0; return self.png })
        XCTAssertEqual(asked, hash, "the bytes are looked up by the row's data_hash")
        XCTAssertTrue(state.isImage)
    }

    func testSVGDrawsOnMacAndIsNamedWhereItCannot() {
        let state = FigureArtifactState.resolve(dataHash: hash, bytes: { _ in self.svg })
        #if os(macOS)
        XCTAssertTrue(state.isImage, "NSImage decodes SVG")
        #else
        guard case .undecodableSVG = state else { return XCTFail("expected undecodableSVG") }
        #endif
        XCTAssertTrue(FigureArtifactState.looksLikeSVG(svg))
        XCTAssertFalse(FigureArtifactState.looksLikeSVG(png))
    }

    func testGarbageIsUndecodableNotSVG() {
        guard case .undecodable = FigureArtifactState.resolve(
            dataHash: hash, bytes: { _ in Data("not an image".utf8) })
        else { return XCTFail("expected undecodable") }
    }

    // MARK: - Refresh rule

    private let figure = UUID(uuidString: "C563336D-1111-4222-8333-444455556666")!

    func testAMutationNamingTheFigureRereads() {
        XCTAssertTrue(FigureArtifactRefresh.shouldReread(
            .itemsMutated(kind: .otherField, ids: [figure]), figureID: figure))
        XCTAssertFalse(FigureArtifactRefresh.shouldReread(
            .itemsMutated(kind: .otherField, ids: [UUID()]), figureID: figure))
    }

    /// The cross-process path: `StoreMutationObserver` turns the Darwin note
    /// into `noteExternalMutation(structural: true)`, which carries no ids.
    func testStructuralRereadsBecauseAnotherProcessesWriteArrivesThatWay() {
        XCTAssertTrue(FigureArtifactRefresh.shouldReread(.structural, figureID: figure))
    }

    func testCollectionMembershipDoesNotReread() {
        XCTAssertFalse(FigureArtifactRefresh.shouldReread(
            .collectionMembershipChanged(collectionID: UUID()), figureID: figure))
    }

    private func isNoArtifact(_ s: FigureArtifactState) -> Bool {
        if case .noArtifact = s { return true }
        return false
    }
}
