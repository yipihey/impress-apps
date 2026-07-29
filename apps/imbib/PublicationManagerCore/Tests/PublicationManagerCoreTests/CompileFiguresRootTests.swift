//
//  CompileFiguresRootTests.swift
//  PublicationManagerCoreTests
//
//  `CompileInputs.figuresRoot` is what makes `image("figures/plot.png")`
//  resolve: without it the Typst engine has no filesystem root and the WHOLE
//  document fails to compile, not just the figure. imprint's iOS editor built
//  its `CompileInputs` without one, so any manuscript with a figure produced
//  nothing on iPhone/iPad.
//
//  This drives the real engine through both paths so the parameter can't be
//  dropped again silently.
//

import XCTest
import ImprintCore

@testable import PublicationManagerCore

final class CompileFiguresRootTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("figures-root-test-\(UUID().uuidString)", isDirectory: true)
        let figures = root.appendingPathComponent("figures", isDirectory: true)
        try FileManager.default.createDirectory(at: figures, withIntermediateDirectories: true)
        try Self.tinyPNG().write(to: figures.appendingPathComponent("plot.png"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let source = """
    = Figure test

    #image("figures/plot.png", width: 40%)
    """

    func testFigureResolvesWhenFiguresRootIsProvided() async throws {
        let output = try await TypstRenderer().render(
            Self.source, options: RenderOptions(figuresRoot: root.path))

        XCTAssertTrue(
            output.isSuccess,
            "compile with figuresRoot should succeed, got: \(output.errors)")
        XCTAssertFalse(output.pdfData.isEmpty)
    }

    func testSameSourceFailsWithoutFiguresRoot() async throws {
        let output = try await TypstRenderer().render(
            Self.source, options: RenderOptions(figuresRoot: nil))

        XCTAssertFalse(
            output.isSuccess,
            "without figuresRoot the figure has no filesystem root — the whole "
                + "document must fail, which is the iOS bug this guards")
    }

    /// `ManuscriptFiguresDirectory.manuscriptRoot` is the root BOTH the macOS
    /// session and the iOS editor pass, so a figure written by one is visible
    /// to the other.
    func testManuscriptRootIsTheFiguresParent() throws {
        let id = UUID()
        defer { try? FileManager.default.removeItem(at: ManuscriptFiguresDirectory.manuscriptRoot(for: id)) }
        let figures = try ManuscriptFiguresDirectory.figuresDirectory(for: id)
        XCTAssertEqual(
            figures.deletingLastPathComponent().standardizedFileURL,
            ManuscriptFiguresDirectory.manuscriptRoot(for: id).standardizedFileURL)
        XCTAssertEqual(figures.lastPathComponent, "figures")
    }

    // MARK: - Helpers

    /// A 1×1 opaque PNG, written by hand so the test needs no fixture file.
    private static func tinyPNG() -> Data {
        Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!
    }
}
