//
//  SciXLibraryTypes.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation

// MARK: - API Response Types

/// Response from GET /libraries endpoint (list all libraries)
public struct SciXLibraryListResponse: Codable, Sendable {
    public let libraries: [SciXLibraryMetadata]
}

/// Library metadata from list endpoint
public struct SciXLibraryMetadata: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let permission: String            // owner, admin, write, read
    public let num_documents: Int
    public let date_created: String
    public let date_last_modified: String
    public let `public`: Bool
    public let owner: String?                // Owner email

    // For Identifiable conformance
    public var uniqueID: String { id }
}

/// Response from GET /libraries/<id> endpoint (library details with bibcodes)
public struct SciXLibraryDetailResponse: Codable, Sendable {
    public let metadata: SciXLibraryDetailMetadata
    public let solr: SciXLibrarySolr?
    public let updates: SciXLibraryUpdates?
    public let documents: [String]?          // Array of bibcodes (primary way to get bibcodes)
}

/// Detailed library metadata including document list
public struct SciXLibraryDetailMetadata: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let `public`: Bool
    public let num_documents: Int
    public let date_created: String
    public let date_last_modified: String
    public let permission: String
    public let owner: String?
    public let num_users: Int?
}

/// Solr query information for library contents
public struct SciXLibrarySolr: Codable, Sendable {
    public let responseHeader: SciXSolrHeader?
    public let response: SciXSolrResponse?
}

/// Solr response header
public struct SciXSolrHeader: Codable, Sendable {
    public let status: Int?
    public let QTime: Int?
}

/// Solr response with documents
public struct SciXSolrResponse: Codable, Sendable {
    public let numFound: Int?
    public let start: Int?
    public let docs: [SciXSolrDoc]?
}

/// Individual document in solr response
public struct SciXSolrDoc: Codable, Sendable {
    public let bibcode: String?
}

/// Update timestamps
public struct SciXLibraryUpdates: Codable, Sendable {
    public let num_updated: Int?
    public let duplicates_removed: Int?
    public let update_list: [String]?
}

/// Response from POST /libraries endpoint (create library)
public struct SciXCreateLibraryResponse: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
}

/// Response from POST /documents/<id> endpoint (modify documents)
public struct SciXModifyDocumentsResponse: Codable, Sendable {
    public let number_added: Int?
    public let number_removed: Int?
}

/// Response from PUT /documents/<id> endpoint (update metadata)
public struct SciXUpdateMetadataResponse: Codable, Sendable {
    public let name: String?
    public let description: String?
    public let `public`: Bool?
}

// MARK: - Permission Types

/// Permission information for a library user
public struct SciXPermission: Codable, Sendable, Identifiable {
    public let email: String
    public let permission: String            // owner, admin, write, read

    public var id: String { email }

    public var level: CDSciXLibrary.PermissionLevel {
        CDSciXLibrary.PermissionLevel(rawValue: permission) ?? .read
    }
}

/// Response from GET /permissions/<id> endpoint
public struct SciXPermissionsResponse: Codable, Sendable {
    // Note: ADS returns an array of [email, permission] arrays
    // We need custom decoding
    public let permissions: [[String]]

    public var parsed: [SciXPermission] {
        permissions.compactMap { arr in
            guard arr.count >= 2 else { return nil }
            return SciXPermission(email: arr[0], permission: arr[1])
        }
    }
}

// MARK: - Request Types

/// Request body for creating a new library
public struct SciXCreateLibraryRequest: Codable, Sendable {
    public let name: String
    public let description: String?
    public let `public`: Bool
    public let bibcode: [String]?

    public init(name: String, description: String? = nil, isPublic: Bool = false, bibcodes: [String]? = nil) {
        self.name = name
        self.description = description
        self.public = isPublic
        self.bibcode = bibcodes
    }
}

/// Request body for modifying documents in a library
public struct SciXModifyDocumentsRequest: Codable, Sendable {
    public let bibcode: [String]
    public let action: String               // "add" or "remove"

    public init(bibcodes: [String], action: SciXDocumentAction) {
        self.bibcode = bibcodes
        self.action = action.rawValue
    }
}

/// Actions for modifying library documents
public enum SciXDocumentAction: String, Codable, Sendable {
    case add = "add"
    case remove = "remove"
}

/// Request body for updating library metadata
public struct SciXUpdateMetadataRequest: Codable, Sendable {
    public let name: String?
    public let description: String?
    public let `public`: Bool?

    public init(name: String? = nil, description: String? = nil, isPublic: Bool? = nil) {
        self.name = name
        self.description = description
        self.public = isPublic
    }
}

/// Request body for setting permissions
public struct SciXSetPermissionRequest: Codable, Sendable {
    public let email: [[String]]            // [[email, permission], ...]

    public init(permissions: [(email: String, permission: String)]) {
        self.email = permissions.map { [$0.email, $0.permission] }
    }
}

/// Request body for transferring ownership
public struct SciXTransferOwnershipRequest: Codable, Sendable {
    public let email: String

    public init(email: String) {
        self.email = email
    }
}

// MARK: - Error Types

/// Errors from SciX Library API
public enum SciXLibraryError: Error, LocalizedError {
    case unauthorized                        // 401: Invalid/missing API key
    case forbidden                           // 403: No permission
    case notFound                            // 404: Library not found
    case conflict(String)                    // 409: Library name conflict
    case rateLimited                         // 429: Too many requests
    case serverError(Int)                    // 5xx: Server error
    case networkError(Error)                 // Network connectivity issue
    case decodingError(Error)                // JSON parsing error
    case noAPIKey                            // No API key configured
    case invalidResponse                     // Unexpected response format

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Invalid or missing SciX API key"
        case .forbidden:
            return "You don't have permission to access this library"
        case .notFound:
            return "Library not found"
        case .conflict(let message):
            return "Conflict: \(message)"
        case .rateLimited:
            return "Too many requests. Please try again later."
        case .serverError(let code):
            return "Server error (\(code)). Please try again later."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        case .noAPIKey:
            return "No SciX API key configured. Add your key in Settings."
        case .invalidResponse:
            return "Unexpected response from server"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError, .networkError:
            return true
        default:
            return false
        }
    }
}
