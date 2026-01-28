//
//  CiteKeyFormatSettings.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-28.
//

import Foundation
import ImbibRustCore

// MARK: - Cite Key Format Preset

/// Preset cite key format options inspired by BibDesk.
public enum CiteKeyFormatPreset: String, CaseIterable, Codable, Sendable {
    /// Classic format: LastName + Year + TitleWord (e.g., Smith2024Machine)
    case classic
    /// Two authors + underscore + year (e.g., SmithJones_2024)
    case authorsYear
    /// Short format: LastName + colon + 2-digit year (e.g., Smith:24)
    case short
    /// All authors (up to 3, then EtAl) + year (e.g., SmithJonesDoeEtAl2024)
    case fullAuthors
    /// Custom user-defined format string
    case custom

    /// The format string for this preset
    public var formatString: String {
        switch self {
        case .classic:
            return "%a%Y%t"
        case .authorsYear:
            return "%a2_%Y"
        case .short:
            return "%a:%y"
        case .fullAuthors:
            return "%A%Y"
        case .custom:
            // Custom preset returns empty; actual format stored separately
            return ""
        }
    }

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .classic:
            return "Classic"
        case .authorsYear:
            return "Author+Year"
        case .short:
            return "Short"
        case .fullAuthors:
            return "Full Authors"
        case .custom:
            return "Custom"
        }
    }

    /// Preview of what this format produces
    public var preview: String {
        switch self {
        case .classic:
            return "Smith2024Machine"
        case .authorsYear:
            return "SmithJones_2024"
        case .short:
            return "Smith:24"
        case .fullAuthors:
            return "SmithJonesDoeEtAl2024"
        case .custom:
            return ""
        }
    }
}

// MARK: - Cite Key Format Settings

/// Settings for cite key generation format.
public struct CiteKeyFormatSettings: Codable, Equatable, Sendable {
    /// The selected preset (or .custom for custom format)
    public var preset: CiteKeyFormatPreset

    /// Custom format string (used when preset is .custom)
    public var customFormat: String

    /// Whether to convert cite keys to lowercase
    public var lowercase: Bool

    /// The active format string (preset or custom)
    public var activeFormat: String {
        if preset == .custom {
            return customFormat.isEmpty ? CiteKeyFormatPreset.classic.formatString : customFormat
        }
        return preset.formatString
    }

    public init(
        preset: CiteKeyFormatPreset = .classic,
        customFormat: String = "%a%Y%t",
        lowercase: Bool = false
    ) {
        self.preset = preset
        self.customFormat = customFormat
        self.lowercase = lowercase
    }

    public static let `default` = CiteKeyFormatSettings()
}

// MARK: - Format Specifier Reference

/// Documentation for format specifiers, used in help UI.
public struct CiteKeyFormatSpecifier: Identifiable, Sendable {
    public let id: String
    public let specifier: String
    public let description: String
    public let example: String

    public init(specifier: String, description: String, example: String) {
        self.id = specifier
        self.specifier = specifier
        self.description = description
        self.example = example
    }
}

/// All available format specifiers for reference.
public let citeKeyFormatSpecifiers: [CiteKeyFormatSpecifier] = [
    CiteKeyFormatSpecifier(
        specifier: "%a",
        description: "First author last name",
        example: "Smith"
    ),
    CiteKeyFormatSpecifier(
        specifier: "%a2",
        description: "First two author last names",
        example: "SmithJones"
    ),
    CiteKeyFormatSpecifier(
        specifier: "%A",
        description: "All authors (up to 3, then EtAl)",
        example: "SmithJonesEtAl"
    ),
    CiteKeyFormatSpecifier(
        specifier: "%y",
        description: "Year (2 digit)",
        example: "24"
    ),
    CiteKeyFormatSpecifier(
        specifier: "%Y",
        description: "Year (4 digit)",
        example: "2024"
    ),
    CiteKeyFormatSpecifier(
        specifier: "%t",
        description: "First significant title word",
        example: "Machine"
    ),
    CiteKeyFormatSpecifier(
        specifier: "%T2",
        description: "First N title words",
        example: "MachineLearning"
    ),
    CiteKeyFormatSpecifier(
        specifier: "%u",
        description: "Unique letter suffix (a-z)",
        example: "a"
    ),
    CiteKeyFormatSpecifier(
        specifier: "%n",
        description: "Unique number suffix",
        example: "2"
    ),
    CiteKeyFormatSpecifier(
        specifier: "%f{field}",
        description: "Custom field value",
        example: "%f{journal} -> Nature"
    ),
]

// MARK: - Cite Key Format Generation Helper

/// Helper for generating cite keys using customizable format settings.
/// Uses the Rust imbib-core library for format parsing and generation.
public struct FormatBasedCiteKeyGenerator {
    private let settings: CiteKeyFormatSettings

    public init(settings: CiteKeyFormatSettings) {
        self.settings = settings
    }

    /// Generate a cite key from publication metadata.
    public func generate(
        author: String?,
        year: String?,
        title: String?
    ) -> String {
        generateCiteKeyFormatted(
            format: settings.activeFormat,
            author: author,
            year: year,
            title: title,
            lowercase: settings.lowercase
        )
    }

    /// Generate a unique cite key, avoiding conflicts with existing keys.
    public func generateUnique(
        author: String?,
        year: String?,
        title: String?,
        existingKeys: [String]
    ) -> String {
        generateUniqueCiteKeyFormatted(
            format: settings.activeFormat,
            author: author,
            year: year,
            title: title,
            lowercase: settings.lowercase,
            existingKeys: existingKeys
        )
    }

    /// Preview what the format produces with example data.
    public func preview() -> String {
        let preview = previewCiteKeyFormat(format: settings.activeFormat)
        return settings.lowercase ? preview.lowercased() : preview
    }

    /// Validate the format string.
    /// Returns a tuple of (isValid, errorMessage, warnings).
    public func validate() -> (isValid: Bool, error: String, warnings: [String]) {
        let result = validateCiteKeyFormat(format: settings.activeFormat)
        return (result.isValid, result.errorMessage, result.warnings)
    }
}
