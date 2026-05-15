import AppKit
import Foundation
import ImpressLogging
import OSLog

/// Detects, launches, and headlessly renders Veusz plots.
///
/// Veusz is an external macOS app (`/Applications/Veusz.app`). This service has
/// two responsibilities:
///   1. Open a `.vsz` file in the Veusz GUI for interactive editing.
///   2. Run `veusz.exe --export` to render a `.vsz` to SVG/PNG/PDF without a UI.
///
/// The service is stateless and safe to instantiate per call; install detection
/// is also exposed as a static helper so UI can show a "Veusz not installed"
/// banner without spinning up the full service.
@MainActor
final class VeuszService {

    /// Veusz's CFBundleIdentifier (from /Applications/Veusz.app/Contents/Info.plist).
    static let veuszBundleIdentifier = "Veusz"

    /// Default install location, used as a fallback when Launch Services can't find the app.
    static let veuszFallbackAppURL = URL(fileURLWithPath: "/Applications/Veusz.app")

    /// Relative path from the app bundle root to the headless CLI binary.
    static let veuszExecutableRelativePath = "Contents/MacOS/veusz.exe"

    init() {}

    // MARK: - Discovery

    /// URL of the installed Veusz.app, or nil if not present.
    static func locateApp() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: veuszBundleIdentifier) {
            return url
        }
        if FileManager.default.fileExists(atPath: veuszFallbackAppURL.path) {
            return veuszFallbackAppURL
        }
        return nil
    }

    /// URL of the headless `veusz.exe` binary inside the app bundle, or nil if not installed.
    static func locateExecutable() -> URL? {
        guard let appURL = locateApp() else { return nil }
        let binary = appURL.appending(path: veuszExecutableRelativePath)
        return FileManager.default.fileExists(atPath: binary.path) ? binary : nil
    }

    /// True when Veusz is installed and ready to use.
    static var isInstalled: Bool { locateExecutable() != nil }

    /// Veusz short version string (e.g. "4.2") read from the app's Info.plist, or nil if unavailable.
    static func installedVersion() -> String? {
        guard let appURL = locateApp() else { return nil }
        let plistURL = appURL.appending(path: "Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    // MARK: - Open

    /// Open a `.vsz` file in the Veusz GUI. Returns true if Launch Services accepted the request.
    @discardableResult
    func openInVeusz(_ url: URL) -> Bool {
        let opened = NSWorkspace.shared.open(url)
        Logger.veusz.infoCapture(
            "openInVeusz \(url.lastPathComponent) → \(opened ? "ok" : "failed")",
            category: "veusz"
        )
        return opened
    }

    // MARK: - Export

    /// Errors raised by the headless export path.
    enum ExportError: LocalizedError {
        case veuszNotInstalled
        case sourceFileMissing(URL)
        case processFailed(exitCode: Int32, stderr: String)
        case outputNotProduced(URL)

        var errorDescription: String? {
            switch self {
            case .veuszNotInstalled:
                return "Veusz is not installed. Install Veusz.app in /Applications to render plots."
            case .sourceFileMissing(let url):
                return "Veusz source file not found: \(url.path)"
            case .processFailed(let code, let stderr):
                let tail = stderr.split(separator: "\n").suffix(5).joined(separator: "\n")
                return "Veusz export failed (exit \(code)): \(tail)"
            case .outputNotProduced(let url):
                return "Veusz exited successfully but did not produce \(url.lastPathComponent)."
            }
        }
    }

    /// Render `source` (a `.vsz` file) to `destination` in the requested format.
    ///
    /// Runs `veusz.exe --export <destination> <source> --quiet` off the main actor.
    /// The destination's file extension must match `format` — Veusz infers the
    /// format from the output extension.
    func export(
        source: URL,
        to destination: URL,
        format: VeuszPlotRef.ExportFormat
    ) async throws {
        guard let executable = Self.locateExecutable() else {
            throw ExportError.veuszNotInstalled
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ExportError.sourceFileMissing(source)
        }

        // Veusz infers format from the destination extension. Force-correct it so
        // callers can pass a destination with no/wrong extension and still get the
        // requested format.
        let normalizedDestination = destination
            .deletingPathExtension()
            .appendingPathExtension(format.fileExtension)

        // Ensure the destination directory exists. Veusz fails ungracefully otherwise.
        let parentDir = normalizedDestination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let started = Date()
        try await runProcess(
            executable: executable,
            arguments: ["--export", normalizedDestination.path, source.path, "--quiet"]
        )
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

        guard FileManager.default.fileExists(atPath: normalizedDestination.path) else {
            throw ExportError.outputNotProduced(normalizedDestination)
        }

        // ADR-0014 D57: emit a JSON-LD provenance sidecar next to the
        // rendered file. Best-effort — if this fails, the figure render
        // already succeeded so don't surface the error to the caller.
        let sidecarURL = Self.provenanceSidecarURL(for: normalizedDestination)
        do {
            try Self.writeProvenanceSidecar(
                source: source,
                rendered: normalizedDestination,
                sidecar: sidecarURL,
                format: format,
                elapsedMs: elapsedMs
            )
        } catch {
            Logger.veusz.warningCapture(
                "Provenance sidecar emit failed for \(normalizedDestination.lastPathComponent): \(error.localizedDescription)",
                category: "veusz"
            )
        }

        Logger.veusz.infoCapture(
            "Exported \(source.lastPathComponent) → \(normalizedDestination.lastPathComponent) in \(elapsedMs)ms",
            category: "veusz"
        )
    }

    /// `figure.svg` -> `figure.ro-crate.json`.
    static func provenanceSidecarURL(for rendered: URL) -> URL {
        let stem = rendered.deletingPathExtension().lastPathComponent
        let parent = rendered.deletingLastPathComponent()
        return parent.appendingPathComponent("\(stem).ro-crate.json")
    }

    /// Write a minimal RO-Crate-compatible JSON-LD sidecar capturing the
    /// `.vsz` source path, rendered output path, format, and timing.
    private static func writeProvenanceSidecar(
        source: URL,
        rendered: URL,
        sidecar: URL,
        format: VeuszPlotRef.ExportFormat,
        elapsedMs: Int
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let creativeWork: [String: Any] = [
            "@id": rendered.lastPathComponent,
            "@type": "CreativeWork",
            "name": source.deletingPathExtension().lastPathComponent,
            "dateCreated": formatter.string(from: Date()),
            "encodingFormat": mimeType(for: format),
            "wasDerivedFrom": [
                "@type": "MediaObject",
                "name": source.lastPathComponent,
                "encodingFormat": "application/x-veusz",
            ],
            "creator": [
                "@type": "SoftwareApplication",
                "name": "Veusz",
            ],
            "duration": "PT\(Double(elapsedMs) / 1000.0)S",
        ]
        let crate: [String: Any] = [
            "@context": "https://w3id.org/ro/crate/1.1/context",
            "@graph": [creativeWork],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: crate,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: sidecar, options: .atomic)
    }

    private static func mimeType(for format: VeuszPlotRef.ExportFormat) -> String {
        switch format {
        case .svg: return "image/svg+xml"
        case .png: return "image/png"
        case .pdf: return "application/pdf"
        }
    }

    // MARK: - Process

    private nonisolated func runProcess(executable: URL, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            // Veusz prints noise to stdout we don't need; redirect to /dev/null.
            process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")

            process.terminationHandler = { proc in
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ExportError.processFailed(
                        exitCode: proc.terminationStatus,
                        stderr: stderr
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
