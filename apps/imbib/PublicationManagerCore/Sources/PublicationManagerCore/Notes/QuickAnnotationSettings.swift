//
//  QuickAnnotationSettings.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation

// MARK: - Quick Annotation Field

/// A customizable field for quick annotations in the notes panel.
public struct QuickAnnotationField: Codable, Identifiable, Equatable, Sendable {
    /// Unique identifier for storage (e.g., "firstAuthor", "keyCollaborators")
    public var id: String

    /// Display label shown in the notes panel
    public var label: String

    /// Placeholder text shown when the field is empty
    public var placeholder: String

    /// Whether this field is visible in the notes panel
    public var isEnabled: Bool

    public init(id: String, label: String, placeholder: String, isEnabled: Bool = true) {
        self.id = id
        self.label = label
        self.placeholder = placeholder
        self.isEnabled = isEnabled
    }
}

// MARK: - Quick Annotation Settings

/// Settings for customizing the quick annotation fields in the notes panel.
public struct QuickAnnotationSettings: Codable, Equatable, Sendable {
    /// The list of quick annotation fields
    public var fields: [QuickAnnotationField]

    public init(fields: [QuickAnnotationField]) {
        self.fields = fields
    }

    /// Default quick annotation settings
    public static let defaults = QuickAnnotationSettings(fields: [
        QuickAnnotationField(
            id: "firstAuthor",
            label: "First Author",
            placeholder: "e.g., Pioneer in this field"
        ),
        QuickAnnotationField(
            id: "keyCollaborators",
            label: "Key Collaborators",
            placeholder: "e.g., Strong team from MIT"
        ),
        QuickAnnotationField(
            id: "keyFindings",
            label: "Key Findings",
            placeholder: "e.g., Novel approach to X"
        ),
        QuickAnnotationField(
            id: "methodology",
            label: "Methodology",
            placeholder: "e.g., Used simulations"
        ),
    ])

    /// Get a field by its ID
    public func field(for id: String) -> QuickAnnotationField? {
        fields.first { $0.id == id }
    }

    /// Get all enabled fields
    public var enabledFields: [QuickAnnotationField] {
        fields.filter(\.isEnabled)
    }

    /// Create a new field with a unique ID
    public static func createNewField() -> QuickAnnotationField {
        QuickAnnotationField(
            id: "custom_\(UUID().uuidString.prefix(8).lowercased())",
            label: "New Field",
            placeholder: "Add description here...",
            isEnabled: true
        )
    }

    /// Find a field by its label (for YAML front matter parsing)
    public func field(byLabel label: String) -> QuickAnnotationField? {
        fields.first { $0.label.lowercased() == label.lowercased() }
    }

    /// Convert annotations keyed by label to annotations keyed by ID
    public func labelToIDAnnotations(_ labelKeyed: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (label, value) in labelKeyed {
            if let field = field(byLabel: label) {
                result[field.id] = value
            } else {
                // Keep unknown keys as-is (custom annotations)
                result[label] = value
            }
        }
        return result
    }

    /// Convert annotations keyed by ID to annotations keyed by label
    public func idToLabelAnnotations(_ idKeyed: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (id, value) in idKeyed {
            if let field = field(for: id) {
                result[field.label] = value
            } else {
                // Keep unknown keys as-is
                result[id] = value
            }
        }
        return result
    }
}
