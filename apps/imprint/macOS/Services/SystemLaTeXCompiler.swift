#if os(macOS)
import Foundation
import ImpressLogging
import OSLog

/// macOS `LaTeXCompiling` backed by a local/embedded TeX toolchain.
///
/// GUI-meld Phase 3 PREP: this owns the full LaTeX orchestration that used to
/// live inline in `ImprintDocumentViewModel.compileLaTeX` — temp-file
/// materialization, per-document Veusz figure mirroring, engine resolution, the
/// real compile via `LaTeXCompilationService`, warning filtering, and the
/// post-compile SyncTeX load + project dependency scan. Keeping it behind the
/// `LaTeXCompiling` protocol lets the cross-platform compile controller stay
/// free of `#if os(macOS)` and of the macOS-only services this uses
/// (`LaTeXCompilationService`, `SyncTeXService`, `LaTeXProjectService`).
struct SystemLaTeXCompiler: LaTeXCompiling {
    var isSupported: Bool { true }

    func compile(_ request: LaTeXCompileRequest) async -> LaTeXCompileResult {
        let sourceText = request.source

        // Resolve the engine (raw string from settings → concrete engine).
        let engine = LaTeXEngine(rawValue: request.engineRaw) ?? .pdflatex

        // LaTeX requires a file URL — write the (possibly unsaved) source to a
        // stable per-document temp directory.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imprint-latex-\(request.documentID.uuidString)")
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
            let figuresSrc = try? VeuszWorkingDirectory().figuresDirectory(forDocumentID: request.documentID)
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
            return LaTeXCompileResult(
                outcome: .preflightFailed,
                pdfData: nil,
                diagnostics: [],
                formattedWarnings: [],
                compilationTimeMs: 0,
                errorMessage: "Failed to write temp file: \(error.localizedDescription)",
                synctexURL: nil,
                sourceURL: sourceURL
            )
        }

        let options = LaTeXCompileOptions(
            engine: engine,
            shellEscape: request.shellEscape
        )

        do {
            let result = try await LaTeXCompilationService.shared.compile(
                sourceURL: sourceURL,
                engine: engine,
                options: options
            )

            let diagnostics = result.errors + result.warnings

            // Surface warnings (filter box warnings if disabled).
            let formattedWarnings = result.warnings
                .filter { diag in
                    if !request.showBoxWarnings && (diag.message.hasPrefix("Overfull") || diag.message.hasPrefix("Underfull")) {
                        return false
                    }
                    return true
                }
                .map { "\($0.file):\($0.line): \($0.message)" }

            if result.isSuccess, let data = result.pdfData {
                return LaTeXCompileResult(
                    outcome: .succeeded,
                    pdfData: data,
                    diagnostics: diagnostics,
                    formattedWarnings: formattedWarnings,
                    compilationTimeMs: result.compilationTimeMs,
                    errorMessage: nil,
                    synctexURL: result.synctexURL,
                    sourceURL: sourceURL
                )
            } else {
                var message = result.errors.map(\.message).joined(separator: "\n")
                if message.isEmpty {
                    message = "Compilation failed (exit code \(result.exitCode))"
                }
                // Log first 500 chars of compilation output for debugging.
                let logSnippet = String(result.logOutput.prefix(500))
                Logger.compilation.errorCapture("LaTeX failed (exit \(result.exitCode)): errors=\(result.errors.map(\.message)), log=\(logSnippet)", category: "latex")
                return LaTeXCompileResult(
                    outcome: .engineFailed,
                    pdfData: nil,
                    diagnostics: diagnostics,
                    formattedWarnings: formattedWarnings,
                    compilationTimeMs: result.compilationTimeMs,
                    errorMessage: message,
                    synctexURL: nil,
                    sourceURL: sourceURL
                )
            }
        } catch {
            Logger.compilation.errorCapture("LaTeX compile threw: \(error)", category: "latex")
            return LaTeXCompileResult(
                outcome: .preflightFailed,
                pdfData: nil,
                diagnostics: [],
                formattedWarnings: [],
                compilationTimeMs: 0,
                errorMessage: error.localizedDescription,
                synctexURL: nil,
                sourceURL: sourceURL
            )
        }
    }

    func loadPostCompile(synctexURL: URL?, sourceURL: URL?) async -> LaTeXPostCompileResult {
        // Load SyncTeX data for bidirectional sync. Routed through the singleton
        // shim for now — the forward/inverse-sync consumers (ContentView,
        // PDFPreviewView, HTTP router) still read `SyncTeXService.shared`. The
        // type is now per-working-directory instantiable for the eventual move
        // to a per-manuscript session.
        if let synctexURL {
            do {
                try await SyncTeXService.shared.load(from: synctexURL)
            } catch {
                Logger.compilation.infoCapture("SyncTeX load failed: \(error)", category: "compile")
            }
        }

        guard let sourceURL else { return .empty }

        // Scan project dependencies for the sidebar.
        await LaTeXProjectService.shared.scanDependencies(from: sourceURL)
        let files = await LaTeXProjectService.shared.allProjectFiles
        let mainFile = await LaTeXProjectService.shared.mainFile
        return LaTeXPostCompileResult(projectFiles: files, mainFileURL: mainFile)
    }
}
#endif // os(macOS)
