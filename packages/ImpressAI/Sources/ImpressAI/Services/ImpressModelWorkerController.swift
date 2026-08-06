import Foundation
import ImpressLogging

/// Starts the signed `impel-taskd` executable from this app's sandbox-approved
/// Application Scripts directory. Worker health itself comes from the Rust
/// heartbeat protocol; this type is only the macOS process-launch adapter.
public protocol ImpressModelWorkerStarting: Sendable {
    func startWorker() async throws
}

public enum ImpressModelWorkerControllerError: LocalizedError, Sendable {
    case notInstalled(String)
    case launchFailed(String)
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let path):
            return "The Impress model worker is not installed at \(path)"
        case .launchFailed(let detail):
            return "Could not start the Impress model worker: \(detail)"
        case .unsupportedPlatform:
            return "The Impress model worker runs on macOS or a configured server"
        }
    }
}

public actor ImpressModelWorkerController: ImpressModelWorkerStarting {
    public static let shared = ImpressModelWorkerController()

    public typealias LaunchAction = @Sendable () throws -> Void

    private let launchAction: LaunchAction
    private var launchTask: Task<Void, Error>?

    public init() {
        launchAction = { @Sendable in
            try Self.launchInstalledWorker()
        }
    }

    public init(launchAction: @escaping LaunchAction) {
        self.launchAction = launchAction
    }

    public func startWorker() async throws {
        if let launchTask {
            try await launchTask.value
            return
        }

        let launchAction = self.launchAction
        let task = Task { try launchAction() }
        launchTask = task
        do {
            logInfo("Requesting Impress model worker startup", category: "ai.worker")
            try await task.value
            launchTask = nil
            logInfo("Impress model worker launch accepted", category: "ai.worker")
        } catch {
            launchTask = nil
            logError(
                "Impress model worker launch failed: \(error.localizedDescription)",
                category: "ai.worker")
            throw error
        }
    }

    public nonisolated static var installationURL: URL? {
        #if os(macOS)
        FileManager.default
            .urls(for: .applicationScriptsDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("impel-taskd", isDirectory: false)
        #else
        nil
        #endif
    }

    public nonisolated static var isInstalled: Bool {
        guard let installationURL else { return false }
        return FileManager.default.isExecutableFile(atPath: installationURL.path)
    }

    private nonisolated static func launchInstalledWorker() throws {
        #if os(macOS)
        guard let installationURL else {
            throw ImpressModelWorkerControllerError.launchFailed(
                "Application Scripts directory is unavailable")
        }
        guard FileManager.default.isExecutableFile(atPath: installationURL.path) else {
            throw ImpressModelWorkerControllerError.notInstalled(installationURL.path)
        }
        do {
            let task = try NSUserUnixTask(url: installationURL)
            task.execute(withArguments: ["--enable"]) { error in
                if let error {
                    logError(
                        "Impress model worker exited: \(error.localizedDescription)",
                        category: "ai.worker")
                }
            }
        } catch {
            throw ImpressModelWorkerControllerError.launchFailed(error.localizedDescription)
        }
        #else
        throw ImpressModelWorkerControllerError.unsupportedPlatform
        #endif
    }
}
