import XCTest
@testable import imprint

@MainActor
final class VeuszServiceTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeuszServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    private static let exampleVszCandidates = [
        "/Applications/Veusz.app/Contents/Resources/examples/contour.vsz",
        "/Applications/Veusz.app/Contents/Resources/examples/3d_function.vsz",
        "/Applications/Veusz.app/Contents/Resources/examples/2d_irregular.vsz",
    ]

    /// First bundled example .vsz that exists on disk, or nil.
    private func locateExampleVsz() -> URL? {
        for path in Self.exampleVszCandidates {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    func testInstallationDetection() throws {
        // This test is non-destructive: it asserts internal consistency between
        // locateApp / locateExecutable / installedVersion, not that Veusz is
        // necessarily installed.
        if VeuszService.isInstalled {
            XCTAssertNotNil(VeuszService.locateApp())
            XCTAssertNotNil(VeuszService.locateExecutable())
            XCTAssertNotNil(VeuszService.installedVersion(),
                            "Installed Veusz should expose a version string")
        } else {
            XCTAssertNil(VeuszService.locateExecutable())
        }
    }

    func testExportProducesSvg() async throws {
        try XCTSkipUnless(VeuszService.isInstalled,
                          "Veusz.app not installed at /Applications/Veusz.app — skipping render test")
        guard let example = locateExampleVsz() else {
            throw XCTSkip("No bundled Veusz example .vsz file found")
        }

        let destination = tempDirectory.appendingPathComponent("out.svg")
        let service = VeuszService()
        try await service.export(source: example, to: destination, format: .svg)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let size = attributes[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 500, "SVG output should be non-trivial in size")
    }

    func testExportNormalizesDestinationExtension() async throws {
        try XCTSkipUnless(VeuszService.isInstalled, "Veusz.app not installed")
        guard let example = locateExampleVsz() else {
            throw XCTSkip("No bundled Veusz example .vsz file found")
        }

        // Caller passes a path with the wrong extension; the service must rewrite
        // to .png so Veusz produces PNG output (it infers format from extension).
        let destinationWithWrongExt = tempDirectory.appendingPathComponent("out.svg")
        let expected = tempDirectory.appendingPathComponent("out.png")

        let service = VeuszService()
        try await service.export(source: example, to: destinationWithWrongExt, format: .png)

        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                      "Expected normalized .png destination")
    }

    func testExportFailsOnMissingSource() async throws {
        try XCTSkipUnless(VeuszService.isInstalled, "Veusz.app not installed")
        let missing = tempDirectory.appendingPathComponent("does-not-exist.vsz")
        let destination = tempDirectory.appendingPathComponent("out.svg")

        let service = VeuszService()
        do {
            try await service.export(source: missing, to: destination, format: .svg)
            XCTFail("Export should have failed on missing source")
        } catch let error as VeuszService.ExportError {
            if case .sourceFileMissing = error { return }
            XCTFail("Expected .sourceFileMissing, got \(error)")
        }
    }
}
