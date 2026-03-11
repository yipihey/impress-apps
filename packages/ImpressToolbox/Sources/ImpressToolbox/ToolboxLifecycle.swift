import Foundation
import ImpressLogging
import OSLog

/// Manages the lifecycle of the impress-toolbox server.
///
/// v1: User runs the server manually or via cargo. The app checks availability
/// and shows guidance in Settings if unavailable.
///
/// v2 (future): LaunchAgent auto-start.
/// v3 (future): Bundled helper binary.
public final class ToolboxLifecycle: Sendable {
    public static let shared = ToolboxLifecycle()

    /// Check if the server is running and reachable.
    public func isRunning() async -> Bool {
        await ToolboxClient.shared.isAvailable()
    }

    /// Instructions for the user to start the server.
    public static let startInstructions = """
    Start the impress-toolbox server:
      cargo run --bin impress-toolbox
    Or install it:
      cargo install --path crates/impress-toolbox
      impress-toolbox
    """

    /// The expected binary name.
    public static let binaryName = "impress-toolbox"

    /// Search for the toolbox binary in common locations.
    public func findBinary() -> URL? {
        let searchPaths = [
            // Cargo install target
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cargo/bin/impress-toolbox"),
            // Homebrew
            URL(fileURLWithPath: "/opt/homebrew/bin/impress-toolbox"),
            // Local bin
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/impress-toolbox"),
        ]

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path.path) {
                return path
            }
        }
        return nil
    }
}
