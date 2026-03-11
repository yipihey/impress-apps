import AppKit
import ImpressLogging
import ImpressToolbox
import OSLog

/// Discovers and manages access to the local TeX distribution (MacTeX, TeX Live, Homebrew).
///
/// Uses security-scoped bookmarks to persist access across launches in the sandbox.
@MainActor @Observable
final class TeXDistributionManager {
    static let shared = TeXDistributionManager()

    /// Path to the TeX distribution's bin directory (e.g. /Library/TeX/texbin/).
    var distributionPath: URL?

    /// Whether a usable TeX distribution was found.
    var isAvailable: Bool { distributionPath != nil }

    /// Which engines are available in the discovered distribution.
    private(set) var installedEngines: [LaTeXEngine] = []

    /// Human-readable distribution description for settings UI.
    var distributionDescription: String {
        guard let path = distributionPath else { return "Not found" }
        return path.path
    }

    // MARK: - Discovery

    /// Search known macOS paths for a TeX distribution.
    func discoverDistribution() async {
        Logger.texDistribution.infoCapture("Starting TeX distribution discovery", category: "tex-distribution")

        // 1. Try saved bookmark first
        if resolveBookmark() {
            Logger.texDistribution.infoCapture("Using saved bookmark: \(distributionPath?.path ?? "nil")", category: "tex-distribution")
            return
        }
        Logger.texDistribution.infoCapture("No saved bookmark, searching known paths...", category: "tex-distribution")

        // 2. Try toolbox discovery if available (works from sandbox)
        if await discoverViaToolbox() {
            return
        }

        // 3. Search known paths locally (may be limited by sandbox)
        let knownPaths = [
            "/Library/TeX/texbin",
            "/usr/local/texlive/2025/bin/universal-darwin",
            "/usr/local/texlive/2024/bin/universal-darwin",
            "/usr/local/texlive/2023/bin/universal-darwin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]

        for path in knownPaths {
            let url = URL(fileURLWithPath: path)
            let pdflatex = url.appendingPathComponent("pdflatex")
            let dirExists = FileManager.default.fileExists(atPath: path)
            let fileExists = FileManager.default.fileExists(atPath: pdflatex.path)
            let isExec = FileManager.default.isExecutableFile(atPath: pdflatex.path)
            let isReadable = FileManager.default.isReadableFile(atPath: pdflatex.path)
            Logger.texDistribution.infoCapture("  \(path)/pdflatex — dir=\(dirExists), file=\(fileExists), exec=\(isExec), readable=\(isReadable)", category: "tex-distribution")

            if fileExists {
                distributionPath = url
                scanEngines()
                Logger.texDistribution.infoCapture("Discovered TeX distribution at \(path)", category: "tex-distribution")
                return
            }
        }

        Logger.texDistribution.warningCapture("No TeX distribution found in known paths, trying 'which'...", category: "tex-distribution")

        // 4. Try `which pdflatex` as fallback
        await discoverViaWhich()

        if distributionPath == nil {
            Logger.texDistribution.errorCapture("TeX distribution discovery failed — no pdflatex found anywhere", category: "tex-distribution")
        }
    }

    /// Discover TeX distribution via the toolbox server (bypasses sandbox restrictions).
    private func discoverViaToolbox() async -> Bool {
        guard await ToolboxClient.shared.isAvailable() else {
            Logger.texDistribution.infoCapture("Toolbox not available, skipping toolbox discovery", category: "tex-distribution")
            return false
        }

        do {
            let result = try await ToolboxClient.shared.discover(
                names: ["pdflatex", "xelatex", "lualatex", "latexmk", "latexindent"],
                searchPaths: [
                    "/Library/TeX/texbin",
                    "/usr/local/texlive/2025/bin/universal-darwin",
                    "/usr/local/texlive/2024/bin/universal-darwin",
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                ]
            )

            guard let pdflatexPath = result.found["pdflatex"] else {
                Logger.texDistribution.infoCapture("Toolbox discovery: pdflatex not found", category: "tex-distribution")
                return false
            }

            let binDir = URL(fileURLWithPath: pdflatexPath).deletingLastPathComponent()
            distributionPath = binDir

            // Build engine list from discovery results
            installedEngines = LaTeXEngine.allCases.filter { engine in
                result.found[engine.rawValue] != nil
            }

            Logger.texDistribution.infoCapture("Discovered TeX via toolbox: \(binDir.path), engines=\(installedEngines.map(\.rawValue))", category: "tex-distribution")
            return true
        } catch {
            Logger.texDistribution.warningCapture("Toolbox discovery failed: \(error.localizedDescription)", category: "tex-distribution")
            return false
        }
    }

    private func discoverViaWhich() async {
        // Try via toolbox first for which-like functionality
        if await ToolboxClient.shared.isAvailable() {
            do {
                let request = ProcessRequest(
                    executable: "/usr/bin/which",
                    arguments: ["pdflatex"],
                    timeoutMs: 5_000
                )
                let result = try await ToolboxClient.shared.execute(request)
                let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.isSuccess, !output.isEmpty {
                    let url = URL(fileURLWithPath: output).deletingLastPathComponent()
                    distributionPath = url
                    scanEngines()
                    Logger.texDistribution.infoCapture("Discovered TeX via toolbox which: \(url.path)", category: "tex-distribution")
                    return
                }
            } catch {
                Logger.texDistribution.infoCapture("Toolbox which failed: \(error.localizedDescription)", category: "tex-distribution")
            }
        }

        // Local fallback
        let result: (URL?, String) = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = ["pdflatex"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let exitCode = process.terminationStatus
                if output.isEmpty {
                    return (nil, "which pdflatex: empty output, exit=\(exitCode)")
                }
                return (URL(fileURLWithPath: output).deletingLastPathComponent(), "which pdflatex: '\(output)', exit=\(exitCode)")
            } catch {
                return (nil, "which pdflatex: launch error: \(error.localizedDescription)")
            }
        }.value

        Logger.texDistribution.infoCapture(result.1, category: "tex-distribution")

        if let url = result.0 {
            distributionPath = url
            scanEngines()
            Logger.texDistribution.infoCapture("Discovered TeX via which: \(url.path)", category: "tex-distribution")
        }
    }

    /// Scan the distribution directory for available engines.
    private func scanEngines() {
        guard let dir = distributionPath else { return }
        installedEngines = LaTeXEngine.allCases.filter { engine in
            let url = dir.appendingPathComponent(engine.rawValue)
            // Use fileExists instead of isExecutableFile — sandbox security-scoped
            // bookmarks grant read access but isExecutableFile may deny execute check.
            // The actual execution goes through Process which handles permissions.
            let exists = FileManager.default.fileExists(atPath: url.path)
            if !exists {
                Logger.texDistribution.infoCapture("  scanEngines: \(engine.rawValue) not found at \(url.path)", category: "tex-distribution")
            }
            return exists
        }
        Logger.texDistribution.infoCapture("Available engines: \(self.installedEngines.map(\.rawValue).joined(separator: ", ")) (\(installedEngines.count)/\(LaTeXEngine.allCases.count))", category: "tex-distribution")
    }

    /// Get the full executable URL for a given engine.
    func executableURL(for engine: LaTeXEngine) -> URL? {
        guard let dir = distributionPath else {
            Logger.texDistribution.warningCapture("executableURL(\(engine.rawValue)): distributionPath is nil", category: "tex-distribution")
            return nil
        }
        let url = dir.appendingPathComponent(engine.rawValue)
        // Use fileExists — sandbox bookmarks don't grant execute permission to
        // isExecutableFile, but Process can still launch the binary.
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists {
            Logger.texDistribution.warningCapture("executableURL(\(engine.rawValue)): \(url.path) not found, securityScoped=\(accessedSecurityScopedURL != nil)", category: "tex-distribution")
        }
        return exists ? url : nil
    }

    // MARK: - User Selection (NSOpenPanel)

    /// Show an open panel to let the user select the TeX distribution directory.
    func requestAccess() {
        let panel = NSOpenPanel()
        panel.message = "Select your TeX distribution's bin directory (e.g. /Library/TeX/texbin)"
        panel.prompt = "Select"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Library/TeX/texbin")

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.setDistribution(url)
            }
        }
    }

    private func setDistribution(_ url: URL) {
        stopAccess()
        distributionPath = url
        scanEngines()
        saveBookmark(for: url)
        Logger.texDistribution.infoCapture("User selected TeX distribution at \(url.path)", category: "tex-distribution")
    }

    // MARK: - Security-Scoped Bookmarks

    private static let bookmarkKey = "imprint.texDistributionBookmark"

    private func saveBookmark(for url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        } catch {
            Logger.texDistribution.warningCapture("Failed to save bookmark: \(error.localizedDescription)", category: "tex-distribution")
        }
    }

    @discardableResult
    private func resolveBookmark() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            Logger.texDistribution.infoCapture("resolveBookmark: no saved bookmark data in UserDefaults", category: "tex-distribution")
            return false
        }

        Logger.texDistribution.infoCapture("resolveBookmark: found \(data.count) bytes of bookmark data", category: "tex-distribution")

        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)

            Logger.texDistribution.infoCapture("resolveBookmark: resolved to \(url.path), stale=\(isStale)", category: "tex-distribution")

            if isStale {
                saveBookmark(for: url)
            }

            guard url.startAccessingSecurityScopedResource() else {
                Logger.texDistribution.warningCapture("resolveBookmark: startAccessingSecurityScopedResource() returned false for \(url.path)", category: "tex-distribution")
                return false
            }

            accessedSecurityScopedURL = url
            distributionPath = url
            scanEngines()

            // Verify the engines are actually accessible after bookmark resolution
            let pdflatexPath = url.appendingPathComponent("pdflatex").path
            let pdflatexExists = FileManager.default.fileExists(atPath: pdflatexPath)
            let pdflatexExec = FileManager.default.isExecutableFile(atPath: pdflatexPath)
            Logger.texDistribution.infoCapture("resolveBookmark: restored \(url.path) — pdflatex exists=\(pdflatexExists), exec=\(pdflatexExec), engines=\(installedEngines.map(\.rawValue))", category: "tex-distribution")
            return true
        } catch {
            Logger.texDistribution.warningCapture("resolveBookmark: failed — \(error.localizedDescription)", category: "tex-distribution")
            return false
        }
    }

    // MARK: - Verification

    /// Run `pdflatex --version` and return the output.
    func verifyInstallation() async -> String {
        guard let execURL = executableURL(for: .pdflatex) else {
            return "pdflatex not found (distributionPath=\(distributionPath?.path ?? "nil"))"
        }

        // Try via toolbox first
        if await ToolboxClient.shared.isAvailable() {
            do {
                let request = ProcessRequest(
                    executable: execURL.path,
                    arguments: ["--version"],
                    timeoutMs: 10_000
                )
                let result = try await ToolboxClient.shared.execute(request)
                let output = result.stdout.isEmpty ? result.stderr : result.stdout
                return output.components(separatedBy: "\n").first ?? output
            } catch {
                Logger.texDistribution.warningCapture("Toolbox verify failed: \(error.localizedDescription)", category: "tex-distribution")
            }
        }

        // Local fallback
        var env = ProcessInfo.processInfo.environment
        if let distPath = distributionPath?.path {
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(distPath):\(existingPath)"
        }

        let capturedEnv = env
        Logger.texDistribution.infoCapture("verifyInstallation: launching pdflatex via /usr/bin/env (local fallback)", category: "tex-distribution")

        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["pdflatex", "--version"]
            process.environment = capturedEnv
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? "No output"
                return output.components(separatedBy: "\n").first ?? output
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        }.value
    }

    // MARK: - Security-Scoped Resource Management

    private var accessedSecurityScopedURL: URL?

    /// Stop accessing the current security-scoped resource.
    func stopAccess() {
        accessedSecurityScopedURL?.stopAccessingSecurityScopedResource()
        accessedSecurityScopedURL = nil
    }
}
