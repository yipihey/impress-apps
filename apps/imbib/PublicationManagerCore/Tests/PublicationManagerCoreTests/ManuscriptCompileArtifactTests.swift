#if os(macOS)
//
//  ManuscriptCompileArtifactTests.swift
//  PublicationManagerCoreTests
//
//  Where a headless compile parks its PDF, and the wire shape the compile
//  route promises.
//
//  `POST /api/manuscripts/{id}/compile` used to answer with `status` only and
//  a byte count. The Rust DTO (imbib-service `CompileResult`) is keyed on `ok`,
//  so a SUCCESSFUL compile decoded as a failure; and with no path on the wire,
//  `render_pdf_page` had nothing to open. Both are asserted here — driving the
//  full route needs a live store + the Typst engine, so these cover the two
//  pieces that were actually wrong.
//

import XCTest

@testable import PublicationManagerCore

final class ManuscriptCompileArtifactTests: XCTestCase {

    private let id = UUID()

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: ManuscriptFiguresDirectory.manuscriptRoot(for: id))
        super.tearDown()
    }

    /// The compile output lives under the manuscript's own root, beside
    /// `figures/`, and the directory is made on demand so a first compile
    /// doesn't fail on a missing path.
    func testCompiledPDFURLIsCreatedUnderTheManuscriptRoot() throws {
        let url = try ManuscriptFiguresDirectory.compiledPDFURL(for: id)

        XCTAssertEqual(url.lastPathComponent, "manuscript.pdf")
        XCTAssertTrue(
            url.path.hasPrefix(ManuscriptFiguresDirectory.manuscriptRoot(for: id).path),
            "artifact must stay inside the manuscript's directory: \(url.path)")
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: url.deletingLastPathComponent().path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    /// One stable path per manuscript: a second compile overwrites the first
    /// rather than growing the shared container without bound.
    func testCompiledPDFURLIsStableAcrossCompiles() throws {
        let first = try ManuscriptFiguresDirectory.compiledPDFURL(for: id)
        try Data("%PDF-1.7".utf8).write(to: first)
        let second = try ManuscriptFiguresDirectory.compiledPDFURL(for: id)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: second), Data("%PDF-1.7".utf8))
    }

    /// Every response from the compile route carries `ok` — the field the Rust
    /// DTO is keyed on — beside the router's `status` envelope. Asserted on
    /// the refusal path, which is the one reachable without a live store and a
    /// Typst engine; the success path sets `ok: output.isSuccess` from the
    /// same dictionary literal.
    func testCompileRouteAlwaysReportsOk() async throws {
        let response = await HTTPAutomationRouter.compileManuscript(
            id: UUID(), includePDF: false)

        XCTAssertEqual(response.status, 404, "an unknown manuscript is not found")
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(body["status"] as? String, "error", "`status` kept for back-compat")
        XCTAssertEqual(body["ok"] as? Bool, false, "the Rust DTO reads `ok`")
    }
}

#endif
