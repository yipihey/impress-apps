//
//  AppearanceMode.swift
//  ImpressTheme
//
//  User preference for color scheme (system/light/dark).
//

import SwiftUI

/// User preference for color scheme
public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Convert to SwiftUI ColorScheme (nil = follow system)
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
