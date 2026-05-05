import Foundation
import ImpressLogging
import OSLog
#if canImport(AppKit)
import AppKit
#endif

/// Manages the lifecycle of the impress-toolbox server.
///
/// Auto-launches the toolbox binary on app startup if it's not already running.
/// Uses NSWorkspace.open to work from within the app sandbox.
public final class ToolboxLifecycle: Sendable {
    public static let shared = ToolboxLifecycle()

    /// Check if the server is running and reachable.
    public func isRunning() async -> Bool {
        await ToolboxClient.shared.isAvailable()
    }

    /// Ensure the toolbox is running. If not, launch it via NSUserUnixTask
    /// from ~/Library/Application Scripts/ (the sandbox-approved way to run
    /// user-installed helper scripts/binaries).
    ///
    /// **First-time setup**: The user must place (or symlink) `impress-toolbox`
    /// into `~/Library/Application Scripts/com.imbib.imprint/`. imprint will
    /// create this directory and offer to install the binary on first launch
    /// if the toolbox is found elsewhere.
    public func ensureRunning() async {
        if await isRunning() {
            logInfo("impress-toolbox already running", category: "toolbox")
            return
        }

        #if os(macOS)
        guard let scriptURL = applicationScriptsURL() else {
            logInfo("Application Scripts directory unavailable", category: "toolbox")
            return
        }

        let toolboxScript = scriptURL.appendingPathComponent("impress-toolbox")

        if !FileManager.default.isExecutableFile(atPath: toolboxScript.path) {
            logInfo("impress-toolbox not found in Application Scripts (\(scriptURL.path)). Install with: ln -s $(which impress-toolbox) '\(scriptURL.path)/impress-toolbox'", category: "toolbox")
            // Try to create the directory so the user just needs to add the symlink
            try? FileManager.default.createDirectory(at: scriptURL, withIntermediateDirectories: true)
            return
        }

        logInfo("Launching impress-toolbox via NSUserUnixTask", category: "toolbox")

        do {
            let task = try NSUserUnixTask(url: toolboxScript)
            task.execute(withArguments: nil) { error in
                if let error = error {
                    logInfo("NSUserUnixTask failed: \(error.localizedDescription)", category: "toolbox")
                }
            }
        } catch {
            logInfo("Cannot create NSUserUnixTask: \(error.localizedDescription)", category: "toolbox")
            return
        }

        // Wait for server to be ready
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(200))
            if await isRunning() {
                logInfo("impress-toolbox is ready (via Application Scripts)", category: "toolbox")
                return
            }
        }
        logInfo("impress-toolbox launched but not yet responding", category: "toolbox")
        #endif
    }

    #if os(macOS)
    /// The Application Scripts directory for imprint (sandbox-approved for NSUserUnixTask).
    private func applicationScriptsURL() -> URL? {
        // com.imbib.imprint is imprint's bundle ID
        let urls = FileManager.default.urls(for: .applicationScriptsDirectory, in: .userDomainMask)
        return urls.first
    }
    #endif

    /// Instructions for the user to install the server.
    public static let startInstructions = """
    Install the impress-toolbox server:
      cargo install --path crates/impress-toolbox
    It will be auto-launched when needed.
    """

    /// The expected binary name.
    public static let binaryName = "impress-toolbox"

    /// The app group container directory for the toolbox binary.
    public static var appGroupBinaryURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.impress.suite")?
            .appendingPathComponent("bin/impress-toolbox")
    }

    /// Search for the toolbox binary.
    ///
    /// From within the sandbox, only the app group container is accessible.
    /// Use `ToolboxLifecycle.installToAppGroup(from:)` to stage the binary.
    public func findBinary() -> URL? {
        // App group container (sandbox-accessible)
        if let groupURL = Self.appGroupBinaryURL,
           FileManager.default.isExecutableFile(atPath: groupURL.path) {
            return groupURL
        }

        // Unsandboxed paths (work during development without sandbox)
        let searchPaths = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cargo/bin/impress-toolbox"),
            URL(fileURLWithPath: "/opt/homebrew/bin/impress-toolbox"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/impress-toolbox"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Projects/impress-apps/target/release/impress-toolbox"),
        ]

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path.path) {
                return path
            }
        }
        return nil
    }

    /// Copy the toolbox binary into the shared app group container so sandboxed
    /// apps can find and launch it. Call from an unsandboxed context (e.g., cargo
    /// post-build script, or a setup command).
    public static func installToAppGroup(from sourcePath: URL) throws {
        guard let dest = appGroupBinaryURL else {
            throw NSError(domain: "ToolboxLifecycle", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "App group container unavailable"])
        }
        let binDir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourcePath, to: dest)
    }
}
