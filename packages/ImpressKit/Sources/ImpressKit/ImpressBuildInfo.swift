//
//  ImpressBuildInfo.swift
//  ImpressKit
//
//  What binary am I actually running?
//
//  Every app in the suite self-installs its Debug build to ~/Applications so
//  Spotlight opens the newest one, and a session can leave several builds and
//  several running instances behind. When a bug then behaves differently from
//  the source, the first question is always "is this app even the code I just
//  built?" — and until now the only way to answer it was `stat` on the
//  executable from a terminal. That is a question the app should answer about
//  itself, in the place every macOS app already offers: About.
//
//  The build stamp is the EXECUTABLE'S modification date. There is no compile
//  timestamp in a Swift binary, and injecting one at build time would make
//  every build dirty; the executable's mtime is written when the linker (and
//  then codesign) finishes, so it IS the build time, to the second, with no
//  build-system machinery to keep in step. `ditto` — which the self-install
//  script phase uses — preserves it, so the copy in ~/Applications reports
//  when it was BUILT, not when it was copied.
//

import Foundation

#if os(macOS)
import AppKit
import SwiftUI
#endif

/// Identity of the running binary: version, build, and when it was built.
public enum ImpressBuildInfo {

    /// The app's marketing version (`CFBundleShortVersionString`).
    public static var version: String {
        info("CFBundleShortVersionString") ?? "—"
    }

    /// The build number (`CFBundleVersion`).
    public static var build: String {
        info("CFBundleVersion") ?? "—"
    }

    /// The bundle's display name, for titles that must match the app.
    public static var appName: String {
        info("CFBundleDisplayName") ?? info("CFBundleName") ?? ProcessInfo.processInfo.processName
    }

    /// An optional commit stamp, for anyone who later injects
    /// `ImpressGitCommit` into Info.plist at build time. Absent by default —
    /// the build date is what catches a stale binary.
    public static var commit: String? {
        info("ImpressGitCommit").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// When this binary was built — the executable's modification date.
    ///
    /// Falls back to the bundle directory when the executable cannot be
    /// stat'd (a sandbox denial, an unusual packaging), and is nil only if
    /// neither can be read.
    public static let buildDate: Date? = {
        let candidates = [Bundle.main.executableURL, Bundle.main.bundleURL].compactMap { $0 }
        for url in candidates {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                let modified = attributes[.modificationDate] as? Date {
                return modified
            }
        }
        return nil
    }()

    /// The build date in the user's locale, or "unknown".
    public static var formattedBuildDate: String {
        guard let buildDate else { return "unknown" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: buildDate)
    }

    /// How old this binary is, in a form that makes a stale one obvious
    /// ("today at 11:42" reads very differently from "18 days ago").
    public static var buildAge: String? {
        guard let buildDate else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: buildDate, relativeTo: Date())
    }

    /// One line for a log, a status endpoint, or a bug report:
    /// `imprint 1.0 (1) — built 30 Aug 2026 at 11:42 (2 minutes ago)`.
    public static var summary: String {
        var line = "\(appName) \(version) (\(build)) — built \(formattedBuildDate)"
        if let buildAge { line += " (\(buildAge))" }
        if let commit { line += " [\(commit)]" }
        return line
    }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}

#if os(macOS)
extension ImpressBuildInfo {

    /// Show the standard About panel with the build stamp in its credits.
    ///
    /// The standard panel is deliberate: it keeps the icon, name, version and
    /// copyright macOS already renders, and adds only the line the suite was
    /// missing.
    @MainActor
    public static func showAboutPanel() {
        var credits = "Built \(formattedBuildDate)"
        if let buildAge { credits += "\n\(buildAge.prefix(1).uppercased() + buildAge.dropFirst())" }
        if let commit { credits += "\nCommit \(commit)" }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(
            string: credits,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])

        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: attributed])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// The About menu item, for every app's `.commands`.
///
/// Replaces the default `.appInfo` group so "About <app>" opens the standard
/// panel WITH the build stamp. The title is read from the bundle, so an app
/// never restates its own name (and never gets it wrong).
public struct ImpressAboutCommand: Commands {

    private let appName: String

    /// - Parameter appName: override only if the menu title must differ from
    ///   the bundle's display name.
    public init(appName: String? = nil) {
        self.appName = appName ?? ImpressBuildInfo.appName
    }

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(appName)") {
                ImpressBuildInfo.showAboutPanel()
            }
        }
    }
}
#endif
