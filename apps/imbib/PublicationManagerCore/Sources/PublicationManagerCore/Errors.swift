//
//  Errors.swift
//  PublicationManagerCore
//

import Foundation

// MARK: - BibTeX Errors

public enum BibTeXError: LocalizedError, Sendable {
    case parseError(line: Int, message: String)
    case invalidEntry(String)
    case missingRequiredField(String)
    case invalidCiteKey(String)

    public var errorDescription: String? {
        switch self {
        case .parseError(let line, let message):
            return "Parse error at line \(line): \(message)"
        case .invalidEntry(let details):
            return "Invalid BibTeX entry: \(details)"
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        case .invalidCiteKey(let key):
            return "Invalid cite key: \(key)"
        }
    }
}

// MARK: - Source Errors

public enum SourceError: LocalizedError, Sendable {
    case networkError(Error)
    case parseError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case notFound(String)
    case unauthorized
    case invalidResponse(String)
    case invalidRequest(String)
    case unknownSource(String)
    case authenticationRequired(String)
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(Int(seconds)) seconds."
            }
            return "Rate limited. Please try again later."
        case .notFound(let message):
            return "Not found: \(message)"
        case .unauthorized:
            return "Authentication required"
        case .invalidResponse(let message):
            return "Invalid response: \(message)"
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        case .unknownSource(let sourceID):
            return "Unknown source: \(sourceID)"
        case .authenticationRequired(let sourceID):
            return "Authentication required for \(sourceID)"
        case .unsupportedFormat(let format):
            return "Format not supported by this source: \(format)"
        }
    }
}

// MARK: - Credential Errors

public enum CredentialError: LocalizedError, Sendable {
    case storageFailed
    case notFound(sourceID: String)
    case invalid(String)
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .storageFailed:
            return "Failed to store credential"
        case .notFound(let sourceID):
            return "No credential found for \(sourceID)"
        case .invalid(let message):
            return "Invalid credential: \(message)"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        }
    }
}

// MARK: - File Errors

public enum FileError: LocalizedError, Sendable {
    case notFound(URL)
    case permissionDenied(URL)
    case importFailed(String)
    case exportFailed(String)
    case invalidFormat(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .permissionDenied(let url):
            return "Permission denied: \(url.lastPathComponent)"
        case .importFailed(let message):
            return "Import failed: \(message)"
        case .exportFailed(let message):
            return "Export failed: \(message)"
        case .invalidFormat(let message):
            return "Invalid format: \(message)"
        }
    }
}
