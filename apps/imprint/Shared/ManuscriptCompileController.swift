import SwiftUI
import Foundation
import OSLog
import ImprintCore
import ImpressLogging

/// Inputs a compile needs, snapshotted from the view at call time.
///
/// Passing an explicit value type (rather than letting the controller read
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

/// The compile core for one imprint manuscript editor session.
///
/// GUI-meld Phase 3 PREP: extracted out of `ImprintDocumentViewModel` so the
/// compile pipeline is a self-contained, capability-injected unit that can
/// later move to the shared GUI package as-is. It owns:
///
/// - the compile/preview **output state** (PDF, SVG, source map, diagnostics),
/// - the **orchestration** (branch on format, Typst via the in-process renderer,
///   LaTeX via the injected `LaTeXCompiling` capability),
/// - the **auto-compile debounce mechanism** (timing policy + task lifetime).
///
/// It deliberately holds no document/editor state and no platform conditionals
/// in its decision logic — LaTeX platform specifics live behind
/// `LaTeXCompiling`. The owning view model exposes this controller's state and
/// methods unchanged, so call sites compile and read output exactly as before.
@MainActor
@Observable
final class ManuscriptCompileController {

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

    /// Platform capability that performs LaTeX compilation (macOS: real TeX;
    /// iOS/absent: unsupported). Injected at composition time.
    private let latexCompiler: LaTeXCompiling

    /// Post-compile follow-up work (SyncTeX load, dependency scan). Cancelled
    /// and replaced on each successful LaTeX compile.
    private var postCompileTask: Task<Void, Never>?

    /// Debounced auto-compile task. Owned here so the debounce *policy* travels
    /// with the compile core; the view supplies only the fire-time work.
    private var autoCompileTask: Task<Void, Never>?

    init(latexCompiler: LaTeXCompiling) {
        self.latexCompiler = latexCompiler
    }

    // MARK: - Auto-compile debounce

    /// Schedule `work` to run after `delayMs` of quiet, cancelling any
    /// previously scheduled compile. The view computes enablement/guards and
    /// passes the fire-time closure (which re-reads live view state and may
    /// bail); this type owns only the timing + task lifetime.
    func scheduleCompile(after delayMs: Int, _ work: @escaping @MainActor () async -> Void) {
        autoCompileTask?.cancel()
        autoCompileTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    /// Cancel a pending debounced compile (e.g. while a citation palette is open).
    func cancelScheduledCompile() {
        autoCompileTask?.cancel()
    }

    // MARK: - Entry point

    /// Compile `inputs.source` and publish the result into this controller's
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

    /// LaTeX compile via the injected capability. All platform specifics (temp
    /// file, Veusz figure mirror, engine selection, SyncTeX, dependency scan)
    /// live inside the `LaTeXCompiling` implementation; this method only maps the
    /// capability's result onto the published state — the same three publish
    /// paths (success / engine-failure / preflight-failure) that used to be
    /// inline here, now selected by `outcome` instead of by `#if os(macOS)`.
    private func compileLaTeX(_ inputs: CompileInputs) async {
        debugStatus = "2:latex,src=\(inputs.source.count)ch"
        debugHistory += "2:\(inputs.source.count) "

        let request = LaTeXCompileRequest(
            source: inputs.source,
            documentID: inputs.documentID,
            engineRaw: inputs.latexEngine,
            shellEscape: inputs.latexShellEscape,
            showBoxWarnings: inputs.latexShowBoxWarnings
        )
        debugStatus = "3:engine=\(inputs.latexEngine)"
        debugHistory += "3:\(inputs.latexEngine) "

        let result = await latexCompiler.compile(request)

        switch result.outcome {
        case .succeeded:
            latexCompilationTimeMs = result.compilationTimeMs
            latexDiagnostics = result.diagnostics
            DocumentRegistry.shared.cachedDiagnostics[inputs.documentID] = latexDiagnostics
            compilationWarnings = result.formattedWarnings

            if let data = result.pdfData {
                pdfData = data
                sourceMapEntries = []
                DocumentRegistry.shared.cachePDF(data, for: inputs.documentID)

                // Post-compile follow-up (SyncTeX load + dependency scan) runs
                // off the critical path and stays cancellable — replaced on
                // every successful compile.
                postCompileTask?.cancel()
                let compiler = latexCompiler
                let synctexURL = result.synctexURL
                let sourceURL = result.sourceURL
                postCompileTask = Task { [weak self] in
                    let post = await compiler.loadPostCompile(synctexURL: synctexURL, sourceURL: sourceURL)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self?.latexProjectFiles = post.projectFiles
                        self?.latexMainFileURL = post.mainFileURL
                    }
                }
            }
            debugStatus = "5:ok,\(result.pdfData?.count ?? 0)b,\(result.compilationTimeMs)ms"
            debugHistory += "5:ok "

        case .engineFailed:
            latexCompilationTimeMs = result.compilationTimeMs
            latexDiagnostics = result.diagnostics
            DocumentRegistry.shared.cachedDiagnostics[inputs.documentID] = latexDiagnostics
            compilationWarnings = result.formattedWarnings
            compilationError = result.errorMessage
            debugHistory += "E "

        case .preflightFailed:
            // Temp-file write failed, the call threw, or LaTeX is unsupported on
            // this platform: only surface the error, leaving prior diagnostics /
            // warnings / timing untouched (matches the pre-extraction behavior).
            compilationError = result.errorMessage
            debugHistory += "X:\(result.errorMessage ?? "preflight") "
        }
    }
}
