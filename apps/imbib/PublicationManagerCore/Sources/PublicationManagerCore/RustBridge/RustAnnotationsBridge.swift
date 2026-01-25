//
//  RustAnnotationsBridge.swift
//  PublicationManagerCore
//
//  Bridge for annotation serialization and conflict resolution.
//  Used for CloudKit sync of PDF annotations.
//
//  Note: Rust annotation serialization API is planned but not yet available.
//  This module provides Swift implementations with the same interface,
//  ready for Rust backend integration when available.
//

import Foundation
import CoreGraphics

// MARK: - Annotations Bridge

/// Bridge for annotation serialization and conflict resolution
public enum RustAnnotationsBridge {

    /// Serialize annotations to JSON for CloudKit sync
    public static func serialize(_ annotations: [AnnotationData]) -> Result<String, Error> {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(annotations)
            return .success(String(data: data, encoding: .utf8) ?? "[]")
        } catch {
            return .failure(error)
        }
    }

    /// Deserialize annotations from JSON after CloudKit sync
    public static func deserialize(_ json: String) -> Result<[AnnotationData], Error> {
        do {
            let data = json.data(using: .utf8) ?? Data()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let annotations = try decoder.decode([AnnotationData].self, from: data)
            return .success(annotations)
        } catch {
            return .failure(error)
        }
    }

    /// Merge local and remote annotations (CloudKit conflict resolution)
    ///
    /// Strategy: Most recently modified wins on conflict, preserving all unique annotations.
    public static func merge(local: [AnnotationData], remote: [AnnotationData]) -> [AnnotationData] {
        var result = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for annotation in remote {
            if let existing = result[annotation.id] {
                // Keep the more recently modified annotation
                if annotation.dateModified > existing.dateModified {
                    result[annotation.id] = annotation
                }
            } else {
                // New annotation from remote
                result[annotation.id] = annotation
            }
        }
        return Array(result.values).sorted { $0.dateCreated < $1.dateCreated }
    }
}

// MARK: - Swift ↔ Rust Type Conversion

/// Swift-native annotation data for bridging
public struct AnnotationData: Codable, Sendable, Identifiable {
    public let id: String
    public let pageNumber: Int
    public let type: String  // highlight, underline, strikeout, note, freetext, ink
    public let bounds: [AnnotationRect]
    public let color: String  // hex color
    public let content: String?
    public let dateCreated: Date
    public let dateModified: Date

    public init(
        id: String,
        pageNumber: Int,
        type: String,
        bounds: [AnnotationRect],
        color: String,
        content: String?,
        dateCreated: Date,
        dateModified: Date
    ) {
        self.id = id
        self.pageNumber = pageNumber
        self.type = type
        self.bounds = bounds
        self.color = color
        self.content = content
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }

    /// Create from a single CGRect (convenience)
    public init(
        id: String,
        pageNumber: Int,
        type: String,
        bounds: CGRect,
        color: String,
        content: String?,
        dateCreated: Date,
        dateModified: Date
    ) {
        self.id = id
        self.pageNumber = pageNumber
        self.type = type
        self.bounds = [AnnotationRect(from: bounds)]
        self.color = color
        self.content = content
        self.dateCreated = dateCreated
        self.dateModified = dateModified
    }
}

/// Rectangle for annotation bounds (Codable-friendly version of CGRect)
public struct AnnotationRect: Codable, Sendable, Equatable {
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(from rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Rust Annotations Info

public enum RustAnnotationsInfo {
    /// Rust annotation backend is not yet available
    /// This will be updated when Rust annotation API is exposed
    public static var isAvailable: Bool { false }
}
