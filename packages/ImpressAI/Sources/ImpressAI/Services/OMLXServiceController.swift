import Foundation
import ImpressLogging

#if os(macOS)
import AppKit
import Darwin
#endif

/// Errors produced while handing local inference startup to oMLX.app.
public enum OMLXServiceControllerError: LocalizedError, Sendable {
    case applicationNotInstalled
    case controlUnavailable(String)
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .applicationNotInstalled:
            return "oMLX.app is not installed or registered with Launch Services"
        case .controlUnavailable(let detail):
            return "Could not ask oMLX.app to start its managed server: \(detail)"
        case .unsupportedPlatform:
            return "oMLX can only be started automatically on macOS"
        }
    }
}

/// The Swift half of starting oMLX: opening the companion app through Launch
/// Services when Rust reports that its control socket is absent. The control
/// protocol (`{"command":"start"}` over `~/Library/Application Support/oMLX/
/// control.sock`), the loopback-8000 policy and the readiness wait live in
/// Rust (`impress_ai::omlx_control`); this actor only asks Launch Services to
/// open the app, and coalesces concurrent requests in one process into a
/// single launch. Launch Services and oMLX make repeat launches across sibling
/// app processes idempotent.
public actor OMLXServiceController: AIHostLaunching {
    public static let shared = OMLXServiceController()

    public typealias LaunchAction = @Sendable () async throws -> Void

    private let launchAction: LaunchAction
    private var launchTask: Task<Void, Error>?

    /// Creates the production controller backed by Launch Services.
    public init() {
        launchAction = { @Sendable in
            try await Self.launchInstalledApplication()
        }
    }

    /// Creates a controller with an injected launcher, primarily for tests.
    public init(launchAction: @escaping LaunchAction) {
        self.launchAction = launchAction
    }

    /// The oMLX companion app.
    public static let bundleIdentifier = "app.omlx"

    /// `AIHostLaunching`: launch the companion app. Concurrent callers join
    /// the in-flight launch instead of opening the app twice.
    public func launchApplication(bundleId: String) async throws {
        guard bundleId == Self.bundleIdentifier else {
            throw OMLXServiceControllerError.controlUnavailable("unsupported companion application \(bundleId)")
        }
        if let launchTask {
            logInfo("Joining an in-flight oMLX launch request", category: "ai.local-service")
            try await launchTask.value
            return
        }
        let launchAction = self.launchAction
        let task = Task { try await launchAction() }
        launchTask = task
        do {
            logInfo("Launching \(bundleId) through Launch Services", category: "ai.local-service")
            try await task.value
            launchTask = nil
            logInfo("Launch Services accepted the oMLX launch request", category: "ai.local-service")
        } catch {
            launchTask = nil
            logError("oMLX launch failed: \(error.localizedDescription)", category: "ai.local-service")
            throw error
        }
    }

    @MainActor
    private static func launchInstalledApplication() async throws {
        #if os(macOS)
        let registeredURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.omlx")
        let applicationURL = registeredURL ?? fallbackApplicationURLs().first(where: isOMLXApplication)
        guard let applicationURL else {
            throw OMLXServiceControllerError.applicationNotInstalled
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        )
        #else
        throw OMLXServiceControllerError.unsupportedPlatform
        #endif
    }

    #if os(macOS)
    private nonisolated static func fallbackApplicationURLs() -> [URL] {
        guard let passwordEntry = getpwuid(getuid()),
              let homePointer = passwordEntry.pointee.pw_dir
        else { return [URL(fileURLWithPath: "/Applications/oMLX.app")] }

        let home = URL(fileURLWithPath: String(cString: homePointer), isDirectory: true)
        return [
            URL(fileURLWithPath: "/Applications/oMLX.app", isDirectory: true),
            home.appendingPathComponent("Applications/oMLX.app", isDirectory: true),
            home.appendingPathComponent("MyApplications/oMLX.app", isDirectory: true),
        ]
    }

    private nonisolated static func isOMLXApplication(_ url: URL) -> Bool {
        Bundle(url: url)?.bundleIdentifier == "app.omlx"
    }
    #endif
}
