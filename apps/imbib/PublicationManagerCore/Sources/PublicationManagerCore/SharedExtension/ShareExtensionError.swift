//
//  ShareExtensionError.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import Foundation

/// Errors that can occur during share extension processing.
public enum ShareExtensionError: LocalizedError {
    /// The shared URL is not a valid research database URL
    case invalidURL

    /// No library is available to save the item
    case noLibrary

    /// The paper could not be found in the database
    case paperNotFound

    /// The source is not supported for sharing
    case unsupportedSource(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid research database URL"
        case .noLibrary:
            return "No library available"
        case .paperNotFound:
            return "Paper not found in database"
        case .unsupportedSource(let source):
            return "Unsupported source: \(source)"
        }
    }
}
