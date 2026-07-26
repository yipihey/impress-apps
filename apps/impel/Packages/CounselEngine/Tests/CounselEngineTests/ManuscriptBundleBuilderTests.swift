//
//  ManuscriptBundleBuilderTests.swift
//  CounselEngineTests
//
//  Phase 8.3 tests for ManuscriptBundleBuilder + ManuscriptBundleReader.
//  Verifies dir → tar.zst → reader extraction round-trip, manifest
//  correctness, exclude-glob behaviour, role classification, and
//  determinism (same dir → same SHA across two runs).
//

import CryptoKit
import Foundation
import Testing
@testable import CounselEngine

@Suite(.serialized)
struct ManuscriptBundleBuilderTests {

    // MARK: - Test fixture factory

    private static func makeBlobRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("impress-bundle-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeFile(_ contents: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Build a tex-style fixture: paper.tex, references.bib, figures/fig1.png,
    /// supplements/appendix.tex, plus a *.aux noise file that should be excluded.
    private static func makeTexFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tex-paper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeFile("\\documentclass{article}\\begin{document}hi\\end{document}",
                      at: dir.appendingPathComponent("paper.tex"))
        try writeFile("@article{foo,title={Foo}}",
                      at: dir.appendingPathComponent("references.bib"))
        try writeFile("PNG-FAKE",
                      at: dir.appendingPathComponent("figures/fig1.png"))
        try writeFile("\\section{Appendix}",
                      at: dir.appendingPathComponent("supplements/appendix.tex"))
        try writeFile("excluded build artifact",
                      at: dir.appendingPathComponent("paper.aux"))
        try writeFile("excluded log",
                      at: dir.appendingPathComponent("paper.log"))
        return dir
    }

    /// Build a typst-style fixture with figures and a supplement.
    private static func makeTypstFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("typst-paper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeFile("= Sample\n\n#image(\"figures/diagram.png\")\n",
                      at: dir.appendingPathComponent("paper.typ"))
        try writeFile("PNG-FAKE",
                      at: dir.appendingPathComponent("figures/diagram.png"))
        return dir
    }

    // MARK: - Build (dir)

    @Test func buildFromDirectoryProducesValidArchive() async throws {
        let blobRoot = Self.makeBlobRoot()
        defer { try? FileManager.default.removeItem(at: blobRoot) }
        let fixture = try Self.makeTexFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let builder = ManuscriptBundleBuilder(blobRootURL: blobRoot)
        let result = try await builder.buildFromDirectory(fixture)

        #expect(result.sha256.count == 64)
        #expect(result.archiveSize > 0)
        #expect(FileManager.default.fileExists(atPath: result.archiveURL.path))
        #expect(result.manifest.mainSource == "paper.tex")
        #expect(result.manifest.sourceFormat == .tex)
        #expect(result.manifest.compile.engine == .pdflatex)
    }

    @Test func buildExcludesAuxAndLog() async throws {
        let blobRoot = Self.makeBlobRoot()
        defer { try? FileManager.default.removeItem(at: blobRoot) }
        let fixture = try Self.makeTexFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let builder = ManuscriptBundleBuilder(blobRootURL: blobRoot)
        let result = try await builder.buildFromDirectory(fixture)

        let paths = Set(result.manifest.entries.map(\.path))
        #expect(paths.contains("paper.tex"))
        #expect(paths.contains("references.bib"))
        #expect(paths.contains("figures/fig1.png"))
        #expect(paths.contains("supplements/appendix.tex"))
        #expect(!paths.contains("paper.aux"))
        #expect(!paths.contains("paper.log"))
    }

    @Test func buildClassifiesRolesCorrectly() async throws {
        let blobRoot = Self.makeBlobRoot()
        defer { try? FileManager.default.removeItem(at: blobRoot) }
        let fixture = try Self.makeTexFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let builder = ManuscriptBundleBuilder(blobRootURL: blobRoot)
        let result = try await builder.buildFromDirectory(fixture)

        let byPath = Dictionary(uniqueKeysWithValues: result.manifest.entries.map { ($0.path, $0.role) })
        #expect(byPath["paper.tex"] == .main)
        #expect(byPath["references.bib"] == .bibliography)
        #expect(byPath["figures/fig1.png"] == .figure)
        #expect(byPath["supplements/appendix.tex"] == .supplement)
    }

    @Test func buildTypstFixtureSelectsTypstEngine() async throws {
        let blobRoot = Self.makeBlobRoot()
        defer { try? FileManager.default.removeItem(at: blobRoot) }
        let fixture = try Self.makeTypstFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let builder = ManuscriptBundleBuilder(blobRootURL: blobRoot)
        let result = try await builder.buildFromDirectory(fixture)

        #expect(result.manifest.mainSource == "paper.typ")
        #expect(result.manifest.sourceFormat == .typst)
        #expect(result.manifest.compile.engine == .typst)
    }

    @Test func buildIsDeterministicAcrossRuns() async throws {
        let blobRoot = Self.makeBlobRoot()
        defer { try? FileManager.default.removeItem(at: blobRoot) }
        let fixture = try Self.makeTexFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let builder = ManuscriptBundleBuilder(blobRootURL: blobRoot)
        let r1 = try await builder.buildFromDirectory(fixture)
        let r2 = try await builder.buildFromDirectory(fixture)
        #expect(r1.sha256 == r2.sha256)
    }

    // MARK: - Build (single file → 1-entry bundle)

    @Test func buildFromSingleFileProducesOneEntryBundle() async throws {
        let blobRoot = Self.makeBlobRoot()
        defer { try? FileManager.default.removeItem(at: blobRoot) }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("single-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mdFile = tempDir.appendingPathComponent("notes.md")
        try "# Hello\n\nbody".write(to: mdFile, atomically: true, encoding: .utf8)

        let builder = ManuscriptBundleBuilder(blobRootURL: blobRoot)
        let result = try await builder.buildFromSingleFile(mdFile)

        #expect(result.manifest.entries.count == 1)
        #expect(result.manifest.mainSource == "notes.md")
        #expect(result.manifest.sourceFormat == .markdown)
        #expect(result.manifest.compile.engine == .none)
    }

    // MARK: - Round-trip with reader

    @Test func roundTripBuildAndReadProducesSameContent() async throws {
        let blobRoot = Self.makeBlobRoot()
        defer { try? FileManager.default.removeItem(at: blobRoot) }
        let fixture = try Self.makeTexFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let builder = ManuscriptBundleBuilder(blobRootURL: blobRoot)
        let buildResult = try await builder.buildFromDirectory(fixture)

        let extractRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: extractRoot) }
        let reader = ManuscriptBundleReader(blobRootURL: blobRoot, extractionRoot: extractRoot)
        let readResult = try await reader.read(sha256: buildResult.sha256)

        // Manifest matches (modulo entry sort order, which canonical encoding pins).
        #expect(readResult.manifest.mainSource == buildResult.manifest.mainSource)
        #expect(Set(readResult.manifest.entries.map(\.path))
                == Set(buildResult.manifest.entries.map(\.path)))

        // paper.tex contents survived the round-trip.
        let paperURL = readResult.extractedURL.appendingPathComponent("paper.tex")
        let paperContent = try String(contentsOf: paperURL, encoding: .utf8)
        #expect(paperContent.contains("\\documentclass"))
    }

    @Test func readerCachesRepeatedReads() async throws {
        let blobRoot = Self.makeBlobRoot()
        defer { try? FileManager.default.removeItem(at: blobRoot) }
        let fixture = try Self.makeTexFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let builder = ManuscriptBundleBuilder(blobRootURL: blobRoot)
        let buildResult = try await builder.buildFromDirectory(fixture)

        let extractRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: extractRoot) }
        let reader = ManuscriptBundleReader(blobRootURL: blobRoot, extractionRoot: extractRoot)

        let r1 = try await reader.read(sha256: buildResult.sha256)
        let r2 = try await reader.read(sha256: buildResult.sha256)
        #expect(r1.extractedURL == r2.extractedURL)
    }

    @Test func readerEntryURLResolvesPaths() async throws {
        let blobRoot = Self.makeBlobRoot()
        defer { try? FileManager.default.removeItem(at: blobRoot) }
        let fixture = try Self.makeTexFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let builder = ManuscriptBundleBuilder(blobRootURL: blobRoot)
        let buildResult = try await builder.buildFromDirectory(fixture)

        let extractRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: extractRoot) }
        let reader = ManuscriptBundleReader(blobRootURL: blobRoot, extractionRoot: extractRoot)

        let figureURL = try await reader.entryURL(sha256: buildResult.sha256, path: "figures/fig1.png")
        #expect(figureURL != nil)

        let missingURL = try await reader.entryURL(sha256: buildResult.sha256, path: "nope.tex")
        #expect(missingURL == nil)
    }

    @Test func readerThrowsForMissingArchive() async {
        let blobRoot = Self.makeBlobRoot()
        defer { try? FileManager.default.removeItem(at: blobRoot) }
        let extractRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: extractRoot) }
        let reader = ManuscriptBundleReader(blobRootURL: blobRoot, extractionRoot: extractRoot)

        let fakeSha = String(repeating: "f", count: 64)
        do {
            _ = try await reader.read(sha256: fakeSha)
            Issue.record("expected archiveNotFound")
        } catch BundleReaderError.archiveNotFound {
            // pass
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Negative paths

    @Test func buildRejectsMissingDirectory() async {
        let blobRoot = Self.makeBlobRoot()
        defer { try? FileManager.default.removeItem(at: blobRoot) }
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID())")
        let builder = ManuscriptBundleBuilder(blobRootURL: blobRoot)
        do {
            _ = try await builder.buildFromDirectory(bogus)
            Issue.record("expected directoryNotFound")
        } catch BundleBuilderError.directoryNotFound {
            // pass
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func buildRejectsAmbiguousMainSource() async throws {
        let blobRoot = Self.makeBlobRoot()
        defer { try? FileManager.default.removeItem(at: blobRoot) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two .tex files at root, neither named canonically.
        try "doc1".write(to: dir.appendingPathComponent("foo.tex"), atomically: true, encoding: .utf8)
        try "doc2".write(to: dir.appendingPathComponent("bar.tex"), atomically: true, encoding: .utf8)

        let builder = ManuscriptBundleBuilder(blobRootURL: blobRoot)
        do {
            _ = try await builder.buildFromDirectory(dir)
            Issue.record("expected ambiguousMainSource")
        } catch BundleBuilderError.ambiguousMainSource {
            // pass
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Glob matching unit tests

    @Test func excludeGlobsMatchBasenames() {
        #expect(ManuscriptBundleBuilder.shouldExclude(relativePath: "paper.aux", globs: ["*.aux"]))
        #expect(!ManuscriptBundleBuilder.shouldExclude(relativePath: "paper.tex", globs: ["*.aux"]))
    }

    @Test func excludeGlobsMatchAnyComponent() {
        #expect(ManuscriptBundleBuilder.shouldExclude(
            relativePath: ".git/config",
            globs: [".git"]
        ))
        #expect(ManuscriptBundleBuilder.shouldExclude(
            relativePath: "node_modules/foo/index.js",
            globs: ["node_modules"]
        ))
    }

    @Test func excludeGlobsHandleStarPatterns() {
        #expect(ManuscriptBundleBuilder.shouldExclude(
            relativePath: "_minted-paper/foo.css",
            globs: ["_minted-*"]
        ))
    }

    // MARK: - Role classifier unit tests

    @Test func roleForPathClassifiesByLocation() {
        #expect(ManuscriptBundleBuilder.roleForPath("figures/x.png") == .figure)
        #expect(ManuscriptBundleBuilder.roleForPath("supplements/info.tex") == .supplement)
        #expect(ManuscriptBundleBuilder.roleForPath("chapters/c1.tex") == .chapter)
    }

    @Test func roleForPathClassifiesByExtension() {
        #expect(ManuscriptBundleBuilder.roleForPath("refs.bib") == .bibliography)
        #expect(ManuscriptBundleBuilder.roleForPath("compiled.bbl") == .bibliography)
        #expect(ManuscriptBundleBuilder.roleForPath("img.svg") == .figure)
        #expect(ManuscriptBundleBuilder.roleForPath("acmart.cls") == .aux)
    }
}
