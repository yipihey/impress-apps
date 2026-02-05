//
//  TagModels.swift
//  ImpressFTUI
//

import SwiftUI

// MARK: - Tag Display Data

/// Value-type snapshot of tag data for safe display in list rows.
public struct TagDisplayData: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let leaf: String
    public let colorLight: String?
    public let colorDark: String?

    public init(id: UUID, path: String, leaf: String, colorLight: String? = nil, colorDark: String? = nil) {
        self.id = id
        self.path = path
        self.leaf = leaf
        self.colorLight = colorLight
        self.colorDark = colorDark
    }

    /// Resolved color for the current color scheme.
    public func resolvedColor(for colorScheme: ColorScheme) -> Color? {
        let hex = colorScheme == .dark ? colorDark : colorLight
        guard let hex else { return nil }
        return Color(hex: hex)
    }
}

// MARK: - Tag Display Style

/// How tags are rendered in publication rows.
public enum TagDisplayStyle: Codable, Equatable, Hashable, Sendable {
    /// Tags are hidden in the list view
    case hidden
    /// Show colored dots only
    case dots(maxVisible: Int)
    /// Show text labels
    case text
    /// Dots with text on hover (future)
    case hybrid(maxVisible: Int)

    public static let `default` = TagDisplayStyle.dots(maxVisible: 5)
}

// MARK: - Tag Text Config

/// Configuration for tag text rendering.
public struct TagTextConfig: Codable, Equatable, Sendable {
    public var showFullPath: Bool
    public var truncateDepth: Int?

    public init(showFullPath: Bool = false, truncateDepth: Int? = nil) {
        self.showFullPath = showFullPath
        self.truncateDepth = truncateDepth
    }

    public static let `default` = TagTextConfig()
}

// MARK: - Tag Path Style

/// How tag paths are displayed.
public enum TagPathStyle: String, Codable, CaseIterable, Sendable {
    case full        // "methods/sims/hydro/AMR"
    case leafOnly    // "AMR"
    case truncated   // ".../hydro/AMR"

    public var displayName: String {
        switch self {
        case .full: return "Full Path"
        case .leafOnly: return "Leaf Only"
        case .truncated: return "Truncated"
        }
    }
}

// MARK: - Tag Completion

/// A completion suggestion for tag input.
public struct TagCompletion: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let leaf: String
    public let depth: Int
    public let useCount: Int
    public let lastUsedAt: Date?
    public let colorLight: String?
    public let colorDark: String?

    public init(
        id: UUID,
        path: String,
        leaf: String,
        depth: Int,
        useCount: Int = 0,
        lastUsedAt: Date? = nil,
        colorLight: String? = nil,
        colorDark: String? = nil
    ) {
        self.id = id
        self.path = path
        self.leaf = leaf
        self.depth = depth
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.colorLight = colorLight
        self.colorDark = colorDark
    }
}

// MARK: - Default Tag Colors

/// Default color palette for tags without explicit colors.
public let defaultTagColors: [(light: String, dark: String)] = [
    ("43A047", "66BB6A"),   // Green
    ("1E88E5", "42A5F5"),   // Blue
    ("8E24AA", "AB47BC"),   // Purple
    ("E53935", "EF5350"),   // Red
    ("FB8C00", "FFA726"),   // Orange
    ("00ACC1", "26C6DA"),   // Cyan
    ("D81B60", "EC407A"),   // Pink
    ("5E35B1", "7E57C2"),   // Deep Purple
]

/// Pick a deterministic color based on a string hash.
public func defaultTagColor(for path: String) -> (light: String, dark: String) {
    let hash = abs(path.hashValue)
    return defaultTagColors[hash % defaultTagColors.count]
}
