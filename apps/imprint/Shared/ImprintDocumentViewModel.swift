import SwiftUI
import Foundation
import OSLog
import ImprintCore
import ImpressLogging

/// Owns the compile/preview pipeline for one imprint document editor session.
///
/// GUI-meld Phase 3 PREP: the compile core itself now lives in
/// `ManuscriptCompileController` (a self-contained, platform-capability-injected
/// unit that can move to the shared GUI package later). This view model *owns*
/// that controller by delegation and re-exposes its state + methods unchanged,
/// so every call site — `vm.compile(makeCompileInputs())`, `vm.pdfData`,
/// `vm.isCompiling`, … — behaves exactly as before.
///
/// The view model remains the imprint-specific composition seam: it is where the
/// platform's `LaTeXCompiling` capability is injected (macOS → real system TeX;
/// iOS / TeX-less desktop → `UnsupportedLaTeXCompiler`).
@MainActor
@Observable
final class ImprintDocumentViewModel {

    /// The extracted compile core. Public so future code can consume it directly
    /// (or lift it into the shared package); existing callers keep using the
    /// forwarders below.
    let compileController: ManuscriptCompileController

    init(
        latexCompiler: LaTeXCompiling = UnsupportedLaTeXCompiler(),
        artifactStore: CompiledArtifactStoring = DocumentRegistry.shared
    ) {
        self.compileController = ManuscriptCompileController(
            latexCompiler: latexCompiler,
            artifactStore: artifactStore
        )
    }

    // MARK: - Compile output (forwarded from the controller)

    var pdfData: Data? { compileController.pdfData }
    var sourceMapEntries: [SourceMapEntry] { compileController.sourceMapEntries }
    var isCompiling: Bool { compileController.isCompiling }
    var compilationError: String? { compileController.compilationError }
    var compilationWarnings: [String] { compileController.compilationWarnings }
    var svgPages: [String] { compileController.svgPages }

    var latexDiagnostics: [LaTeXDiagnostic] { compileController.latexDiagnostics }
    var latexCompilationTimeMs: Int { compileController.latexCompilationTimeMs }
    var latexProjectFiles: [URL] { compileController.latexProjectFiles }
    var latexMainFileURL: URL? { compileController.latexMainFileURL }

    var debugStatus: String { compileController.debugStatus }
    var debugHistory: String { compileController.debugHistory }

    // MARK: - Compile (forwarded)

    /// Compile `inputs.source` and publish the result into the observable state.
    func compile(_ inputs: CompileInputs) async {
        await compileController.compile(inputs)
    }

    /// Schedule a debounced auto-compile (the view supplies the fire-time work,
    /// which re-reads live view state and may bail).
    func scheduleCompile(after delayMs: Int, _ work: @escaping @MainActor () async -> Void) {
        compileController.scheduleCompile(after: delayMs, work)
    }

    /// Cancel any pending debounced compile.
    func cancelScheduledCompile() {
        compileController.cancelScheduledCompile()
    }
}
