import XCTest
@testable import imprint

@MainActor
final class VeuszPlotStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var storage: VeuszWorkingDirectory!
    private var renderer: StubRenderer!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeuszPlotStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let captured = tempRoot!
        storage = VeuszWorkingDirectory(containerRootProvider: { captured })
        renderer = StubRenderer()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    func testWorkingDirectoryMaterializeAndRead() throws {
        let docID = UUID()
        let payload = ["a.vsz": Data("hello".utf8), "b.svg": Data("<svg/>".utf8)]
        let dir = try storage.materializeFigures(payload, for: docID)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "a.vsz").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "b.svg").path))

        let readBack = try storage.readFigures(for: docID)
        XCTAssertEqual(readBack, payload)
    }

    func testCreatePlotWritesVszAndCallsRenderer() async throws {
        let docID = UUID()
        var notifications = 0
        let store = try VeuszPlotStore(
            documentID: docID,
            initialPlots: [],
            initialFigureFiles: [:],
            renderer: renderer,
            storage: storage,
            onChange: { _ in notifications += 1 }
        )

        let plot = try await store.createPlot(name: "Test Plot")

        XCTAssertEqual(store.plots.count, 1)
        XCTAssertEqual(store.plots[0].id, plot.id)
        XCTAssertEqual(plot.displayName, "Test Plot")
        XCTAssertEqual(plot.sourceRelativePath, "figures/Test Plot.vsz")
        XCTAssertEqual(plot.renderedRelativePath, "figures/Test Plot.svg")
        XCTAssertEqual(plot.renderStatus, .idle)

        let vszPath = store.workingDirectory.appending(path: "Test Plot.vsz")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vszPath.path))

        // Stub renderer should have been called once.
        XCTAssertEqual(renderer.exportCallCount, 1)

        // onChange fires multiple times (create, render-started, render-finished).
        XCTAssertGreaterThanOrEqual(notifications, 2)
    }

    func testCreatePlotMarksFailureWhenRendererThrows() async throws {
        renderer.exportShouldFail = true
        let store = try VeuszPlotStore(
            documentID: UUID(),
            initialPlots: [],
            initialFigureFiles: [:],
            renderer: renderer,
            storage: storage
        )

        let plot = try await store.createPlot(name: "broken")
        guard case .failed(let message) = plot.renderStatus else {
            return XCTFail("Expected .failed render status, got \(plot.renderStatus)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testDeletePlotRemovesFiles() async throws {
        let store = try VeuszPlotStore(
            documentID: UUID(),
            initialPlots: [],
            initialFigureFiles: [:],
            renderer: renderer,
            storage: storage
        )
        let plot = try await store.createPlot(name: "doomed")
        let vszPath = store.workingDirectory.appending(path: "doomed.vsz")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vszPath.path))

        store.deletePlot(plot.id)

        XCTAssertTrue(store.plots.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vszPath.path))
    }

    func testRerenderCallsRendererAgain() async throws {
        let store = try VeuszPlotStore(
            documentID: UUID(),
            initialPlots: [],
            initialFigureFiles: [:],
            renderer: renderer,
            storage: storage
        )
        let plot = try await store.createPlot(name: "rerender me")
        XCTAssertEqual(renderer.exportCallCount, 1)

        await store.rerender(plotID: plot.id)
        XCTAssertEqual(renderer.exportCallCount, 2)
    }

    func testInitialPlotsAreLoadedAndFilesMaterialized() throws {
        let docID = UUID()
        let plot = VeuszPlotRef(
            displayName: "Existing",
            sourceRelativePath: "figures/existing.vsz",
            renderedRelativePath: "figures/existing.svg"
        )
        let figures: [String: Data] = [
            "existing.vsz": Data("# vsz".utf8),
            "existing.svg": Data("<svg/>".utf8),
        ]
        let store = try VeuszPlotStore(
            documentID: docID,
            initialPlots: [plot],
            initialFigureFiles: figures,
            renderer: renderer,
            storage: storage
        )

        XCTAssertEqual(store.plots.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.workingDirectory.appending(path: "existing.vsz").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.workingDirectory.appending(path: "existing.svg").path
        ))

        // currentFigureFiles round-trips the materialized bytes.
        let snapshot = store.currentFigureFiles()
        XCTAssertEqual(snapshot, figures)
    }

    func testSanitizeNameStripsUnsafeCharacters() {
        XCTAssertEqual(VeuszPlotStore.sanitize(name: "  Plot/One  "), "Plot-One")
        XCTAssertEqual(VeuszPlotStore.sanitize(name: "a:b*c?d"), "a-b-c-d")
        XCTAssertEqual(VeuszPlotStore.sanitize(name: "   "), "Untitled Plot")
    }
}

/// Renderer stub: simulates Veusz by touching the destination file (so post-render
/// existence checks succeed) and tracking call count.
@MainActor
final class StubRenderer: VeuszRendering {
    var exportCallCount = 0
    var exportShouldFail = false
    var openCallCount = 0

    nonisolated func openInVeusz(_ url: URL) -> Bool {
        Task { @MainActor in openCallCount += 1 }
        return true
    }

    func export(source: URL, to destination: URL, format: VeuszPlotRef.ExportFormat) async throws {
        exportCallCount += 1
        if exportShouldFail {
            throw NSError(domain: "StubRendererError", code: 1, userInfo: [NSLocalizedDescriptionKey: "stub failure"])
        }
        let parent = destination.deletingPathExtension().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("<rendered/>".utf8).write(to: destination)
    }
}
