//
//  ModalEditingSettings.swift
//  ImpressHelixCore
//
//  Shared settings for modal editing across apps.
//

import SwiftUI

/// Available modal editing styles
public enum EditorStyleIdentifier: String, CaseIterable, Identifiable, Sendable {
    case helix
    case vim
    case emacs

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .helix: return "Helix"
        case .vim: return "Vim"
        case .emacs: return "Emacs"
        }
    }
}

/// Shared settings for modal editing behavior.
///
/// Access via `ModalEditingSettings.shared` singleton.
/// Settings are persisted to UserDefaults.
@MainActor
@Observable
public final class ModalEditingSettings {
    /// Shared singleton instance
    public static let shared = ModalEditingSettings()

    /// UserDefaults keys
    private enum Keys {
        static let isEnabled = "modalEditing.isEnabled"
        static let selectedStyle = "modalEditing.selectedStyle"
        static let showModeIndicator = "modalEditing.showModeIndicator"
    }

    /// Whether modal editing is enabled
    public var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return UserDefaults.standard.bool(forKey: Keys.isEnabled)
        }
        set {
            withMutation(keyPath: \.isEnabled) {
                UserDefaults.standard.set(newValue, forKey: Keys.isEnabled)
            }
        }
    }

    /// The selected editing style (raw value)
    public var selectedStyleRaw: String {
        get {
            access(keyPath: \.selectedStyleRaw)
            return UserDefaults.standard.string(forKey: Keys.selectedStyle) ?? EditorStyleIdentifier.helix.rawValue
        }
        set {
            withMutation(keyPath: \.selectedStyleRaw) {
                UserDefaults.standard.set(newValue, forKey: Keys.selectedStyle)
            }
        }
    }

    /// Whether to show the mode indicator
    public var showModeIndicator: Bool {
        get {
            access(keyPath: \.showModeIndicator)
            return UserDefaults.standard.object(forKey: Keys.showModeIndicator) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.showModeIndicator) {
                UserDefaults.standard.set(newValue, forKey: Keys.showModeIndicator)
            }
        }
    }

    /// The selected editing style (computed from raw value)
    public var selectedStyle: EditorStyleIdentifier {
        get {
            EditorStyleIdentifier(rawValue: selectedStyleRaw) ?? .helix
        }
        set {
            selectedStyleRaw = newValue.rawValue
        }
    }

    private init() {}
}
