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

        // Veusz's PDF output has the .vsz page as its MediaBox — even
        // with tight graph margins there's residual whitespace. Trim
        // the PDF to its content bounding box via the pdfcrop helper
        // so `\includegraphics{plot.pdf}` lands without padding around
        // the figure. Best-effort: when pdfcrop isn't installed the
        // helper exits 0 and the untrimmed PDF stays in place.
        if format == .pdf {
            await cropPdfIfPossible(at: normalizedDestination)
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

    /// File name of the Veusz wrapper script we install at
    /// `~/Library/Application Scripts/com.imbib.imprint/`.
    static let unixTaskScriptName = "run-veusz.sh"

    /// File name of the pdfcrop wrapper script installed alongside
    /// `run-veusz.sh`. Runs `pdfcrop` (TeXLive) on a PDF in-place to
    /// trim it to the content bounding box so figures land in LaTeX
    /// `\includegraphics` without surrounding whitespace.
    static let pdfcropScriptName = "run-pdfcrop.sh"

    /// True when the user has granted write access (via `installHelperScript`)
    /// and BOTH wrapper scripts (`run-veusz.sh` and `run-pdfcrop.sh`) are
    /// present + executable at the expected path. The Plots inspector
    /// reads this to show the install banner — if either is missing,
    /// the banner re-prompts for a fresh install.
    static var isHelperScriptInstalled: Bool {
        guard let dir = try? FileManager.default.url(
            for: .applicationScriptsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return false }
        for name in [unixTaskScriptName, pdfcropScriptName] {
            let scriptURL = dir.appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
                return false
            }
            guard let existing = try? String(contentsOf: scriptURL, encoding: .utf8),
                  existing.hasPrefix("#!/usr/bin/env bash") || existing.hasPrefix("#!/bin/bash")
            else { return false }
            // Version marker — bump `imprint-helper-version` in both
            // embedded templates whenever the script logic changes in a
            // way that needs the user to re-install. Older versions
            // miss the marker and trigger a re-install prompt.
            if !existing.contains("imprint-helper-version: \(currentHelperVersion)") {
                return false
            }
        }
        return true
    }

    /// Bump this whenever either embedded helper-script template
    /// changes in a way that requires a re-install (PATH fixes,
    /// stderr-surfacing tweaks, new flags, etc.). The version marker
    /// in both `unixTaskScriptTemplate` and `pdfcropScriptTemplate`
    /// must match this number.
    static let currentHelperVersion: Int = 3

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

        // Granted scope covers everything inside the folder. Write both
        // wrapper scripts + chmod them.
        let veuszScriptURL = granted.appendingPathComponent(unixTaskScriptName)
        let pdfcropScriptURL = granted.appendingPathComponent(pdfcropScriptName)
        let started = granted.startAccessingSecurityScopedResource()
        defer { if started { granted.stopAccessingSecurityScopedResource() } }

        try unixTaskScriptTemplate.write(to: veuszScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: veuszScriptURL.path
        )
        try pdfcropScriptTemplate.write(to: pdfcropScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: pdfcropScriptURL.path
        )
        Logger.veusz.infoCapture(
            "Installed Veusz helpers at \(veuszScriptURL.path) + \(pdfcropScriptURL.path)",
            category: "veusz"
        )
        return veuszScriptURL
    }

    /// Run the Veusz wrapper script via NSUserUnixTask. Convenience
    /// over the script-agnostic `runScriptViaUserUnixTask`.
    private nonisolated func runViaUserUnixTask(arguments: [String]) async throws {
        try await runScriptViaUserUnixTask(
            scriptURL: try resolveUnixTaskScript(),
            arguments: arguments
        )
    }

    /// Resolve the pdfcrop wrapper script. Throws
    /// `helperScriptNotInstalled` when missing (caller treats that as a
    /// no-op skip — pdfcrop is a quality-of-life step, never required).
    private nonisolated func resolvePdfcropScript() throws -> URL {
        guard let dir = try? FileManager.default.url(
            for: .applicationScriptsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            throw ExportError.helperScriptNotInstalled
        }
        let scriptURL = dir.appendingPathComponent(Self.pdfcropScriptName)
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw ExportError.helperScriptNotInstalled
        }
        return scriptURL
    }

    /// Crop the given PDF to its content bounding box in-place via the
    /// pdfcrop wrapper. Best-effort — failures (pdfcrop not installed,
    /// TeXLive missing, file unreadable) log a warning and return; the
    /// uncropped PDF stays in place so the figure still appears in
    /// downstream `\includegraphics`, just with margins.
    ///
    /// The wrapper script ALWAYS exits 0 (it can't tell its caller
    /// what to do on failure without disrupting the render pipeline)
    /// and reports actual status via stderr. We capture that and log
    /// it so we can see whether cropping really happened.
    nonisolated func cropPdfIfPossible(at pdfURL: URL) async {
        do {
            let scriptURL = try resolvePdfcropScript()
            let stderr = try await runScriptViaUserUnixTaskCapturingStderr(
                scriptURL: scriptURL,
                arguments: [pdfURL.path]
            )
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                Logger.veusz.infoCapture(
                    "pdfcrop completed for \(pdfURL.lastPathComponent) (no stderr)",
                    category: "veusz"
                )
            } else if trimmed.contains("cropped ") {
                Logger.veusz.infoCapture(
                    "pdfcrop: \(trimmed)",
                    category: "veusz"
                )
            } else {
                // Any non-success stderr (pdfcrop not found, gs missing,
                // pdfcrop internal error) surfaces here so it's visible
                // in the in-app console + HTTP /api/logs.
                Logger.veusz.warningCapture(
                    "pdfcrop did not trim \(pdfURL.lastPathComponent): \(trimmed)",
                    category: "veusz"
                )
            }
        } catch {
            Logger.veusz.warningCapture(
                "pdfcrop skipped for \(pdfURL.lastPathComponent): \(error.localizedDescription)",
                category: "veusz"
            )
        }
    }

    /// Variant of `runScriptViaUserUnixTask` that returns captured
    /// stderr instead of discarding it. Used by `cropPdfIfPossible`
    /// so the diagnostic line from the wrapper script reaches our
    /// log capture.
    private nonisolated func runScriptViaUserUnixTaskCapturingStderr(
        scriptURL: URL,
        arguments: [String]
    ) async throws -> String {
        let task = try NSUserUnixTask(url: scriptURL)
        let stderrPipe = Pipe()
        task.standardError = stderrPipe.fileHandleForWriting
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
            try? stderrPipe.fileHandleForWriting.close()
            let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let nsErr = error as NSError
            let exitCode: Int32 = (nsErr.userInfo["NSTaskTerminationReason"] as? Int32) ?? Int32(nsErr.code)
            throw ExportError.processFailed(
                exitCode: exitCode,
                stderr: stderrText.isEmpty ? nsErr.localizedDescription : stderrText
            )
        }

        try? stderrPipe.fileHandleForWriting.close()
        let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        return String(data: stderrData, encoding: .utf8) ?? ""
    }

    /// Run an arbitrary user-unix-task script with the given args.
    /// Captures stderr so failures surface a useful message instead of
    /// the raw NSError. Shared by the Veusz + pdfcrop callers.
    private nonisolated func runScriptViaUserUnixTask(
        scriptURL: URL,
        arguments: [String]
    ) async throws {
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
        # imprint-helper-version: 3
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

    /// Embedded template for the pdfcrop wrapper. Trims a PDF to its
    /// content bounding box in-place. Best-effort — exits 0 even on
    /// failure (caller treats absence as a no-op fallback). On
    /// success/failure, writes a diagnostic line to stderr so the
    /// app's log capture can surface what actually happened.
    ///
    /// Why a separate script: pdfcrop needs a different binary than
    /// Veusz (`/Library/TeX/texbin/pdfcrop` vs. Veusz.app) and the
    /// sandbox requires each invocation to go through its own
    /// NSUserUnixTask script for the system to arbitrate exec.
    static let pdfcropScriptTemplate: String = #"""
        #!/usr/bin/env bash
        # imprint-helper-version: 3
        # imprint -> pdfcrop wrapper, invoked via NSUserUnixTask from
        # apps/imprint/macOS/Services/VeuszService.swift after a PDF
        # render to trim the bounding box for clean LaTeX inclusion.
        #
        # Usage: run-pdfcrop.sh <path-to-pdf>
        # Trims the PDF in-place. Exits 0 unconditionally; diagnostic
        # output on stderr.

        set -u

        if [ -z "${1:-}" ]; then
            echo "run-pdfcrop.sh: missing PDF path argument" >&2
            exit 64
        fi
        target="$1"

        # NSUserUnixTask environments don't inherit /usr/local/bin etc., so
        # pdfcrop's internal `gs` lookup fails by default on macOS unless we
        # extend PATH ourselves to the standard install locations.
        export PATH="/Library/TeX/texbin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"

        pdfcrop_bin=""
        for bin in \
            "/Library/TeX/texbin/pdfcrop" \
            "/usr/local/texlive/2025/bin/universal-darwin/pdfcrop" \
            "/usr/local/texlive/2024/bin/universal-darwin/pdfcrop" \
            "/opt/homebrew/bin/pdfcrop"; do
            if [ -x "$bin" ]; then
                pdfcrop_bin="$bin"
                break
            fi
        done

        if [ -z "$pdfcrop_bin" ]; then
            echo "run-pdfcrop.sh: pdfcrop not found on system; leaving PDF untrimmed" >&2
            exit 0
        fi

        # pdfcrop calls Ghostscript internally; verify it's reachable so
        # we report a clear "gs missing" diagnostic instead of letting
        # pdfcrop fail with a cryptic error.
        if ! command -v gs >/dev/null 2>&1; then
            echo "run-pdfcrop.sh: ghostscript (gs) not on PATH (=$PATH); install gs or pdfcrop will fail" >&2
            exit 0
        fi

        # pdfcrop refuses to write input==output. Use a temp file then mv.
        tmpdir=$(mktemp -d)
        trap 'rm -rf "$tmpdir"' EXIT
        cropped="$tmpdir/cropped.pdf"

        orig_size=$(stat -f%z "$target" 2>/dev/null || echo 0)

        # pdfcrop creates a hardlink in its CWD to the input PDF (so
        # ghostscript can process it). NSUserUnixTask launches us with
        # a CWD that's read-only inside the sandbox — see the previous
        # error "tmp-pdfcrop-NNNN-img.pdf failed (Read-only file system)".
        # cd into the writable tmpdir so the hardlink lands there.
        cd "$tmpdir"

        # `--margins 2` adds 2bp (≈0.7mm) padding so labels at the edge
        # don't kiss the crop boundary in print. `--hires` computes the
        # bounding box at higher precision (matters for tight crops
        # around small text labels). Capture stderr so failures surface
        # in app logs instead of being swallowed.
        pdfcrop_stderr=$("$pdfcrop_bin" --hires --margins 2 "$target" "$cropped" 2>&1 >/dev/null) || pdfcrop_status=$?
        : "${pdfcrop_status:=0}"

        if [ "$pdfcrop_status" -ne 0 ] || [ ! -s "$cropped" ]; then
            echo "run-pdfcrop.sh: pdfcrop failed (exit $pdfcrop_status). stderr: $pdfcrop_stderr" >&2
            exit 0
        fi

        new_size=$(stat -f%z "$cropped" 2>/dev/null || echo 0)
        mv "$cropped" "$target"
        echo "run-pdfcrop.sh: cropped $target ($orig_size B → $new_size B)" >&2
        exit 0
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
