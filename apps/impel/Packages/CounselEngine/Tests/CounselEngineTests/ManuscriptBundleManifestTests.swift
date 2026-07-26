//
//  ManuscriptBundleManifestTests.swift
//  CounselEngineTests
//
//  Phase 8.2 tests for the Swift mirror of the Rust BundleManifest. Verifies
//  parse/validate symmetry with the Rust side, deterministic canonical
//  encoding, and the same negative cases the Rust tests cover.
//

import Foundation
import Testing
@testable import CounselEngine

@Suite(.serialized)
struct ManuscriptBundleManifestTests {

    static func sampleManifest() -> ManuscriptBundleManifest {
        ManuscriptBundleManifest(
            mainSource: "paper.tex",
            sourceFormat: .tex,
            entries: [
                BundleEntry(path: "paper.tex", role: .main),
                BundleEntry(path: "references.bib", role: .bibliography),
                BundleEntry(path: "figures/fig1.pdf", role: .figure),
            ],
            compile: BundleCompileSpec(engine: .pdflatex),
            excludeGlobs: ["*.aux", "*.log"]
        )
    }

    // MARK: - Round-trip

    @Test func roundTripPreservesStructure() throws {
        let m = Self.sampleManifest()
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ManuscriptBundleManifest.self, from: data)
        #expect(back == m)
    }

    @Test func parseAcceptsCanonicalEncoding() throws {
        let m = Self.sampleManifest()
        let json = try m.canonicalJSON()
        let parsed = try ManuscriptBundleManifest.parse(json)
        #expect(parsed.mainSource == m.mainSource)
        #expect(parsed.entries.count == m.entries.count)
    }

    // MARK: - Cross-language compat (matches Rust BundleManifest serde shape)

    @Test func decodesRustSerdeShape() throws {
        let json = """
        {
            "schema": "manuscript-bundle-manifest@1.0.0",
            "main_source": "paper.typ",
            "source_format": "typst",
            "entries": [
                {"path": "paper.typ", "role": "main"},
                {"path": "figures/diagram.png", "role": "figure"}
            ],
            "compile": {
                "engine": "typst",
                "extra_args": []
            },
            "exclude_globs": [".DS_Store"]
        }
        """
        let parsed = try ManuscriptBundleManifest.parse(json)
        #expect(parsed.mainSource == "paper.typ")
        #expect(parsed.sourceFormat == .typst)
        #expect(parsed.compile.engine == .typst)
        #expect(parsed.entries.count == 2)
    }

    @Test func decodesWithoutExcludeGlobsField() throws {
        let json = """
        {
            "schema": "manuscript-bundle-manifest@1.0.0",
            "main_source": "x.md",
            "source_format": "markdown",
            "entries": [{"path": "x.md", "role": "main"}],
            "compile": {"engine": "none", "extra_args": []}
        }
        """
        let parsed = try ManuscriptBundleManifest.parse(json)
        #expect(parsed.excludeGlobs.isEmpty)
    }

    // MARK: - Validation negatives

    @Test func validateRejectsSchemaMismatch() {
        let m = ManuscriptBundleManifest(
            schema: "manuscript-bundle-manifest@2.0.0",
            mainSource: "x.tex",
            sourceFormat: .tex,
            entries: [BundleEntry(path: "x.tex", role: .main)],
            compile: BundleCompileSpec(engine: .pdflatex)
        )
        do {
            try m.validate()
            Issue.record("expected schemaMismatch")
        } catch BundleManifestError.schemaMismatch {
            // pass
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func validateRejectsEmptyMainSource() {
        let m = ManuscriptBundleManifest(
            mainSource: "",
            sourceFormat: .tex,
            entries: [BundleEntry(path: "x.tex", role: .main)],
            compile: BundleCompileSpec(engine: .pdflatex)
        )
        do {
            try m.validate()
            Issue.record("expected emptyMainSource")
        } catch BundleManifestError.emptyMainSource {
            // pass
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func validateRejectsMainSourceNotInEntries() {
        let m = ManuscriptBundleManifest(
            mainSource: "missing.tex",
            sourceFormat: .tex,
            entries: [BundleEntry(path: "x.tex", role: .main)],
            compile: BundleCompileSpec(engine: .pdflatex)
        )
        do {
            try m.validate()
            Issue.record("expected mainSourceNotInEntries")
        } catch BundleManifestError.mainSourceNotInEntries(let path) {
            #expect(path == "missing.tex")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func validateRejectsAbsolutePath() {
        let m = ManuscriptBundleManifest(
            mainSource: "x.tex",
            sourceFormat: .tex,
            entries: [
                BundleEntry(path: "x.tex", role: .main),
                BundleEntry(path: "/etc/passwd", role: .aux),
            ],
            compile: BundleCompileSpec(engine: .pdflatex)
        )
        do {
            try m.validate()
            Issue.record("expected unsafePath")
        } catch BundleManifestError.unsafePath(let path) {
            #expect(path == "/etc/passwd")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func validateRejectsParentTraversal() {
        let m = ManuscriptBundleManifest(
            mainSource: "x.tex",
            sourceFormat: .tex,
            entries: [
                BundleEntry(path: "x.tex", role: .main),
                BundleEntry(path: "../escape.tex", role: .aux),
            ],
            compile: BundleCompileSpec(engine: .pdflatex)
        )
        do {
            try m.validate()
            Issue.record("expected unsafePath")
        } catch BundleManifestError.unsafePath {
            // pass
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func parseRejectsMalformedJSON() {
        do {
            _ = try ManuscriptBundleManifest.parse("{not json")
            Issue.record("expected parseError")
        } catch BundleManifestError.parseError {
            // pass
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Determinism

    @Test func canonicalJSONSortsEntries() throws {
        let m = ManuscriptBundleManifest(
            mainSource: "paper.tex",
            sourceFormat: .tex,
            entries: [
                BundleEntry(path: "z.tex", role: .aux),
                BundleEntry(path: "paper.tex", role: .main),
                BundleEntry(path: "a.tex", role: .aux),
            ],
            compile: BundleCompileSpec(engine: .pdflatex)
        )
        let json = try m.canonicalJSONString()
        // The first entry's path appears before the second; verify by
        // string positions (sortedKeys + sortedEntries makes this stable).
        let posA = json.range(of: "\"a.tex\"")!.lowerBound
        let posPaper = json.range(of: "\"paper.tex\"")!.lowerBound
        let posZ = json.range(of: "\"z.tex\"")!.lowerBound
        #expect(posA < posPaper)
        #expect(posPaper < posZ)
    }

    @Test func canonicalJSONIsDeterministic() throws {
        let m = Self.sampleManifest()
        let a = try m.canonicalJSON()
        let b = try m.canonicalJSON()
        #expect(a == b)
    }

    @Test func roleSerializesAsLowercase() throws {
        let entry = BundleEntry(path: "x.tex", role: .bibliography)
        let data = try JSONEncoder().encode(entry)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"bibliography\""))
    }

    @Test func engineSerializesAsLowercase() throws {
        let spec = BundleCompileSpec(engine: .pdflatex)
        let data = try JSONEncoder().encode(spec)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"pdflatex\""))
    }
}
