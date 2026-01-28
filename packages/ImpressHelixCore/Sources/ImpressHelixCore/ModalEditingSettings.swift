//
//  ModalEditingSettings.swift
//  ImpressHelixCore
//
//  Shared settings for modal editing across apps.
//

import SwiftUI
import Combine

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
public final class ModalEditingSettings: ObservableObject {
    /// Shared singleton instance
    public static let shared = ModalEditingSettings()

    /// Whether modal editing is enabled
    @AppStorage("modalEditing.isEnabled")
    public var isEnabled: Bool = false

    /// The selected editing style
    @AppStorage("modalEditing.selectedStyle")
    public var selectedStyleRaw: String = EditorStyleIdentifier.helix.rawValue

    /// Whether to show the mode indicator
    @AppStorage("modalEditing.showModeIndicator")
    public var showModeIndicator: Bool = true

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
