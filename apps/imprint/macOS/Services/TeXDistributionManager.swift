import AppKit
import ImpressLogging
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
        // 1. Try saved bookmark first
        if resolveBookmark() { return }

        // 2. Search known paths
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
            if FileManager.default.isExecutableFile(atPath: pdflatex.path) {
                distributionPath = url
                scanEngines()
                Logger.texDistribution.infoCapture("Discovered TeX distribution at \(path)", category: "tex-distribution")
                return
            }
        }

        // 3. Try `which pdflatex` as fallback
        await discoverViaWhich()
    }

    private func discoverViaWhich() async {
        let result: URL? = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = ["pdflatex"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !output.isEmpty else { return nil }
                return URL(fileURLWithPath: output).deletingLastPathComponent()
            } catch {
                return nil
            }
        }.value

        if let url = result {
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
            return FileManager.default.isExecutableFile(atPath: url.path)
        }
        Logger.texDistribution.infoCapture("Available engines: \(self.installedEngines.map(\.rawValue).joined(separator: ", "))", category: "tex-distribution")
    }

    /// Get the full executable URL for a given engine.
    func executableURL(for engine: LaTeXEngine) -> URL? {
        guard let dir = distributionPath else { return nil }
        let url = dir.appendingPathComponent(engine.rawValue)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
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
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return false }

        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)

            if isStale {
                saveBookmark(for: url)
            }

            guard url.startAccessingSecurityScopedResource() else {
                Logger.texDistribution.warningCapture("Failed to access security-scoped bookmark", category: "tex-distribution")
                return false
            }

            accessedSecurityScopedURL = url
            distributionPath = url
            scanEngines()
            Logger.texDistribution.infoCapture("Restored TeX distribution from bookmark: \(url.path)", category: "tex-distribution")
            return true
        } catch {
            Logger.texDistribution.warningCapture("Failed to resolve bookmark: \(error.localizedDescription)", category: "tex-distribution")
            return false
        }
    }

    // MARK: - Verification

    /// Run `pdflatex --version` and return the output.
    func verifyInstallation() async -> String {
        guard let url = executableURL(for: .pdflatex) else {
            return "pdflatex not found"
        }

        let capturedURL = url
        return await Task.detached {
            let process = Process()
            process.executableURL = capturedURL
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                // Read pipe before waitUntilExit to prevent potential deadlock
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
