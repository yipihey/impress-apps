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
        case helperScriptNotInstalled

        var errorDescription: String? {
            switch self {
            case .veuszNotInstalled:
                return "Veusz is not installed. Install Veusz.app in /Applications (or ~/MyApplications) to render plots."
            case .sourceFileMissing(let url):
                return "Veusz source file not found: \(url.path)"
            case .processFailed(let code, let stderr):
                let tail = stderr.split(separator: "\n").suffix(5).joined(separator: "\n")
                return "Veusz export failed (exit \(code)): \(tail)"
            case .outputNotProduced(let url):
                return "Veusz exited successfully but did not produce \(url.lastPathComponent)."
            case .helperScriptNotInstalled:
                return "Imprint needs a one-time grant to install the Veusz helper script. Open Settings → Veusz, click \"Install Helper\", and pick the suggested folder when the panel appears."
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

        // The sandbox blocks Process.run() on arbitrary user-installed
        // binaries — even when locateExecutable() confirms the file exists,
        // direct subprocess spawn fails with "file doesn't exist" because
        // the sandbox filters the path during exec. NSUserUnixTask is
        // Apple's blessed escape hatch: the wrapper script lives outside
        // the sandbox in ~/Library/Application Scripts/<bundle-id>/ and
        // the system arbitrates its invocation. (See VeuszService+UnixTask
        // for the install + invoke logic.)
        _ = executable  // retained for the install banner; actual exec goes via NSUserUnixTask

        let started = Date()
        try await runViaUserUnixTask(
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

    // MARK: - NSUserUnixTask invocation

    /// File name of the wrapper script we install at
    /// `~/Library/Application Scripts/com.imbib.imprint/`.
    static let unixTaskScriptName = "run-veusz.sh"

    /// True when the user has granted write access (via `installHelperScript`)
    /// and the wrapper script is present + executable at the expected path.
    /// The Plots inspector reads this to show the install banner.
    static var isHelperScriptInstalled: Bool {
        guard let dir = try? FileManager.default.url(
            for: .applicationScriptsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return false }
        let scriptURL = dir.appendingPathComponent(unixTaskScriptName)
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else { return false }
        // Treat presence-with-correct-prefix as installed. We don't require
        // byte-exact match against the template so a user-customised wrapper
        // continues to satisfy the check.
        if let existing = try? String(contentsOf: scriptURL, encoding: .utf8),
           existing.hasPrefix("#!/usr/bin/env bash") || existing.hasPrefix("#!/bin/bash") {
            return true
        }
        return false
    }

    /// Resolve the URL of the user-unix-task wrapper script. The script
    /// lives in the App-Scripts container, which is sandbox-exempt for
    /// *execution* but NOT for writes (Apple security boundary). Writing
    /// requires the one-time user grant via `installHelperScript`.
    ///
    /// Returns the absolute URL of an installed script — or throws
    /// `ExportError.helperScriptNotInstalled` when missing.
    private nonisolated func resolveUnixTaskScript() throws -> URL {
        guard let dir = try? FileManager.default.url(
            for: .applicationScriptsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            throw ExportError.helperScriptNotInstalled
        }
        let scriptURL = dir.appendingPathComponent(Self.unixTaskScriptName)
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw ExportError.helperScriptNotInstalled
        }
        return scriptURL
    }

    /// Install the wrapper script via a user-granted NSOpenPanel.
    ///
    /// Called from the Plots panel "Install Helper" button. NSSavePanel
    /// proved unreliable on macOS 26 — `directoryURL` was sometimes
    /// ignored for sandbox-restricted folders, and the script ended up in
    /// the wrong place. Switching to NSOpenPanel pointed at the *parent*
    /// (`~/Library/Application Scripts/`) and asking the user to click
    /// the bundle-id folder is two clicks but unambiguous: the only valid
    /// target is the `com.imbib.imprint` folder.
    ///
    /// Returns the installed script's URL on success, or nil if the user
    /// cancelled. Throws when the user picks the wrong folder.
    @MainActor
    static func installHelperScript() async throws -> URL? {
        let scriptsDir = try FileManager.default.url(
            for: .applicationScriptsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let parent = scriptsDir.deletingLastPathComponent()
        let bundleFolderName = scriptsDir.lastPathComponent

        let panel = NSOpenPanel()
        panel.title = "Install Veusz Helper"
        panel.message = "Click the folder named \"\(bundleFolderName)\" below, then click \"Grant Access\". The script will be installed inside that folder."
        panel.prompt = "Grant Access"
        panel.directoryURL = parent
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.showsHiddenFiles = false

        let response = await panel.beginAsync()
        guard response == .OK, let granted = panel.url else {
            Logger.veusz.infoCapture("Helper install cancelled by user", category: "veusz")
            return nil
        }

        let chosen = granted.standardizedFileURL
        let expected = scriptsDir.standardizedFileURL

        if chosen != expected {
            Logger.veusz.warningCapture(
                "Helper install: chosen folder \(chosen.path) does not match expected \(expected.path) — install rejected",
                category: "veusz"
            )
            throw ExportError.processFailed(
                exitCode: -1,
                stderr: "Wrong folder. Please click 'Install Helper…' again and select the folder named \"\(bundleFolderName)\" (no other folder is valid)."
            )
        }

        // Granted scope covers everything inside the folder. Write the
        // script + chmod it.
        let scriptURL = granted.appendingPathComponent(unixTaskScriptName)
        let started = granted.startAccessingSecurityScopedResource()
        defer { if started { granted.stopAccessingSecurityScopedResource() } }

        try unixTaskScriptTemplate.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        Logger.veusz.infoCapture("Installed Veusz helper at \(scriptURL.path)", category: "veusz")
        return scriptURL
    }

    /// Run the Veusz wrapper script via NSUserUnixTask. Captures stderr so
    /// failures surface a useful message instead of the raw NSError.
    private nonisolated func runViaUserUnixTask(arguments: [String]) async throws {
        let scriptURL = try resolveUnixTaskScript()
        let task = try NSUserUnixTask(url: scriptURL)

        let stderrPipe = Pipe()
        task.standardError = stderrPipe.fileHandleForWriting
        // We don't need Veusz's chatty stdout; route it to /dev/null. If
        // /dev/null open fails (vanishingly unlikely), fall back to leaving
        // stdout unset (inherits from the parent — fine).
        task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.execute(withArguments: arguments) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            // Drain stderr so the error message includes the wrapper +
            // veusz's complaint instead of just "exit 1".
            try? stderrPipe.fileHandleForWriting.close()
            let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // NSUserUnixTask reports the non-zero exit as NSError with
            // userInfo[NSUserScriptTaskNameKey] etc. Surface the exit code
            // when we can extract it; otherwise use the underlying domain/code.
            let nsErr = error as NSError
            let exitCode: Int32 = (nsErr.userInfo["NSTaskTerminationReason"] as? Int32) ?? Int32(nsErr.code)
            throw ExportError.processFailed(
                exitCode: exitCode,
                stderr: stderrText.isEmpty ? nsErr.localizedDescription : stderrText
            )
        }

        // Drain stderr (and close) on success too — leftover open handles
        // can stall the next render.
        try? stderrPipe.fileHandleForWriting.close()
        _ = try? stderrPipe.fileHandleForReading.readToEnd()
    }

    /// Embedded template for the NSUserUnixTask wrapper. We carry it inline
    /// so the install path doesn't depend on any repo-relative file.
    ///
    /// Searches the well-known Veusz install locations, exec's the binary
    /// with the caller's verbatim arguments. Falls back with a clear stderr
    /// message + exit 127 when Veusz is genuinely missing.
    static let unixTaskScriptTemplate: String = #"""
        #!/usr/bin/env bash
        # imprint -> Veusz wrapper, invoked via NSUserUnixTask from
        # apps/imprint/macOS/Services/VeuszService.swift. Sandboxed imprint
        # can't spawn arbitrary user-installed binaries directly; it relies
        # on this script (living outside the sandbox under
        # ~/Library/Application Scripts/com.imbib.imprint/) to do it.
        #
        # The script is auto-installed on first VeuszService call. If you
        # need to customise the Veusz lookup, fork this file under a
        # different name; imprint overwrites this one to match the embedded
        # template whenever it drifts.
        #
        # All arguments are passed through verbatim to veusz.exe.

        set -u

        for app in \
            "/Applications/Veusz.app" \
            "$HOME/Applications/Veusz.app" \
            "$HOME/MyApplications/Veusz.app"; do
            if [ -x "$app/Contents/MacOS/veusz.exe" ]; then
                exec "$app/Contents/MacOS/veusz.exe" "$@"
            fi
        done

        echo "run-veusz.sh: Veusz.app not found at /Applications, ~/Applications, or ~/MyApplications" >&2
        exit 127
        """#
}

// MARK: - NSOpenPanel async helper

private extension NSSavePanel {
    /// Modal-but-async wrapper around `begin(completionHandler:)`. The
    /// returned `NSApplication.ModalResponse` matches the panel's response.
    /// Extension is on `NSSavePanel` so both Open and Save panels get it
    /// (NSOpenPanel inherits from NSSavePanel).
    @MainActor
    func beginAsync() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            begin { response in
                continuation.resume(returning: response)
            }
        }
    }
}
