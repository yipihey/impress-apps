//
//  HelpCategory.swift
//  PublicationManagerCore
//
//  Categories for help documentation.
//

import Foundation

/// Categories for grouping help documents in the sidebar.
public enum HelpCategory: String, CaseIterable, Codable, Sendable {
    case gettingStarted = "Getting Started"
    case features = "Features"
    case keyboardShortcuts = "Keyboard Shortcuts"
    case faq = "FAQ"
    case automation = "Automation"
    case architecture = "Architecture"

    /// SF Symbol name for the category icon.
    public var iconName: String {
        switch self {
        case .gettingStarted:
            return "play.circle"
        case .features:
            return "star"
        case .keyboardShortcuts:
            return "keyboard"
        case .faq:
            return "questionmark.circle"
        case .automation:
            return "gearshape.2"
        case .architecture:
            return "building.columns"
        }
    }

    /// Display order for categories in the sidebar.
    public var sortOrder: Int {
        switch self {
        case .gettingStarted: return 0
        case .features: return 1
        case .keyboardShortcuts: return 2
        case .faq: return 3
        case .automation: return 4
        case .architecture: return 5
        }
    }

    /// Whether this category contains developer documentation.
    public var isDeveloperCategory: Bool {
        switch self {
        case .architecture:
            return true
        default:
            return false
        }
    }
}
