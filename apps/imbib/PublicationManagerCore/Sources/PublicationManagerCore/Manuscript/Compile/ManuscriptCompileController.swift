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
public struct CompileInputs: Sendable {
    public let source: String
    public let format: DocumentFormat
    public let previewFormat: String
    public let documentID: UUID
    public let documentTitle: String
    public let latexEngine: String
    public let latexShellEscape: Bool
    public let latexShowBoxWarnings: Bool
    /// Per-manuscript app-group dir for on-disk figure assets:
    /// `image("figures/plot.png")` in the source resolves under it. nil → no
    /// filesystem figure resolution (Typst path only; LaTeX has its own mirror).
    public let figuresRoot: String?

    public init(
        source: String,
        format: DocumentFormat,
        previewFormat: String,
        documentID: UUID,
        documentTitle: String,
        latexEngine: String,
        latexShellEscape: Bool,
        latexShowBoxWarnings: Bool,
        figuresRoot: String? = nil
    ) {
        self.source = source
        self.format = format
        self.previewFormat = previewFormat
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.latexEngine = latexEngine
        self.latexShellEscape = latexShellEscape
        self.latexShowBoxWarnings = latexShowBoxWarnings
        self.figuresRoot = figuresRoot
    }
}

/// The compile core for one manuscript editor session.
///
/// GUI-meld Phase 3: moved out of the imprint app target into
/// PublicationManagerCore so the compile pipeline is a self-contained,
/// capability-injected unit shared by imprint AND imbib. It owns:
///
/// - the compile/preview **output state** (PDF, SVG, source map, diagnostics),
/// - the **orchestration** (branch on format, Typst via the in-process renderer,
///   LaTeX via the injected `LaTeXCompiling` capability),
/// - the **auto-compile debounce mechanism** (timing policy + task lifetime).
///
/// It deliberately holds no document/editor state and no platform conditionals
/// in its decision logic — LaTeX platform specifics live behind
/// `LaTeXCompiling`, and PDF/diagnostic caching lives behind
/// `CompiledArtifactStoring`. The owning view model exposes this controller's
/// state and methods unchanged, so call sites compile and read output exactly
/// as before.
@MainActor
@Observable
public final class ManuscriptCompileController {

    // MARK: - Compile output (observed by the view)

    public var pdfData: Data?
    public var sourceMapEntries: [SourceMapEntry] = []
    public var isCompiling = false
    public var compilationError: String?
    public var compilationWarnings: [String] = []
    /// Structured diagnostics from the last compile (errors on failure,
    /// warnings always) — Typst and LaTeX both land here, in user-source
    /// coordinates, so the strip/panel can navigate the editor to them.
    public var compilationDiagnostics: [CompileDiagnostic] = []

    /// SVG preview pages (Typst SVG preview mode).
    public var svgPages: [String] = []

    // LaTeX-specific output
    public var latexDiagnostics: [LaTeXDiagnostic] = []
    public var latexCompilationTimeMs: Int = 0
    public var latexProjectFiles: [URL] = []
    public var latexMainFileURL: URL?

    // Debug breadcrumb state (surfaced in DEBUG toolbar items).
    public var debugStatus: String = "idle"
    public var debugHistory: String = ""

    // MARK: - Owned services

    /// Shared Typst renderer instance for this editor session.
    private let renderer = TypstRenderer()

    /// Platform capability that performs LaTeX compilation (macOS: real TeX;
    /// iOS/absent: unsupported). Injected at composition time.
    private let latexCompiler: LaTeXCompiling

    /// Side-effect cache for compiled PDFs + diagnostics (imprint's
    /// `DocumentRegistry`; no-op in imbib). Injected so the controller holds no
    /// app-target type.
    private let artifactStore: CompiledArtifactStoring

    /// Post-compile follow-up work (SyncTeX load, dependency scan). Cancelled
    /// and replaced on each successful LaTeX compile.
    private var postCompileTask: Task<Void, Never>?

    /// Debounced auto-compile task. Owned here so the debounce *policy* travels
    /// with the compile core; the view supplies only the fire-time work.
    private var autoCompileTask: Task<Void, Never>?

    public init(
        latexCompiler: LaTeXCompiling,
        artifactStore: CompiledArtifactStoring = NoopCompiledArtifactStore()
    ) {
        self.latexCompiler = latexCompiler
        self.artifactStore = artifactStore
    }

    // MARK: - Auto-compile debounce

    /// Schedule `work` to run after `delayMs` of quiet, cancelling any
    /// previously scheduled compile. The view computes enablement/guards and
    /// passes the fire-time closure (which re-reads live view state and may
    /// bail); this type owns only the timing + task lifetime.
    public func scheduleCompile(after delayMs: Int, _ work: @escaping @MainActor () async -> Void) {
        autoCompileTask?.cancel()
        autoCompileTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    /// Cancel a pending debounced compile (e.g. while a citation palette is open).
    public func cancelScheduledCompile() {
        autoCompileTask?.cancel()
    }

    // MARK: - Entry point

    /// Compile `inputs.source` and publish the result into this controller's
    /// observable state. Branches on document format. Timed under the
    /// `compile` PerfMetrics bucket so budget breaches surface in the Console.
    public func compile(_ inputs: CompileInputs) async {
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
        compilationDiagnostics = []
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
            case .markdown, .plaintext:
                // No compile pipeline: markdown renders live (MarkdownUI) in
                // the Preview tab; plain text has no rendered state.
                pdfData = nil
            }
        }

        isCompiling = false
        debugStatus = "F:pdf=\(pdfData?.count ?? 0)"
        debugHistory += "F:\(pdfData?.count ?? 0)"
        Logger.compilation.infoCapture(
            "Compile finished: pdf=\(pdfData?.count ?? 0)b, errors=\(compilationError != nil ? 1 : 0)",
            category: "compile"
        )
        // "errors=1" without the message made the console useless for the one
        // question a failed compile raises. Log the message itself (bounded).
        if let error = compilationError {
            Logger.compilation.errorCapture(
                "Compile error: \(error.prefix(400))",
                category: "compile"
            )
        }
        log("compile() finished")
    }

    private func log(_ message: String) {
        Logger.compilation.infoCapture(message, category: "compile")
    }

    // MARK: - Typst Compilation

    private func compileTypst(_ inputs: CompileInputs) async {
        var sourceText = inputs.source
        let format = inputs.previewFormat
        debugStatus = "2:src=\(sourceText.count)ch"
        debugHistory += "2:\(sourceText.count) "
        log("Source text length: \(sourceText.count), format: \(format)")

        // Store-backed citations: resolve the manuscript's `@citeKey`
        // references against the host's library (citation seam) and serve
        // the matching BibTeX to Typst as a virtual bibliography.bib. When
        // the author hasn't placed a #bibliography() themselves, append one
        // so citations Just Work. No seam / no keys / no matches → exactly
        // the previous behavior.
        let bibSource = assembleBibliography(for: sourceText)
        if bibSource != nil && !sourceText.contains("#bibliography(") {
            sourceText += "\n#bibliography(\"bibliography.bib\")\n"
        }

        do {
            log("Creating RenderOptions")
            debugStatus = "3:options"
            debugHistory += "3 "
            let options = RenderOptions(
                pageSize: .a4,
                isDraft: false,
                figuresRoot: inputs.figuresRoot,
                bibSource: bibSource
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
                    compilationDiagnostics = output.diagnostics.map(CompileDiagnostic.init)

                    let pdfOutput = try await renderer.render(sourceText, options: options)
                    if pdfOutput.isSuccess {
                        pdfData = pdfOutput.pdfData
                        artifactStore.cachePDF(pdfOutput.pdfData, for: inputs.documentID)
                    }

                    debugStatus = "6:set,\(output.svgPages.count)p,map=\(output.sourceMapEntries.count)"
                    debugHistory += "6:ok "
                } else {
                    compilationError = output.errors.joined(separator: "\n")
                    compilationDiagnostics = output.diagnostics.map(CompileDiagnostic.init)
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
                    compilationDiagnostics = output.diagnostics.map(CompileDiagnostic.init)
                    artifactStore.cachePDF(output.pdfData, for: inputs.documentID)
                    debugStatus = "6:set,\(output.pdfData.count)b,map=\(output.sourceMapEntries.count)"
                    debugHistory += "6:ok "
                } else {
                    compilationError = output.errors.joined(separator: "\n")
                    compilationDiagnostics = output.diagnostics.map(CompileDiagnostic.init)
                    debugHistory += "E "
                }
            }
        } catch {
            compilationError = error.localizedDescription
            compilationDiagnostics = [
                CompileDiagnostic(severity: .error, message: error.localizedDescription)
            ]
            debugHistory += "X:\(error) "
        }
    }

    // (See also ManuscriptCitationKeys at the bottom of this file — the
    // PMC-facing wrapper app targets use so they don't link ImprintCore.)

    /// Build the virtual bibliography for a Typst source: extract the
    /// distinct `@citeKey` references (canonical Rust scanner) and export
    /// their BibTeX from the host's library via the citation seam. Returns
    /// nil when there are no keys, no seam, or no matches — the compile then
    /// proceeds without a bibliography, as before.
    private func assembleBibliography(for source: String) -> String? {
        guard source.contains("@") else { return nil }
        let keys = ImprintCore.extractCiteKeys(source: source)
        guard !keys.isEmpty else { return nil }
        guard let citations = ManuscriptEditorEnvironment.shared.citationSearch else {
            return nil
        }
        let bib = citations.bibliography(forKeys: keys)
        if let bib {
            log("bibliography: \(keys.count) cite key(s), \(bib.count)ch BibTeX")
        } else {
            log("bibliography: \(keys.count) cite key(s), none resolved in library")
        }
        return bib
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
            compilationDiagnostics = result.diagnostics.map(CompileDiagnostic.init)
            artifactStore.cacheDiagnostics(latexDiagnostics, for: inputs.documentID)
            compilationWarnings = result.formattedWarnings

            if let data = result.pdfData {
                pdfData = data
                sourceMapEntries = []
                artifactStore.cachePDF(data, for: inputs.documentID)

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
            compilationDiagnostics = result.diagnostics.map(CompileDiagnostic.init)
            artifactStore.cacheDiagnostics(latexDiagnostics, for: inputs.documentID)
            compilationWarnings = result.formattedWarnings
            compilationError = result.errorMessage
            debugHistory += "E "

        case .preflightFailed:
            // Temp-file write failed, the call threw, or LaTeX is unsupported on
            // this platform: only surface the error, leaving prior diagnostics /
            // warnings / timing untouched (matches the pre-extraction behavior).
            compilationError = result.errorMessage
            if let message = result.errorMessage {
                compilationDiagnostics = [CompileDiagnostic(severity: .error, message: message)]
            }
            debugHistory += "X:\(result.errorMessage ?? "preflight") "
        }
    }
}

// MARK: - Cite-key extraction (PMC-facing wrapper)

/// Distinct `@citeKey` references in a Typst source, in first-appearance
/// order — the canonical Rust scanner (`imprint-core::extract_cite_keys`),
/// re-exposed through PMC so app targets (imbib-iOS) don't need to link
/// ImprintCore directly.
public enum ManuscriptCitationKeys {
    public static func extract(from source: String) -> [String] {
        ImprintCore.extractCiteKeys(source: source)
    }
}
