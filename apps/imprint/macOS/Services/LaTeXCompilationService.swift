import Foundation
import ImpressLogging
import OSLog

/// Engine choices for LaTeX compilation.
enum LaTeXEngine: String, CaseIterable, Codable, Sendable {
    case pdflatex
    case xelatex
    case lualatex
    case latexmk

    var displayName: String {
        switch self {
        case .pdflatex: "pdfLaTeX"
        case .xelatex: "XeLaTeX"
        case .lualatex: "LuaLaTeX"
        case .latexmk: "latexmk"
        }
    }

    func defaultArguments(outputDir: String) -> [String] {
        switch self {
        case .latexmk:
            ["-pdf", "-interaction=nonstopmode", "-synctex=1", "-output-directory=\(outputDir)"]
        case .pdflatex, .xelatex, .lualatex:
            ["-interaction=nonstopmode", "-synctex=1", "-output-directory=\(outputDir)"]
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

    private var runningProcess: Process?

    var isCompiling: Bool { runningProcess != nil }

    // MARK: - Compilation

    /// Compile a `.tex` file to PDF using the specified engine.
    ///
    /// - Parameters:
    ///   - sourceURL: Path to the main `.tex` file.
    ///   - engine: Which TeX engine to use.
    ///   - options: Compilation options.
    /// - Returns: A `LaTeXCompilationResult` with PDF data, diagnostics, etc.
    func compile(sourceURL: URL, engine: LaTeXEngine, options: LaTeXCompileOptions) async throws -> LaTeXCompilationResult {
        let start = CFAbsoluteTimeGetCurrent()

        let texDistribution = await TeXDistributionManager.shared
        guard let execURL = await texDistribution.executableURL(for: engine) else {
            throw LaTeXCompilationError.engineNotFound(engine)
        }

        let sourceDir = sourceURL.deletingLastPathComponent()
        let buildDir = buildDirectory(for: sourceURL)

        // Ensure build directory exists
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let buildDirName = buildDir.lastPathComponent
        var arguments = engine.defaultArguments(outputDir: buildDirName)

        if options.draft {
            arguments.append("-draftmode")
        }
        if options.shellEscape {
            arguments.append("-shell-escape")
        }
        if !options.synctex {
            // Remove -synctex=1 if disabled
            arguments.removeAll { $0.hasPrefix("-synctex") }
        }
        arguments.append(contentsOf: options.extraArguments)
        arguments.append(sourceURL.lastPathComponent)

        let process = Process()
        process.executableURL = execURL
        process.arguments = arguments
        process.currentDirectoryURL = sourceDir

        // Set up environment with TeX distribution in PATH
        var env = ProcessInfo.processInfo.environment
        if let distPath = await texDistribution.distributionPath?.path {
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(distPath):\(existingPath)"
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        runningProcess = process

        defer { runningProcess = nil }

        Logger.compilation.infoCapture("Compiling \(sourceURL.lastPathComponent) with \(engine.rawValue)", category: "latex")

        do {
            try process.run()
        } catch {
            throw LaTeXCompilationError.launchFailed(error)
        }

        // Read both pipes concurrently to avoid deadlock when >64KB on one pipe
        let stdoutData: Data
        let stderrData: Data
        let group = DispatchGroup()
        var _stdoutData = Data()
        var _stderrData = Data()

        group.enter()
        DispatchQueue.global().async {
            _stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            _stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        stdoutData = _stdoutData
        stderrData = _stderrData

        process.waitUntilExit()

        let logOutput = [
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? "",
        ].joined(separator: "\n")

        let exitCode = process.terminationStatus
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

        // Also try to read the .log file for better diagnostics
        let logFileName = sourceURL.deletingPathExtension().lastPathComponent + ".log"
        let logFileURL = buildDir.appendingPathComponent(logFileName)
        let logFileContent = (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
        let diagnosticSource = logFileContent.isEmpty ? logOutput : logFileContent

        // Parse diagnostics
        let diagnostics = LaTeXLogParser.parse(diagnosticSource)

        // Read PDF if compilation succeeded
        let pdfFileName = sourceURL.deletingPathExtension().lastPathComponent + ".pdf"
        let pdfURL = buildDir.appendingPathComponent(pdfFileName)
        let pdfData = try? Data(contentsOf: pdfURL)

        // Find synctex file
        let synctexFileName = sourceURL.deletingPathExtension().lastPathComponent + ".synctex.gz"
        let synctexURL = buildDir.appendingPathComponent(synctexFileName)
        let synctexExists = FileManager.default.fileExists(atPath: synctexURL.path)

        Logger.compilation.infoCapture("Compilation finished: exit=\(exitCode), time=\(elapsedMs)ms, pdf=\(pdfData?.count ?? 0)b, errors=\(diagnostics.errors.count), warnings=\(diagnostics.warnings.count)", category: "latex")

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

    /// Kill the running compilation process.
    func cancel() {
        if let process = runningProcess, process.isRunning {
            process.terminate()
            Logger.compilation.infoCapture("Cancelled running compilation", category: "latex")
        }
        runningProcess = nil
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
