//
//  SciXLibraryService.swift
//  PublicationManagerCore
//
//  Actor-based service for the SciX Biblib API.
//
//  Core operations (list, get, create, add, remove, delete) are handled by
//  scix-client-ffi (Rust). Advanced operations (permissions, metadata updates,
//  ownership transfer) not yet in scix-client use a minimal URLSession.
//

import Foundation
import ImpressScixCore
import OSLog

// MARK: - SciXLibraryService

/// Actor-based service for communicating with the SciX Biblib API.
public actor SciXLibraryService {

    // MARK: - Singleton

    public static let shared = SciXLibraryService()

    // MARK: - Properties

    private let baseURL = "https://api.adsabs.harvard.edu/v1/biblib"
    /// URLSession kept only for advanced operations not covered by scix-client.
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    // MARK: - Initialization

    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - API Key

    private func getAPIKey() async throws -> String {
        if let key = await CredentialManager.shared.apiKey(for: "ads"), !key.isEmpty {
            return key
        }
        if let key = await CredentialManager.shared.apiKey(for: "scix"), !key.isEmpty {
            return key
        }
        throw SciXLibraryError.noAPIKey
    }

    // MARK: - Library Listing (scix-client)

    /// Fetch all libraries accessible to the user.
    public func fetchLibraries() async throws -> [SciXLibraryMetadata] {
        let apiKey = try await getAPIKey()

        do {
            let libraries = try await Task.detached(priority: .userInitiated) {
                try scixListLibraries(token: apiKey)
            }.value

            Logger.scix.info("Fetched \(libraries.count) SciX libraries")
            return libraries.map { SciXLibraryMetadata(from: $0) }
        } catch let error as ScixFfiError {
            throw SciXLibraryError(from: error)
        }
    }

    /// Fetch details for a specific library including bibcodes.
    public func fetchLibraryDetails(id: String) async throws -> SciXLibraryDetailResponse {
        let apiKey = try await getAPIKey()

        do {
            let detail = try await Task.detached(priority: .userInitiated) {
                try scixGetLibrary(token: apiKey, libraryId: id)
            }.value

            Logger.scix.info("Fetched library details: \(detail.name) (\(detail.numDocuments) docs)")
            return SciXLibraryDetailResponse(from: detail)
        } catch let error as ScixFfiError {
            throw SciXLibraryError(from: error)
        }
    }

    /// Fetch bibcodes for a library.
    public func fetchLibraryBibcodes(id: String) async throws -> [String] {
        let details = try await fetchLibraryDetails(id: id)

        if let documents = details.documents, !documents.isEmpty {
            return documents
        }
        if let docs = details.solr?.response?.docs {
            let bibcodes = docs.compactMap { $0.bibcode }
            if !bibcodes.isEmpty { return bibcodes }
        }

        Logger.scix.warning("No bibcodes found in library response")
        return []
    }

    // MARK: - Library Creation (scix-client)

    /// Create a new library.
    public func createLibrary(
        name: String,
        description: String? = nil,
        isPublic: Bool = false,
        bibcodes: [String]? = nil
    ) async throws -> SciXCreateLibraryResponse {
        let apiKey = try await getAPIKey()

        do {
            let libraryID = try await Task.detached(priority: .userInitiated) {
                try scixCreateLibrary(
                    token: apiKey,
                    name: name,
                    description: description ?? "",
                    isPublic: isPublic,
                    bibcodes: bibcodes ?? []
                )
            }.value

            Logger.scix.info("Created library: \(name) (id: \(libraryID))")
            return SciXCreateLibraryResponse(id: libraryID, name: name, description: description)
        } catch let error as ScixFfiError {
            throw SciXLibraryError(from: error)
        }
    }

    // MARK: - Document Management (scix-client)

    /// Add bibcodes to a library.
    public func addDocuments(libraryID: String, bibcodes: [String]) async throws -> Int {
        let apiKey = try await getAPIKey()

        do {
            try await Task.detached(priority: .userInitiated) {
                try scixAddToLibrary(token: apiKey, libraryId: libraryID, bibcodes: bibcodes)
            }.value

            Logger.scix.info("Added \(bibcodes.count) documents to library \(libraryID)")
            return bibcodes.count
        } catch let error as ScixFfiError {
            throw SciXLibraryError(from: error)
        }
    }

    /// Remove bibcodes from a library.
    public func removeDocuments(libraryID: String, bibcodes: [String]) async throws -> Int {
        let apiKey = try await getAPIKey()

        do {
            try await Task.detached(priority: .userInitiated) {
                try scixRemoveFromLibrary(token: apiKey, libraryId: libraryID, bibcodes: bibcodes)
            }.value

            Logger.scix.info("Removed \(bibcodes.count) documents from library \(libraryID)")
            return bibcodes.count
        } catch let error as ScixFfiError {
            throw SciXLibraryError(from: error)
        }
    }

    // MARK: - Library Deletion (scix-client)

    /// Delete a library (requires owner permission).
    public func deleteLibrary(id: String) async throws {
        let apiKey = try await getAPIKey()

        do {
            try await Task.detached(priority: .userInitiated) {
                try scixDeleteLibrary(token: apiKey, libraryId: id)
            }.value

            Logger.scix.info("Deleted library \(id)")
        } catch let error as ScixFfiError {
            throw SciXLibraryError(from: error)
        }
    }

    // MARK: - Metadata Updates (URLSession — not yet in scix-client)

    /// Update library metadata (name, description, public status).
    public func updateMetadata(
        libraryID: String,
        name: String? = nil,
        description: String? = nil,
        isPublic: Bool? = nil
    ) async throws {
        let request = SciXUpdateMetadataRequest(
            name: name,
            description: description,
            isPublic: isPublic
        )
        let body = try encoder.encode(request)
        let (_, _) = try await makeRequest(path: "/documents/\(libraryID)", method: "PUT", body: body)
        Logger.scix.info("Updated metadata for library \(libraryID)")
    }

    // MARK: - Permissions (URLSession — not yet in scix-client)

    /// Fetch permissions for a library.
    public func fetchPermissions(libraryID: String) async throws -> [SciXPermission] {
        let (data, _) = try await makeRequest(path: "/permissions/\(libraryID)")

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: [[String]]] {
            let permissions = json.values.first ?? []
            return permissions.compactMap { arr in
                guard arr.count >= 2 else { return nil }
                return SciXPermission(email: arr[0], permission: arr[1])
            }
        }
        throw SciXLibraryError.invalidResponse
    }

    /// Set permission for a user on a library.
    public func setPermission(
        libraryID: String,
        email: String,
        permission: SciXPermissionLevel
    ) async throws {
        let request = SciXSetPermissionRequest(
            permissions: [(email: email, permission: permission.rawValue)]
        )
        let body = try encoder.encode(request)
        let (_, _) = try await makeRequest(path: "/permissions/\(libraryID)", method: "POST", body: body)
        Logger.scix.info("Set permission \(permission.rawValue) for \(email) on library \(libraryID)")
    }

    // MARK: - Ownership Transfer (URLSession — not yet in scix-client)

    /// Transfer library ownership to another user.
    public func transferOwnership(libraryID: String, toEmail: String) async throws {
        let request = SciXTransferOwnershipRequest(email: toEmail)
        let body = try encoder.encode(request)
        let (_, _) = try await makeRequest(path: "/transfer/\(libraryID)", method: "POST", body: body)
        Logger.scix.info("Transferred ownership of library \(libraryID) to \(toEmail)")
    }

    // MARK: - URLSession Helper (for advanced operations not covered by scix-client)

    private func makeRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let apiKey = try await getAPIKey()
        let url = URL(string: "\(baseURL)\(path)")!

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        Logger.scix.debug("SciX API: \(method) \(path)")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SciXLibraryError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SciXLibraryError.invalidResponse
        }

        try handleStatusCode(httpResponse.statusCode, data: data)
        return (data, httpResponse)
    }

    private func handleStatusCode(_ statusCode: Int, data: Data) throws {
        switch statusCode {
        case 200...299: return
        case 401: throw SciXLibraryError.unauthorized
        case 403: throw SciXLibraryError.forbidden
        case 404: throw SciXLibraryError.notFound
        case 409: throw SciXLibraryError.conflict(String(data: data, encoding: .utf8) ?? "Unknown conflict")
        case 429: throw SciXLibraryError.rateLimited
        default: throw SciXLibraryError.serverError(statusCode)
        }
    }
}

// MARK: - Type Adapters

extension SciXLibraryMetadata {
    /// Create from a scix-client ScixLibrary.
    /// Fields not provided by scix-client (permission, dates) get sensible defaults.
    init(from lib: ScixLibrary) {
        self.init(
            id: lib.id,
            name: lib.name,
            description: lib.description.isEmpty ? nil : lib.description,
            permission: "owner",  // scix-client returns user's own libraries
            num_documents: Int(lib.numDocuments),
            date_created: "",
            date_last_modified: "",
            public: lib.isPublic,
            owner: lib.owner.isEmpty ? nil : lib.owner
        )
    }
}

extension SciXLibraryDetailResponse {
    /// Create from a scix-client ScixLibraryDetail.
    init(from detail: ScixLibraryDetail) {
        let metadata = SciXLibraryDetailMetadata(
            id: detail.id,
            name: detail.name,
            description: detail.description.isEmpty ? nil : detail.description,
            public: detail.isPublic,
            num_documents: Int(detail.numDocuments),
            date_created: "",
            date_last_modified: "",
            permission: "owner",
            owner: detail.owner.isEmpty ? nil : detail.owner,
            num_users: nil
        )
        self.init(metadata: metadata, solr: nil, updates: nil, documents: detail.bibcodes)
    }
}

extension SciXLibraryError {
    init(from error: ScixFfiError) {
        switch error {
        case .unauthorized: self = .unauthorized
        case .rateLimited: self = .rateLimited
        case .notFound: self = .notFound
        case .networkError: self = .networkError(URLError(.badServerResponse))
        case .apiError: self = .serverError(500)
        case .`internal`: self = .serverError(500)
        }
    }
}

// MARK: - Logger Extension

extension Logger {
    static let scix = Logger(subsystem: "com.imbib.PublicationManagerCore", category: "scix")
}
