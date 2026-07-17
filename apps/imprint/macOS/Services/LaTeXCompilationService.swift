import Foundation
import ImpressLogging
import ImpressToolbox
import OSLog
#if IMPRINT_TECTONIC
import ImprintRustCore
#endif

/// Engine choices for LaTeX compilation.
enum LaTeXEngine: String, CaseIterable, Codable, Sendable {
    case pdflatex
    case xelatex
    case lualatex
    case latexmk
    // Embedded, self-contained Tectonic engine (in-process, no system TeX).
    // Gated: only present in a Tectonic-enabled build (see IMPRINT_TECTONIC),
    // which links imprint-core's `tectonic-render` feature.
    #if IMPRINT_TECTONIC
    case tectonic
    #endif

    var displayName: String {
        switch self {
        case .pdflatex: "pdfLaTeX"
        case .xelatex: "XeLaTeX"
        case .lualatex: "LuaLaTeX"
        case .latexmk: "latexmk"
        #if IMPRINT_TECTONIC
        case .tectonic: "Tectonic"
        #endif
        }
    }

    func defaultArguments(outputDir: String) -> [String] {
        switch self {
        case .latexmk:
            ["-pdf", "-interaction=nonstopmode", "-synctex=1", "-output-directory=\(outputDir)"]
        case .pdflatex, .xelatex, .lualatex:
            ["-interaction=nonstopmode", "-synctex=1", "-output-directory=\(outputDir)"]
        #if IMPRINT_TECTONIC
        case .tectonic:
            // Tectonic runs in-process via imprint-core; no CLI args.
            []
        #endif
        }
    }
}

/// Options for a LaTeX compilation run.
struct LaTeXCompileOptions: Sendable {
    var engine: LaTeXEngine = .pdflatex
    var synctex: Bool = true
    var draft: Bool = false
    var shellEscape: Bool = false
    var extraArguments: [String] = []
}

/// The result of a LaTeX compilation.
struct LaTeXCompilationResult: Sendable {
    var pdfData: Data?
    var pdfURL: URL?
    var synctexURL: URL?
    var logOutput: String
    var errors: [LaTeXDiagnostic]
    var warnings: [LaTeXDiagnostic]
    var exitCode: Int32
    var compilationTimeMs: Int

    var isSuccess: Bool { exitCode == 0 && pdfData != nil }
}

/// A single diagnostic from LaTeX compilation.
struct LaTeXDiagnostic: Identifiable, Sendable {
    let id = UUID()
    var file: String
    var line: Int
    var column: Int?
    var message: String
    var severity: DiagnosticSeverity
    var context: String?

    enum DiagnosticSeverity: String, Sendable {
        case error, warning, info
    }
}

/// Compiles LaTeX documents using the local TeX distribution via Process.
actor LaTeXCompilationService {
    static let shared = LaTeXCompilationService()

    private var runningTask: Task<(Data, Data, Int32), Error>?

    private(set) var isCompiling = false

    // MARK: - Compilation

    /// Compile a `.tex` file to PDF using the specified engine.
    ///
    /// - Parameters:
    ///   - sourceURL: Path to the main `.tex` file.
    ///   - engine: Which TeX engine to use.
    ///   - options: Compilation options.
    /// - Returns: A `LaTeXCompilationResult` with PDF data, diagnostics, etc.
    func compile(sourceURL: URL, engine: LaTeXEngine, options: LaTeXCompileOptions) async throws -> LaTeXCompilationResult {
        #if IMPRINT_TECTONIC
        if engine == .tectonic {
            // Self-contained in-process engine — no toolbox / system TeX.
            return try await compileViaTectonic(sourceURL: sourceURL, options: options)
        }
        #endif
        if await ToolboxClient.shared.isAvailable() {
            return try await compileViaToolbox(sourceURL: sourceURL, engine: engine, options: options)
        } else {
            Logger.compilation.warningCapture("Toolbox unavailable, falling back to local Process", category: "latex")
            return try await compileLocal(sourceURL: sourceURL, engine: engine, options: options)
        }
    }

    #if IMPRINT_TECTONIC
    /// Warm the Tectonic engine at launch: a trivial throwaway compile that
    /// primes the on-demand package bundle (fetched into the sandbox cache) and
    /// the LaTeX format cache, so the user's first real compile isn't slow.
    /// Idempotent and cheap once warm. Runs off the main thread.
    static func warmTectonic() async {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("tectonic", isDirectory: true)
        if let cacheDir { try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true) }
        let start = Date()
        let opts = ImprintRustCore.TectonicOptions(synctex: false, cacheDir: cacheDir?.path, filesystemRoot: nil)
        let src = "\\documentclass{article}\\begin{document}warm\\end{document}"
        _ = await Task.detached(priority: .background) {
            ImprintRustCore.compileLatexTectonic(source: src, options: opts)
        }.value
        Logger.compilation.infoCapture(
            "Tectonic engine warmed in \(Int(Date().timeIntervalSince(start) * 1000))ms",
            category: "latex"
        )
    }

    /// Compile via the embedded Tectonic engine (imprint-core `tectonic-render`).
    /// Runs in-process on a detached task; maps the Rust `LatexCompileResult`
    /// into the shared `LaTeXCompilationResult`. Packages are fetched on demand
    /// into the app's sandbox Caches dir.
    private func compileViaTectonic(sourceURL: URL, options: LaTeXCompileOptions) async throws -> LaTeXCompilationResult {
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("tectonic", isDirectory: true)
        if let cacheDir { try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true) }

        let start = Date()
        let rustOptions = ImprintRustCore.TectonicOptions(
            synctex: options.synctex,
            cacheDir: cacheDir?.path,
            // Resolve figures/\input against the doc's temp compile dir (where the
            // view model mirrors the Veusz figures/ before calling us).
            filesystemRoot: sourceURL.deletingLastPathComponent().path
        )
        let result = await Task.detached(priority: .userInitiated) {
            ImprintRustCore.compileLatexTectonic(source: source, options: rustOptions)
        }.value
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        // Write SyncTeX bytes to a sibling file so SyncTeXService can load it.
        var synctexURL: URL?
        if let synctexBytes = result.synctexData {
            let url = sourceURL.deletingPathExtension().appendingPathExtension("synctex.gz")
            try? Data(synctexBytes).write(to: url)
            synctexURL = url
        }

        let allDiagnostics = result.diagnostics.map { d in
            LaTeXDiagnostic(
                file: d.file,
                line: Int(d.line),
                column: d.column.map(Int.init),
                message: d.message,
                severity: LaTeXDiagnostic.DiagnosticSeverity(rawValue: d.severity) ?? .warning,
                context: d.context
            )
        }
        let errors = allDiagnostics.filter { $0.severity == .error }
        let warnings = allDiagnostics.filter { $0.severity != .error }
        // Surface the fatal-error summary if the engine produced no diagnostics.
        var finalErrors = errors
        if let err = result.error, errors.isEmpty {
            finalErrors = [LaTeXDiagnostic(file: sourceURL.lastPathComponent, line: 0, column: nil,
                                           message: err, severity: .error, context: nil)]
        }

        Logger.compilation.infoCapture(
            "Tectonic compile: pdf=\(result.pdfData?.count ?? 0)b, synctex=\(result.synctexData?.count ?? 0)b, diags=\(allDiagnostics.count), \(result.compileMs)ms",
            category: "latex"
        )

        return LaTeXCompilationResult(
            pdfData: result.pdfData.map { Data($0) },
            pdfURL: nil,
            synctexURL: synctexURL,
            logOutput: result.error ?? "",
            errors: finalErrors,
            warnings: warnings,
            exitCode: result.pdfData == nil ? 1 : 0,
            compilationTimeMs: result.compileMs > 0 ? Int(result.compileMs) : elapsedMs
        )
    }
    #endif

    // MARK: - Toolbox Compilation

    private func compileViaToolbox(sourceURL: URL, engine: LaTeXEngine, options: LaTeXCompileOptions) async throws -> LaTeXCompilationResult {
        let start = CFAbsoluteTimeGetCurrent()

        let texDistribution = await TeXDistributionManager.shared
        guard let execURL = await texDistribution.executableURL(for: engine) else {
            throw LaTeXCompilationError.engineNotFound(engine)
        }

        let sourceDir = sourceURL.deletingLastPathComponent()
        let buildDir = buildDirectory(for: sourceURL)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let buildDirName = buildDir.lastPathComponent
        var arguments = engine.defaultArguments(outputDir: buildDirName)
        if options.draft { arguments.append("-draftmode") }
        if options.shellEscape { arguments.append("-shell-escape") }
        if !options.synctex { arguments.removeAll { $0.hasPrefix("-synctex") } }
        arguments.append(contentsOf: options.extraArguments)
        arguments.append(sourceURL.lastPathComponent)

        var env: [String: String] = [:]
        if let distPath = await texDistribution.distributionPath?.path {
            let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(distPath):\(existingPath)"
        }

        // Inject TEXINPUTS so graphicx can find rendered Veusz plots that
        // live in the per-document plot-store working directory (a
        // sandboxed container path that the main.tex's cwd can't see).
        // Format per kpathsea: colon-separated, trailing `//` recurses,
        // trailing `:` appends the default search path.
        let plotPaths = await Self.plotSearchPaths()
        if !plotPaths.isEmpty {
            let existing = ProcessInfo.processInfo.environment["TEXINPUTS"] ?? ""
            let joined = (plotPaths + [existing]).filter { !$0.isEmpty }.joined(separator: ":")
            // Trailing colon = append system default. Required for kpathsea.
            env["TEXINPUTS"] = joined.hasSuffix(":") ? joined : "\(joined):"
            let joinedForLog = plotPaths.joined(separator: ", ")
            Logger.compilation.infoCapture(
                "TEXINPUTS injected for \(plotPaths.count) plot working dir(s): \(joinedForLog)",
                category: "latex"
            )
        }

        let pdfFileName = sourceURL.deletingPathExtension().lastPathComponent + ".pdf"
        let pdfURL = buildDir.appendingPathComponent(pdfFileName)

        Logger.compilation.infoCapture("Compiling \(sourceURL.lastPathComponent) with \(engine.rawValue) via toolbox", category: "latex")

        isCompiling = true
        defer { isCompiling = false }

        let request = ProcessRequest(
            executable: execURL.path,
            arguments: arguments,
            workingDirectory: sourceDir.path,
            environment: env,
            timeoutMs: 60_000
        )

        let (processResult, pdfData) = try await ToolboxClient.shared.executeAndRetrieveFile(
            request, outputFile: pdfURL.path
        )

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

        // Read the .log file for diagnostics
        let logFileName = sourceURL.deletingPathExtension().lastPathComponent + ".log"
        let logFileURL = buildDir.appendingPathComponent(logFileName)
        let logFileContent = (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""

        let logOutput = [processResult.stdout, processResult.stderr].joined(separator: "\n")
        let diagnosticSource = logFileContent.isEmpty ? logOutput : logFileContent
        let diagnostics = LaTeXLogParser.parse(diagnosticSource)

        // Find synctex file
        let synctexFileName = sourceURL.deletingPathExtension().lastPathComponent + ".synctex.gz"
        let synctexURL = buildDir.appendingPathComponent(synctexFileName)
        let synctexExists = FileManager.default.fileExists(atPath: synctexURL.path)

        Logger.compilation.infoCapture("Compilation finished (toolbox): exit=\(processResult.exitCode), time=\(elapsedMs)ms, pdf=\(pdfData?.count ?? 0)b, errors=\(diagnostics.errors.count), warnings=\(diagnostics.warnings.count)", category: "latex")

        return LaTeXCompilationResult(
            pdfData: pdfData,
            pdfURL: pdfData != nil ? pdfURL : nil,
            synctexURL: synctexExists ? synctexURL : nil,
            logOutput: diagnosticSource,
            errors: diagnostics.errors,
            warnings: diagnostics.warnings,
            exitCode: processResult.exitCode,
            compilationTimeMs: elapsedMs
        )
    }

    // MARK: - Local Fallback (for unsandboxed debug builds)

    private func compileLocal(sourceURL: URL, engine: LaTeXEngine, options: LaTeXCompileOptions) async throws -> LaTeXCompilationResult {
        let start = CFAbsoluteTimeGetCurrent()

        let texDistribution = await TeXDistributionManager.shared
        guard await texDistribution.executableURL(for: engine) != nil else {
            throw LaTeXCompilationError.engineNotFound(engine)
        }

        let sourceDir = sourceURL.deletingLastPathComponent()
        let buildDir = buildDirectory(for: sourceURL)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let buildDirName = buildDir.lastPathComponent
        var arguments = engine.defaultArguments(outputDir: buildDirName)
        if options.draft { arguments.append("-draftmode") }
        if options.shellEscape { arguments.append("-shell-escape") }
        if !options.synctex { arguments.removeAll { $0.hasPrefix("-synctex") } }
        arguments.append(contentsOf: options.extraArguments)
        arguments.append(sourceURL.lastPathComponent)

        var env = ProcessInfo.processInfo.environment
        if let distPath = await texDistribution.distributionPath?.path {
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(distPath):\(existingPath)"
        }

        // Same TEXINPUTS injection as the toolbox path (see compileViaToolbox).
        let plotPaths = await Self.plotSearchPaths()
        if !plotPaths.isEmpty {
            let existing = env["TEXINPUTS"] ?? ""
            let joined = (plotPaths + [existing]).filter { !$0.isEmpty }.joined(separator: ":")
            env["TEXINPUTS"] = joined.hasSuffix(":") ? joined : "\(joined):"
        }

        let envArguments = [engine.rawValue] + arguments

        Logger.compilation.infoCapture("Compiling \(sourceURL.lastPathComponent) with \(engine.rawValue) via /usr/bin/env (local fallback)", category: "latex")

        isCompiling = true
        defer { isCompiling = false; runningTask = nil }

        let capturedArguments = envArguments
        let capturedSourceDir = sourceDir
        let capturedEnv = env

        let task = Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = capturedArguments
            process.currentDirectoryURL = capturedSourceDir
            process.environment = capturedEnv

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                throw LaTeXCompilationError.launchFailed(error)
            }

            let group = DispatchGroup()
            var outData = Data()
            var errData = Data()

            group.enter()
            DispatchQueue.global().async {
                outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.wait()

            process.waitUntilExit()
            return (outData, errData, process.terminationStatus)
        }
        runningTask = task
        let (stdoutData, stderrData, exitCode) = try await task.value

        let logOutput = [
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? "",
        ].joined(separator: "\n")
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

        let logFileName = sourceURL.deletingPathExtension().lastPathComponent + ".log"
        let logFileURL = buildDir.appendingPathComponent(logFileName)
        let logFileContent = (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
        let diagnosticSource = logFileContent.isEmpty ? logOutput : logFileContent
        let diagnostics = LaTeXLogParser.parse(diagnosticSource)

        let pdfFileName = sourceURL.deletingPathExtension().lastPathComponent + ".pdf"
        let pdfURL = buildDir.appendingPathComponent(pdfFileName)
        let pdfData = try? Data(contentsOf: pdfURL)

        let synctexFileName = sourceURL.deletingPathExtension().lastPathComponent + ".synctex.gz"
        let synctexURL = buildDir.appendingPathComponent(synctexFileName)
        let synctexExists = FileManager.default.fileExists(atPath: synctexURL.path)

        Logger.compilation.infoCapture("Compilation finished (local): exit=\(exitCode), time=\(elapsedMs)ms, pdf=\(pdfData?.count ?? 0)b, errors=\(diagnostics.errors.count), warnings=\(diagnostics.warnings.count)", category: "latex")

        return LaTeXCompilationResult(
            pdfData: pdfData,
            pdfURL: pdfData != nil ? pdfURL : nil,
            synctexURL: synctexExists ? synctexURL : nil,
            logOutput: diagnosticSource,
            errors: diagnostics.errors,
            warnings: diagnostics.warnings,
            exitCode: exitCode,
            compilationTimeMs: elapsedMs
        )
    }

    // MARK: - TEXINPUTS for Veusz plot working dirs

    /// Collect the on-disk working-directory paths of every registered
    /// `VeuszPlotStore` so the LaTeX compile can find rendered plots that
    /// live in per-document sandboxed paths (not next to main.tex).
    ///
    /// Returns absolute paths; kpathsea expands `~` for us via TEXINPUTS,
    /// but absolute paths are simpler.
    @MainActor
    private static func plotSearchPaths() -> [String] {
        VeuszPlotStoreRegistry.shared.allStores.map(\.workingDirectory.path)
    }

    // MARK: - Build Directory

    /// Returns the build directory (`.build/`) alongside the source file.
    func buildDirectory(for sourceURL: URL) -> URL {
        sourceURL.deletingLastPathComponent().appendingPathComponent(".build")
    }

    /// Remove the build directory for a source file.
    func cleanBuild(for sourceURL: URL) throws {
        let dir = buildDirectory(for: sourceURL)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
            Logger.compilation.infoCapture("Cleaned build directory: \(dir.path)", category: "latex")
        }
    }

    // MARK: - Cancellation

    /// Cancel the running compilation task.
    func cancel() {
        if let task = runningTask {
            task.cancel()
            Logger.compilation.infoCapture("Cancelled running compilation", category: "latex")
        }
        runningTask = nil
        isCompiling = false
    }
}

// MARK: - Errors

enum LaTeXCompilationError: LocalizedError {
    case engineNotFound(LaTeXEngine)
    case launchFailed(Error)
    case noTeXDistribution

    var errorDescription: String? {
        switch self {
        case .engineNotFound(let engine):
            "TeX engine '\(engine.displayName)' not found. Check Settings > LaTeX."
        case .launchFailed(let error):
            "Failed to launch TeX process: \(error.localizedDescription)"
        case .noTeXDistribution:
            "No TeX distribution found. Install MacTeX or TeX Live, then configure in Settings > LaTeX."
        }
    }
}
