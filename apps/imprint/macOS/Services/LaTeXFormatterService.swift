import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imprint.app", category: "latexFormatter")

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
            logger.warning("latexindent not found")
            return nil
        }

        // Write source to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("imprint-format-\(UUID().uuidString).tex")
        defer { try? FileManager.default.removeItem(at: inputURL) }

        guard let data = source.data(using: .utf8) else { return nil }
        do {
            try data.write(to: inputURL)
        } catch {
            logger.error("Failed to write temp file: \(error.localizedDescription)")
            return nil
        }

        let process = Process()
        process.executableURL = execURL
        process.arguments = [inputURL.path]

        // Set PATH to include TeX distribution
        var env = ProcessInfo.processInfo.environment
        if let distPath = await TeXDistributionManager.shared.distributionPath?.path {
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = "\(distPath):\(existingPath)"
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let formatted = String(data: outputData, encoding: .utf8),
                  !formatted.isEmpty else { return nil }

            logger.info("Formatted \(source.count) → \(formatted.count) chars")
            return formatted
        } catch {
            logger.error("latexindent failed: \(error.localizedDescription)")
            return nil
        }
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
