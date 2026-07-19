import SwiftUI
import Foundation
import OSLog
import ImprintCore
import ImpressLogging

/// Inputs a compile needs, snapshotted from the view at call time.
///
/// Passing an explicit value type (rather than letting the view model read
/// `@State`/`@AppStorage`/`@Binding` directly) keeps the compile pipeline pure:
/// no hidden reads of live SwiftUI storage, so there are no feedback loops
/// between "compile mutated state" and "state change triggered a compile".
/// (See CLAUDE.md: "Capture @State Before Async Work".)
struct CompileInputs {
    let source: String
    let format: DocumentFormat
    let previewFormat: String
    let documentID: UUID
    let documentTitle: String
    let latexEngine: String
    let latexShellEscape: Bool
    let latexShowBoxWarnings: Bool
}

/// Owns the compile/preview output state and the compile orchestration for one
/// imprint document editor session.
///
/// Extracted from the former monolithic `ContentView` so the compile pipeline
/// is (a) declaratively observable by the view, (b) driven by explicit inputs,
/// and (c) timed by `PerfMetrics` so the Console Performance tab shows live
/// editor-compile latency. The view retains only view-coupled concerns
/// (cursor/SyncTeX, scheduling/debounce, export/print, PDF scrolling); this
/// type retains only "given source + settings, produce a preview".
@MainActor
@Observable
final class ImprintDocumentViewModel {

    // MARK: - Compile output (observed by the view)

    var pdfData: Data?
    var sourceMapEntries: [SourceMapEntry] = []
    var isCompiling = false
    var compilationError: String?
    var compilationWarnings: [String] = []

    /// SVG preview pages (Typst SVG preview mode).
    var svgPages: [String] = []

    // LaTeX-specific output
    var latexDiagnostics: [LaTeXDiagnostic] = []
    var latexCompilationTimeMs: Int = 0
    var latexProjectFiles: [URL] = []
    var latexMainFileURL: URL?

    // Debug breadcrumb state (surfaced in DEBUG toolbar items).
    var debugStatus: String = "idle"
    var debugHistory: String = ""

    // MARK: - Owned services

    /// Shared Typst renderer instance for this editor session.
    private let renderer = TypstRenderer()

    /// Post-compile follow-up work (SyncTeX load, dependency scan). Cancelled
    /// and replaced on each successful LaTeX compile.
    private var postCompileTask: Task<Void, Never>?

    // MARK: - Entry point

    /// Compile `inputs.source` and publish the result into this view model's
    /// observable state. Branches on document format. Timed under the
    /// `compile` PerfMetrics bucket so budget breaches surface in the Console.
    func compile(_ inputs: CompileInputs) async {
        let sourceLen = inputs.source.count
        Logger.compilation.infoCapture(
            "Compile started: format=\(inputs.format), source=\(sourceLen)ch",
            category: "compile"
        )
        log("compile() started")
        debugHistory = ""
        debugStatus = "1:started"
        debugHistory += "1 "
        isCompiling = true
        compilationError = nil
        compilationWarnings = []
        latexDiagnostics = []

        await PerfMetrics.shared.measureAsync(
            PerfBucket.compile,
            detail: "editor-\(inputs.format)"
        ) {
            switch inputs.format {
            case .typst:
                await compileTypst(inputs)
            case .latex:
                await compileLaTeX(inputs)
            }
        }

        isCompiling = false
        debugStatus = "F:pdf=\(pdfData?.count ?? 0)"
        debugHistory += "F:\(pdfData?.count ?? 0)"
        Logger.compilation.infoCapture(
            "Compile finished: pdf=\(pdfData?.count ?? 0)b, errors=\(compilationError != nil ? 1 : 0)",
            category: "compile"
        )
        log("compile() finished")
    }

    private func log(_ message: String) {
        Logger.compilation.infoCapture(message, category: "compile")
    }

    // MARK: - Typst Compilation

    private func compileTypst(_ inputs: CompileInputs) async {
        let sourceText = inputs.source
        let format = inputs.previewFormat
        debugStatus = "2:src=\(sourceText.count)ch"
        debugHistory += "2:\(sourceText.count) "
        log("Source text length: \(sourceText.count), format: \(format)")

        do {
            log("Creating RenderOptions")
            debugStatus = "3:options"
            debugHistory += "3 "
            let options = RenderOptions(
                pageSize: .a4,
                isDraft: false
            )

            if format == "svg" {
                debugStatus = "4:rendering(svg)"
                debugHistory += "4svg "
                log("Calling renderer.renderSVG()")
                let output = try await renderer.renderSVG(sourceText, options: options)
                debugStatus = "5:done,ok=\(output.isSuccess),pages=\(output.svgPages.count)"
                debugHistory += "5:\(output.svgPages.count)p "

                if output.isSuccess {
                    svgPages = output.svgPages
                    sourceMapEntries = output.sourceMapEntries
                    compilationWarnings = output.warnings

                    let pdfOutput = try await renderer.render(sourceText, options: options)
                    if pdfOutput.isSuccess {
                        pdfData = pdfOutput.pdfData
                        DocumentRegistry.shared.cachePDF(pdfOutput.pdfData, for: inputs.documentID)
                    }

                    debugStatus = "6:set,\(output.svgPages.count)p,map=\(output.sourceMapEntries.count)"
                    debugHistory += "6:ok "
                } else {
                    compilationError = output.errors.joined(separator: "\n")
                    debugHistory += "E "
                }
            } else {
                debugStatus = "4:rendering(pdf)"
                debugHistory += "4pdf "
                let output = try await renderer.render(sourceText, options: options)
                debugStatus = "5:done,ok=\(output.isSuccess),sz=\(output.pdfData.count)"
                debugHistory += "5:\(output.pdfData.count) "

                if output.isSuccess {
                    pdfData = output.pdfData
                    sourceMapEntries = output.sourceMapEntries
                    compilationWarnings = output.warnings
                    DocumentRegistry.shared.cachePDF(output.pdfData, for: inputs.documentID)
                    debugStatus = "6:set,\(output.pdfData.count)b,map=\(output.sourceMapEntries.count)"
                    debugHistory += "6:ok "
                } else {
                    compilationError = output.errors.joined(separator: "\n")
                    debugHistory += "E "
                }
            }
        } catch {
            compilationError = error.localizedDescription
            debugHistory += "X:\(error) "
        }
    }

    // MARK: - LaTeX Compilation

    private func compileLaTeX(_ inputs: CompileInputs) async {
        #if !os(macOS)
        // LaTeX compilation spawns a local TeX distribution via Process —
        // desktop-only. Typst is the cross-platform path.
        compilationError = "LaTeX compilation is only available on macOS. Use Typst format on this device."
        #else
        // LaTeX requires a file URL — the document must be saved to disk first.
        // For unsaved documents, write to a temp directory.
        let sourceText = inputs.source
        debugStatus = "2:latex,src=\(sourceText.count)ch"
        debugHistory += "2:\(sourceText.count) "

        // Resolve the engine
        let engineRaw = inputs.latexEngine
        let engine = LaTeXEngine(rawValue: engineRaw) ?? .pdflatex

        // Get or create a temp file URL for compilation
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imprint-latex-\(inputs.documentID.uuidString)")
        let sourceURL = tempDir.appendingPathComponent("main.tex")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try sourceText.data(using: .utf8)?.write(to: sourceURL)

            // Mirror the per-document Veusz figures dir into the compile
            // tempdir so `\includegraphics{figures/foo.pdf}` resolves.
            // The plot store renders into
            //   <container>/Application Support/imprint/manuscripts/<docID>/figures/
            // but pdfLaTeX runs with `tempDir/` as cwd and only sees what's
            // under it. We re-build figures/ on every compile so deletes
            // + renames in the plot panel land here too. Best-effort: a
            // copy failure shouldn't block the compile, only log it.
            let figuresSrc = try? VeuszWorkingDirectory().figuresDirectory(forDocumentID: inputs.documentID)
            let figuresDst = tempDir.appendingPathComponent("figures")
            try? FileManager.default.removeItem(at: figuresDst)
            if let figuresSrc, FileManager.default.fileExists(atPath: figuresSrc.path) {
                do {
                    try FileManager.default.copyItem(at: figuresSrc, to: figuresDst)
                    Logger.documents.infoCapture("Mirrored figures/ from plot store into compile tempdir", category: "compile")
                } catch {
                    Logger.documents.warningCapture("Failed to mirror figures/ for compile: \(error.localizedDescription)", category: "compile")
                }
            }
        } catch {
            compilationError = "Failed to write temp file: \(error.localizedDescription)"
            debugHistory += "X:write "
            return
        }

        debugStatus = "3:engine=\(engine.rawValue)"
        debugHistory += "3:\(engine.rawValue) "

        let options = LaTeXCompileOptions(
            engine: engine,
            shellEscape: inputs.latexShellEscape
        )

        do {
            let result = try await LaTeXCompilationService.shared.compile(
                sourceURL: sourceURL,
                engine: engine,
                options: options
            )

            latexCompilationTimeMs = result.compilationTimeMs
            latexDiagnostics = result.errors + result.warnings
            DocumentRegistry.shared.cachedDiagnostics[inputs.documentID] = latexDiagnostics

            if result.isSuccess, let data = result.pdfData {
                pdfData = data
                sourceMapEntries = []
                DocumentRegistry.shared.cachePDF(data, for: inputs.documentID)

                // Cancel previous post-compile tasks before starting new ones
                postCompileTask?.cancel()
                let capturedSynctexURL = result.synctexURL
                let capturedSourceURL = sourceURL
                postCompileTask = Task {
                    // Load SyncTeX data for bidirectional sync
                    if let synctexURL = capturedSynctexURL {
                        do {
                            try await SyncTeXService.shared.load(from: synctexURL)
                        } catch {
                            self.log("SyncTeX load failed: \(error)")
                        }
                    }

                    guard !Task.isCancelled else { return }

                    // Scan project dependencies for sidebar
                    await LaTeXProjectService.shared.scanDependencies(from: capturedSourceURL)
                    let files = await LaTeXProjectService.shared.allProjectFiles
                    let mainFile = await LaTeXProjectService.shared.mainFile
                    await MainActor.run {
                        self.latexProjectFiles = files
                        self.latexMainFileURL = mainFile
                    }
                }
                debugStatus = "5:ok,\(data.count)b,\(result.compilationTimeMs)ms"
                debugHistory += "5:ok "
            } else {
                compilationError = result.errors.map(\.message).joined(separator: "\n")
                if compilationError?.isEmpty ?? true {
                    compilationError = "Compilation failed (exit code \(result.exitCode))"
                }
                // Log first 500 chars of compilation output for debugging
                let logSnippet = String(result.logOutput.prefix(500))
                Logger.compilation.errorCapture("LaTeX failed (exit \(result.exitCode)): errors=\(result.errors.map(\.message)), log=\(logSnippet)", category: "latex")
                debugHistory += "E "
            }

            // Surface warnings (filter box warnings if disabled)
            let showBoxWarnings = inputs.latexShowBoxWarnings
            compilationWarnings = result.warnings
                .filter { diag in
                    if !showBoxWarnings && (diag.message.hasPrefix("Overfull") || diag.message.hasPrefix("Underfull")) {
                        return false
                    }
                    return true
                }
                .map { "\($0.file):\($0.line): \($0.message)" }

        } catch {
            compilationError = error.localizedDescription
            Logger.compilation.errorCapture("LaTeX compile threw: \(error)", category: "latex")
            debugHistory += "X:\(error) "
        }
        #endif // os(macOS)
    }
}
