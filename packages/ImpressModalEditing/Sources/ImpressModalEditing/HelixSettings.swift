import Foundation
import Combine

/// Shared settings manager for Helix modal editing across the Impress suite.
///
/// Uses App Group shared UserDefaults for cross-app synchronization on iOS/macOS.
/// Falls back to standard UserDefaults if App Group is unavailable.
@MainActor
public final class HelixSettings: ObservableObject {
    /// Shared singleton instance.
    public static let shared = HelixSettings()

    /// The UserDefaults suite used for settings storage.
    private let defaults: UserDefaults

    /// UserDefaults key for the Helix enabled setting.
    private static let helixModeEnabledKey = "helixModeEnabled"

    /// App Group identifier for cross-app settings synchronization.
    private static let appGroupIdentifier = "group.com.impress.shared"

    /// Whether Helix modal editing is enabled.
    ///
    /// When `true`, text views use Helix-style modal editing (Normal/Insert/Select modes).
    /// When `false`, text views use standard platform text editing behavior.
    ///
    /// Defaults to `true` for new installations.
    @Published public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.helixModeEnabledKey)
        }
    }

    /// Publisher that emits when the setting changes.
    public var isEnabledPublisher: AnyPublisher<Bool, Never> {
        $isEnabled.eraseToAnyPublisher()
    }

    private init() {
        // Try to use App Group UserDefaults for cross-app sync, fall back to standard
        self.defaults = UserDefaults(suiteName: Self.appGroupIdentifier) ?? .standard

        // Read initial value, defaulting to true (Helix enabled)
        if defaults.object(forKey: Self.helixModeEnabledKey) != nil {
            self.isEnabled = defaults.bool(forKey: Self.helixModeEnabledKey)
        } else {
            // First launch: default to enabled
            self.isEnabled = true
            defaults.set(true, forKey: Self.helixModeEnabledKey)
        }
    }

    /// Toggle the Helix editing mode on or off.
    public func toggle() {
        isEnabled.toggle()
    }

    /// Reset to default settings (Helix enabled).
    public func resetToDefaults() {
        isEnabled = true
    }
}
