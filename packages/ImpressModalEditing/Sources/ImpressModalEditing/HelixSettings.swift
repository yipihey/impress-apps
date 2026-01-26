import Foundation
import Combine

/// Per-app settings manager for Helix modal editing.
///
/// Each app creates its own instance with a configurable key prefix, storing
/// settings in local UserDefaults. This allows independent configuration per app.
///
/// Example usage:
/// ```swift
/// @StateObject private var helixSettings = HelixSettings(keyPrefix: "imprint.helix")
/// ```
@MainActor
public final class HelixSettings: ObservableObject {
    /// The UserDefaults suite used for settings storage.
    private let defaults: UserDefaults

    /// Key prefix for this instance's settings.
    private let keyPrefix: String

    /// UserDefaults key for the Helix enabled setting.
    private var helixModeEnabledKey: String {
        "\(keyPrefix).isEnabled"
    }

    /// Whether Helix modal editing is enabled.
    ///
    /// When `true`, text views use Helix-style modal editing (Normal/Insert/Select modes).
    /// When `false`, text views use standard platform text editing behavior.
    ///
    /// Defaults to `true` for new installations.
    @Published public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: helixModeEnabledKey)
        }
    }

    /// Publisher that emits when the setting changes.
    public var isEnabledPublisher: AnyPublisher<Bool, Never> {
        $isEnabled.eraseToAnyPublisher()
    }

    /// Create a new HelixSettings instance.
    ///
    /// - Parameters:
    ///   - keyPrefix: Prefix for UserDefaults keys (e.g., "imprint.helix", "implore.helix").
    ///                Defaults to "helix" for backward compatibility.
    ///   - defaults: UserDefaults instance to use. Defaults to `.standard`.
    public init(keyPrefix: String = "helix", defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix

        let key = "\(keyPrefix).isEnabled"
        // Read initial value, defaulting to true (Helix enabled)
        if defaults.object(forKey: key) != nil {
            self.isEnabled = defaults.bool(forKey: key)
        } else {
            // First launch: default to enabled
            self.isEnabled = true
            defaults.set(true, forKey: key)
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
