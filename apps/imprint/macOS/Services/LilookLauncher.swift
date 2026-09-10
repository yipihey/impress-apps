//
//  LilookLauncher.swift
//  imprint
//
//  Opens a lilaq figure in lilook (https://github.com/yipihey/lilook) — a
//  separate application whose model IS the `.typ` file, so the working copy
//  the Plots panel writes is exactly what it edits. Found on PATH or in the
//  Homebrew prefix; `lilook.app` when one is installed.
//

import AppKit
import Foundation
import ImpressLogging
import OSLog

enum LilookLauncher {
    /// The `lilook-app` (or `lilook`) executable, if installed.
    static var executable: URL? {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.lilook.app") {
            return app
        }
        let candidates = [
            "/opt/homebrew/bin/lilook-app", "/opt/homebrew/bin/lilook",
            "/usr/local/bin/lilook-app", "/usr/local/bin/lilook",
            NSString(string: "~/.cargo/bin/lilook-app").expandingTildeInPath,
        ]
        return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Launch lilook on `url`. Returns whether it started.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard let exe = executable else { return false }
        if exe.pathExtension == "app" {
            NSWorkspace.shared.open([url], withApplicationAt: exe, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    Logger.library.warningCapture("lilook: \(error.localizedDescription)", category: "manuscripts")
                }
            }
            return true
        }
        let process = Process()
        process.executableURL = exe
        process.arguments = [url.path]
        process.currentDirectoryURL = url.deletingLastPathComponent()
        do {
            try process.run()
            Logger.library.infoCapture("lilook: opened \(url.lastPathComponent) with \(exe.path)", category: "manuscripts")
            return true
        } catch {
            Logger.library.warningCapture("lilook: could not launch \(exe.path): \(error.localizedDescription)", category: "manuscripts")
            return false
        }
    }
}
