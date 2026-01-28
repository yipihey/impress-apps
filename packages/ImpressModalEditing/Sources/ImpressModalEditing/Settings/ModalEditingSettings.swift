import Foundation
import Combine

/// Cross-app settings manager for modal editing.
///
/// Uses App Group UserDefaults (`group.com.impress.apps`) for shared preferences
/// across all Impress suite apps (imbib, imprint, implore).
///
/// Example usage:
/// ```swift
/// @StateObject private var settings = ModalEditingSettings.shared
///
/// Toggle("Modal editing", isOn: $settings.isEnabled)
/// Picker("Style", selection: $settings.selectedStyle) { ... }
/// ```
@MainActor
public final class ModalEditingSettings: ObservableObject {
    /// Shared instance using App Group storage.
    public static let shared = ModalEditingSettings()

    /// App Group identifier for cross-app settings sync.
    public static let appGroupIdentifier = "group.com.impress.apps"

    /// UserDefaults keys.
    private enum Keys {
        static let isEnabled = "modalEditing.isEnabled"
        static let selectedStyle = "modalEditing.selectedStyle"
        static let showModeIndicator = "modalEditing.showModeIndicator"
        static let modeIndicatorPosition = "modalEditing.modeIndicatorPosition"
    }

    /// The UserDefaults suite (App Group or standard).
    private let defaults: UserDefaults

    /// Whether modal editing is enabled.
    @Published public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.isEnabled)
        }
    }

    /// The currently selected editor style.
    @Published public var selectedStyle: EditorStyleIdentifier {
        didSet {
            defaults.set(selectedStyle.rawValue, forKey: Keys.selectedStyle)
        }
    }

    /// Whether to show the mode indicator overlay.
    @Published public var showModeIndicator: Bool {
        didSet {
            defaults.set(showModeIndicator, forKey: Keys.showModeIndicator)
        }
    }

    /// Position of the mode indicator.
    @Published public var modeIndicatorPosition: ModeIndicatorPosition {
        didSet {
            defaults.set(modeIndicatorPosition.rawValue, forKey: Keys.modeIndicatorPosition)
        }
    }

    /// Publisher for when any setting changes.
    public var settingsChangedPublisher: AnyPublisher<Void, Never> {
        Publishers.Merge4(
            $isEnabled.map { _ in () },
            $selectedStyle.map { _ in () },
            $showModeIndicator.map { _ in () },
            $modeIndicatorPosition.map { _ in () }
        )
        .eraseToAnyPublisher()
    }

    /// Create settings manager with App Group storage.
    public init() {
        // Try to use App Group storage, fall back to standard UserDefaults
        if let groupDefaults = UserDefaults(suiteName: Self.appGroupIdentifier) {
            self.defaults = groupDefaults
        } else {
            self.defaults = .standard
        }

        // Load stored values with defaults
        self.isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? false
        self.selectedStyle = EditorStyleIdentifier(rawValue: defaults.string(forKey: Keys.selectedStyle) ?? "") ?? .helix
        self.showModeIndicator = defaults.object(forKey: Keys.showModeIndicator) as? Bool ?? true
        self.modeIndicatorPosition = ModeIndicatorPosition(rawValue: defaults.string(forKey: Keys.modeIndicatorPosition) ?? "") ?? .bottomLeft
    }

    /// Create settings manager with custom UserDefaults (for testing or per-app override).
    public init(defaults: UserDefaults) {
        self.defaults = defaults

        self.isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? false
        self.selectedStyle = EditorStyleIdentifier(rawValue: defaults.string(forKey: Keys.selectedStyle) ?? "") ?? .helix
        self.showModeIndicator = defaults.object(forKey: Keys.showModeIndicator) as? Bool ?? true
        self.modeIndicatorPosition = ModeIndicatorPosition(rawValue: defaults.string(forKey: Keys.modeIndicatorPosition) ?? "") ?? .bottomLeft
    }

    /// Reset all settings to defaults.
    public func resetToDefaults() {
        isEnabled = false
        selectedStyle = .helix
        showModeIndicator = true
        modeIndicatorPosition = .bottomLeft
    }

    /// Toggle modal editing on/off.
    public func toggle() {
        isEnabled.toggle()
    }

    /// Cycle to the next editor style.
    public func cycleStyle() {
        let styles = EditorStyleIdentifier.allCases
        if let index = styles.firstIndex(of: selectedStyle) {
            let nextIndex = (index + 1) % styles.count
            selectedStyle = styles[nextIndex]
        }
    }
}

/// Position of the mode indicator overlay.
public enum ModeIndicatorPosition: String, Sendable, CaseIterable, Codable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

#if canImport(SwiftUI)
import SwiftUI

public extension ModeIndicatorPosition {
    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}
#endif
