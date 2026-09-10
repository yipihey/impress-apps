//
//  TreeRender.swift
//  ImprintCore
//
//  Typst over a project tree, from memory (ADR-0030 D5). The Swift face of
//  `imprint_core::project::typst`: the app hands over every file it holds
//  for the manuscript — the store's rows plus the live buffer — and gets
//  back the PDF or per-page SVGs with diagnostics that name the FILE a span
//  points into. No directory is written; iOS and macOS take the same path.
//

import Foundation
import ImprintRustCore

/// One file of the tree as the compiler should see it: text or bytes.
public struct TreeRenderFile: Sendable, Hashable {
    public let path: String
    /// chapter | bibliography | figure | figure-source | data | style | aux | supplement | output | main
    public let role: String
    public let text: String?
    public let bytes: Data?
    /// `{runner, outputs, inputs, args}` for a figure source, when declared.
    public let buildJSON: String?
    /// Provenance of an output row (staleness derives from these).
    public let derivedFrom: String?
    public let derivedFromHash: String?

    public init(
        path: String, role: String, text: String,
        buildJSON: String? = nil, derivedFrom: String? = nil, derivedFromHash: String? = nil
    ) {
        self.path = path
        self.role = role
        self.text = text
        self.bytes = nil
        self.buildJSON = buildJSON
        self.derivedFrom = derivedFrom
        self.derivedFromHash = derivedFromHash
    }

    public init(
        path: String, role: String, bytes: Data,
        buildJSON: String? = nil, derivedFrom: String? = nil, derivedFromHash: String? = nil
    ) {
        self.path = path
        self.role = role
        self.text = nil
        self.bytes = bytes
        self.buildJSON = buildJSON
        self.derivedFrom = derivedFrom
        self.derivedFromHash = derivedFromHash
    }

    var ffi: ImprintRustCore.FfiProjectFile {
        ImprintRustCore.FfiProjectFile(
            path: path, role: role, text: text, bytes: bytes,
            buildJson: buildJSON, derivedFrom: derivedFrom, derivedFromHash: derivedFromHash)
    }
}

/// A bibliography row's effective text (a projection the app resolved).
public struct TreeRenderBibliography: Sendable, Hashable {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

/// A diagnostic in tree paths.
public struct TreeRenderDiagnostic: Sendable, Hashable, Identifiable {
    public enum Severity: String, Sendable {
        case error, warning, info
    }
    public let severity: Severity
    public let code: String
    public let message: String
    public let file: String?
    public let line: Int?

    public var id: String { "\(severity.rawValue)|\(code)|\(file ?? "")|\(line ?? 0)|\(message)" }

    init(ffi: ImprintRustCore.FfiProjectDiagnostic) {
        severity = Severity(rawValue: ffi.severity) ?? .error
        code = ffi.code
        message = ffi.message
        file = ffi.file
        line = ffi.line.map(Int.init)
    }
}

/// What a tree compile produced.
public struct TreeRenderOutput: Sendable {
    public let isSuccess: Bool
    public let pdfData: Data?
    public let svgPages: [String]
    public let pageCount: Int
    public let compileMs: Int
    public let diagnostics: [TreeRenderDiagnostic]

    public var errors: [String] {
        diagnostics.filter { $0.severity == .error }.map(\.summaryLine)
    }
}

extension TreeRenderDiagnostic {
    /// `file:line: message` — what a log line or an error card shows.
    public var summaryLine: String {
        var s = ""
        if let file { s += file }
        if let line { s += ":\(line)" }
        if !s.isEmpty { s += ": " }
        return s + message
    }
}

extension TypstRenderer {
    /// Compile a project tree from memory. `entryOverride` replaces the
    /// entry's text (the live buffer); `output` is `"svg"` or `"pdf"`. Runs
    /// off-main like the single-source renderer; the Rust engine is per
    /// thread and persistent.
    public func renderTree(
        files: [TreeRenderFile],
        entryPath: String,
        entryOverride: String?,
        output: String,
        bibliographies: [TreeRenderBibliography] = []
    ) async -> TreeRenderOutput {
        let ffiFiles = files.map(\.ffi)
        let ffiBibs = bibliographies.map {
            ImprintRustCore.FfiProjectBibliography(path: $0.path, text: $0.text)
        }
        let result = await Task.detached(priority: .userInitiated) {
            ImprintRustCore.compileTypstTreeToOutput(
                files: ffiFiles,
                entryPath: entryPath,
                entryOverride: entryOverride,
                output: output,
                bibliographies: ffiBibs)
        }.value
        return TreeRenderOutput(
            isSuccess: result.ok,
            pdfData: result.pdfData,
            svgPages: result.svgPages,
            pageCount: Int(result.pageCount),
            compileMs: Int(result.compileMs),
            diagnostics: result.diagnostics.map(TreeRenderDiagnostic.init(ffi:)))
    }
}

/// The derived build graph of a tree the app holds, as JSON — the same shape
/// `imprint-project-service_project-graph` returns (edges, unresolved,
/// steps, reachable, unreferenced, diagnostics). Pure; safe on any thread.
public func projectGraphJSON(files: [TreeRenderFile], entryPath: String, format: String) -> String {
    ImprintRustCore.projectGraphJson(files: files.map(\.ffi), entryPath: entryPath, format: format)
}

/// A directory read as a tree — nothing written (ADR-0030 P3). The plan is
/// Rust's: build residue skipped, roles from the extension and then from
/// use, the entry guessed with its reason (`entryOverride` wins).
public struct ImportedTreePlan: Sendable {
    public let ok: Bool
    public let entryPath: String
    public let entryReason: String
    /// typst | latex | markdown | plaintext
    public let format: String
    /// Every file, the entry included (its role is `main`).
    public let files: [TreeRenderFile]
    /// `path: why` for what the walk left out.
    public let skipped: [String]
    public let message: String

    public var entry: TreeRenderFile? { files.first { $0.path == entryPath } }
}

public func importDirectoryPlan(at url: URL, entryOverride: String? = nil) -> ImportedTreePlan {
    let r = ImprintRustCore.projectImportDirectoryPlan(directory: url.path, entryOverride: entryOverride)
    return ImportedTreePlan(
        ok: r.ok,
        entryPath: r.entryPath,
        entryReason: r.entryReason,
        format: r.format,
        files: r.files.map { f in
            if let text = f.text {
                return TreeRenderFile(path: f.path, role: f.role, text: text)
            }
            return TreeRenderFile(path: f.path, role: f.role, bytes: f.bytes ?? Data())
        },
        skipped: r.skipped,
        message: r.message)
}

// MARK: - Builds (ADR-0030 P4)

/// One file a build wrote into its work directory.
public struct TreeBuildOutput: Sendable, Hashable, Identifiable {
    /// pdf | svg | synctex | log
    public let kind: String
    public let name: String
    public let path: String
    public let size: UInt64
    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
}

/// What happened to one figure step.
public struct TreeStepReport: Sendable, Hashable, Identifiable {
    public enum Status: String, Sendable {
        case ran, fresh, skipped, failed
    }
    public let source: String
    public let runner: String
    public let status: Status
    public let message: String
    public let durationMs: UInt64
    public let outputs: [String]
    public let command: String?
    public var id: String { source }
}

/// A file a figure step wrote, with the provenance its row should carry.
public struct TreeProducedFile: Sendable {
    public let path: String
    public let bytes: Data
    public let derivedFrom: String
    public let derivedFromHash: String
}

/// The report of one build.
public struct TreeBuildReport: Sendable {
    public let isSuccess: Bool
    public let engine: String
    public let message: String
    public let outputs: [TreeBuildOutput]
    public let pdfData: Data?
    public let svgPages: [String]
    public let diagnostics: [TreeRenderDiagnostic]
    public let steps: [TreeStepReport]
    public let produced: [TreeProducedFile]
    public let log: String
    public let durationMs: UInt64

    public var pdfOutput: TreeBuildOutput? { outputs.first { $0.kind == "pdf" } }
    public var errors: [String] { diagnostics.filter { $0.severity == .error }.map(\.summaryLine) }

    init(ffi r: ImprintRustCore.FfiBuildReport) {
        isSuccess = r.ok
        engine = r.engine
        message = r.message
        outputs = r.outputs.map { TreeBuildOutput(kind: $0.kind, name: $0.name, path: $0.path, size: $0.size) }
        pdfData = r.pdfData
        svgPages = r.svgPages
        diagnostics = r.diagnostics.map(TreeRenderDiagnostic.init(ffi:))
        steps = r.steps.map {
            TreeStepReport(
                source: $0.source, runner: $0.runner,
                status: TreeStepReport.Status(rawValue: $0.status) ?? .failed,
                message: $0.message, durationMs: $0.durationMs, outputs: $0.outputs, command: $0.command)
        }
        produced = r.produced.map {
            TreeProducedFile(path: $0.path, bytes: $0.bytes, derivedFrom: $0.derivedFrom, derivedFromHash: $0.derivedFromHash)
        }
        log = r.log
        durationMs = r.durationMs
    }
}

extension TypstRenderer {
    /// Build one target of a tree the app holds: stale figure steps first
    /// (`shell` only with `allowShell`), then the document engine — Typst
    /// from memory, Markdown through Typst, LaTeX through `workDir` and
    /// the system's TeX. Runs off-main; the caller records the row and
    /// the produced files through the store.
    public func buildTree(
        files: [TreeRenderFile],
        entryPath: String,
        format: String,
        targetsJSON: String?,
        targetID: String?,
        workDir: URL,
        allowShell: Bool,
        entryOverride: String?,
        bibliographies: [TreeRenderBibliography] = []
    ) async -> TreeBuildReport {
        let ffiFiles = files.map(\.ffi)
        let ffiBibs = bibliographies.map {
            ImprintRustCore.FfiProjectBibliography(path: $0.path, text: $0.text)
        }
        let dir = workDir.path
        let result = await Task.detached(priority: .userInitiated) {
            ImprintRustCore.projectBuildTree(
                files: ffiFiles,
                entryPath: entryPath,
                format: format,
                targetsJson: targetsJSON,
                targetId: targetID,
                workDir: dir,
                allowShell: allowShell,
                entryOverride: entryOverride,
                bibliographies: ffiBibs)
        }.value
        return TreeBuildReport(ffi: result)
    }
}

/// Markdown → Typst markup (ADR-0030 D10), what the build engine compiles.
public func markdownToTypst(_ markdown: String) -> String {
    ImprintRustCore.markdownToTypst(markdown: markdown)
}
