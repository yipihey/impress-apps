import Foundation
import ImpressLogging
import OSLog

/// Provides LaTeX source code formatting via `latexindent` if available.
actor LaTeXFormatterService {
    static let shared = LaTeXFormatterService()

    /// Whether latexindent is available in the TeX distribution.
    var isAvailable: Bool {
        get async {
            await executableURL() != nil
        }
    }

    /// Format a LaTeX source string.
    /// Returns the formatted source, or nil if formatting failed.
    func format(_ source: String) async -> String? {
        guard let execURL = await executableURL() else {
            Logger.latexFormatter.warningCapture("latexindent not found", category: "latex-formatter")
            return nil
        }

        // Write source to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("imprint-format-\(UUID().uuidString).tex")

        guard let data = source.data(using: .utf8) else { return nil }
        do {
            try data.write(to: inputURL)
        } catch {
            Logger.latexFormatter.errorCapture("Failed to write temp file: \(error.localizedDescription)", category: "latex-formatter")
            return nil
        }

        // Set PATH to include TeX distribution
        var env = ProcessInfo.processInfo.environment
        if let distPath = await TeXDistributionManager.shared.distributionPath?.path {
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(distPath):\(existingPath)"
        }

        let capturedEnv = env
        let capturedInputURL = inputURL
        let capturedExecURL = execURL
        let result: String? = await Task.detached {
            defer { try? FileManager.default.removeItem(at: capturedInputURL) }

            let process = Process()
            process.executableURL = capturedExecURL
            process.arguments = [capturedInputURL.path]
            process.environment = capturedEnv

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let formatted = String(data: outputData, encoding: .utf8),
                      !formatted.isEmpty else { return nil }
                return formatted
            } catch {
                return nil
            }
        }.value

        if let result {
            Logger.latexFormatter.infoCapture("Formatted \(source.count) → \(result.count) chars", category: "latex-formatter")
        }
        return result
    }

    /// Format only a selected range of LaTeX source.
    func formatSelection(_ source: String, range: Range<String.Index>) async -> String? {
        let selection = String(source[range])
        guard let formatted = await format(selection) else { return nil }
        var result = source
        result.replaceSubrange(range, with: formatted)
        return result
    }

    private func executableURL() async -> URL? {
        let distManager = await TeXDistributionManager.shared
        guard let distPath = await distManager.distributionPath else { return nil }
        let url = distPath.appendingPathComponent("latexindent")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}
