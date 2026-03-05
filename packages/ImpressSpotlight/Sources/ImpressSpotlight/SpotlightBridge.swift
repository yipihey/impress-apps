import Foundation

/// Holds a long-lived reference to the per-app `SpotlightSyncCoordinator`.
///
/// Each app sets this once during startup. Without this, the coordinator
/// would be deallocated when the startup Task completes, silently breaking
/// all incremental Spotlight updates.
@MainActor
public final class SpotlightBridge {
    public static let shared = SpotlightBridge()

    public private(set) var coordinator: SpotlightSyncCoordinator?

    private init() {}

    public func setCoordinator(_ coordinator: SpotlightSyncCoordinator) {
        self.coordinator = coordinator
    }
}
