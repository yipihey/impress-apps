//
//  SciXLibraryService.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation
import OSLog

/// Actor-based service for communicating with the SciX Biblib API.
/// Handles all HTTP requests to the ADS/SciX library endpoints.
public actor SciXLibraryService {

    // MARK: - Singleton

    public static let shared = SciXLibraryService()

    // MARK: - Properties

    private let baseURL = "https://api.adsabs.harvard.edu/v1/biblib"
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    // Rate limiting: 5000 requests/day = ~3.5 requests/second max
    // We'll be conservative and limit to 1 request per 500ms
    private var lastRequestTime: Date?
    private let minRequestInterval: TimeInterval = 0.5

    // MARK: - Initialization

    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - API Key

    /// Get the API key from CredentialManager
    /// Uses the same "ads" key as ADSSource since SciX uses the ADS API
    private func getAPIKey() async throws -> String {
        let key = await CredentialManager.shared.apiKey(for: "ads")
        guard let apiKey = key, !apiKey.isEmpty else {
            throw SciXLibraryError.noAPIKey
        }
        return apiKey
    }

    // MARK: - Rate Limiting

    private func waitForRateLimit() async {
        if let lastTime = lastRequestTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < minRequestInterval {
                let delay = minRequestInterval - elapsed
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        lastRequestTime = Date()
    }

    // MARK: - HTTP Helpers

    private func makeRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        await waitForRateLimit()

        let apiKey = try await getAPIKey()
        let url = URL(string: "\(baseURL)\(path)")!

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body = body {
            request.httpBody = body
        }

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
        case 200...299:
            return // Success
        case 401:
            throw SciXLibraryError.unauthorized
        case 403:
            throw SciXLibraryError.forbidden
        case 404:
            throw SciXLibraryError.notFound
        case 409:
            let message = String(data: data, encoding: .utf8) ?? "Unknown conflict"
            throw SciXLibraryError.conflict(message)
        case 429:
            throw SciXLibraryError.rateLimited
        case 500...599:
            throw SciXLibraryError.serverError(statusCode)
        default:
            throw SciXLibraryError.serverError(statusCode)
        }
    }

    // MARK: - Library Listing

    /// Fetch all libraries accessible to the user
    public func fetchLibraries() async throws -> [SciXLibraryMetadata] {
        let (data, _) = try await makeRequest(path: "/libraries")

        do {
            let response = try decoder.decode(SciXLibraryListResponse.self, from: data)
            Logger.scix.info("Fetched \(response.libraries.count) SciX libraries")
            return response.libraries
        } catch {
            throw SciXLibraryError.decodingError(error)
        }
    }

    /// Fetch details for a specific library including bibcodes
    public func fetchLibraryDetails(id: String) async throws -> SciXLibraryDetailResponse {
        // Don't use raw=true - it returns solr as a string which breaks decoding
        // The documents array is available in both cases
        let (data, _) = try await makeRequest(path: "/libraries/\(id)")

        // Log raw response for debugging
        if let rawJSON = String(data: data, encoding: .utf8) {
            Logger.scix.debug("Library details raw response: \(rawJSON.prefix(500))")
        }

        do {
            let response = try decoder.decode(SciXLibraryDetailResponse.self, from: data)
            Logger.scix.info("Fetched library details: \(response.metadata.name) (\(response.metadata.num_documents) docs)")
            return response
        } catch {
            Logger.scix.error("Failed to decode library details: \(error)")
            throw SciXLibraryError.decodingError(error)
        }
    }

    /// Fetch bibcodes for a library
    public func fetchLibraryBibcodes(id: String) async throws -> [String] {
        let details = try await fetchLibraryDetails(id: id)

        // Primary: Use documents array if available
        if let documents = details.documents, !documents.isEmpty {
            Logger.scix.debug("Found \(documents.count) bibcodes in documents array")
            return documents
        }

        // Fallback: Extract from solr.response.docs
        if let docs = details.solr?.response?.docs {
            let bibcodes = docs.compactMap { $0.bibcode }
            if !bibcodes.isEmpty {
                Logger.scix.debug("Found \(bibcodes.count) bibcodes in solr.response.docs")
                return bibcodes
            }
        }

        Logger.scix.warning("No bibcodes found in library response")
        return []
    }

    // MARK: - Library Creation

    /// Create a new library
    public func createLibrary(
        name: String,
        description: String? = nil,
        isPublic: Bool = false,
        bibcodes: [String]? = nil
    ) async throws -> SciXCreateLibraryResponse {
        let request = SciXCreateLibraryRequest(
            name: name,
            description: description,
            isPublic: isPublic,
            bibcodes: bibcodes
        )

        let body = try encoder.encode(request)
        let (data, _) = try await makeRequest(path: "/libraries", method: "POST", body: body)

        do {
            let response = try decoder.decode(SciXCreateLibraryResponse.self, from: data)
            Logger.scix.info("Created library: \(response.name) (id: \(response.id))")
            return response
        } catch {
            throw SciXLibraryError.decodingError(error)
        }
    }

    // MARK: - Document Management

    /// Add bibcodes to a library
    public func addDocuments(libraryID: String, bibcodes: [String]) async throws -> Int {
        let request = SciXModifyDocumentsRequest(bibcodes: bibcodes, action: .add)
        let body = try encoder.encode(request)

        let (data, _) = try await makeRequest(path: "/documents/\(libraryID)", method: "POST", body: body)

        do {
            let response = try decoder.decode(SciXModifyDocumentsResponse.self, from: data)
            let added = response.number_added ?? 0
            Logger.scix.info("Added \(added) documents to library \(libraryID)")
            return added
        } catch {
            throw SciXLibraryError.decodingError(error)
        }
    }

    /// Remove bibcodes from a library
    public func removeDocuments(libraryID: String, bibcodes: [String]) async throws -> Int {
        let request = SciXModifyDocumentsRequest(bibcodes: bibcodes, action: .remove)
        let body = try encoder.encode(request)

        let (data, _) = try await makeRequest(path: "/documents/\(libraryID)", method: "POST", body: body)

        do {
            let response = try decoder.decode(SciXModifyDocumentsResponse.self, from: data)
            let removed = response.number_removed ?? 0
            Logger.scix.info("Removed \(removed) documents from library \(libraryID)")
            return removed
        } catch {
            throw SciXLibraryError.decodingError(error)
        }
    }

    // MARK: - Metadata Updates

    /// Update library metadata (name, description, public status)
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

    // MARK: - Library Deletion

    /// Delete a library (requires owner permission)
    public func deleteLibrary(id: String) async throws {
        let (_, _) = try await makeRequest(path: "/documents/\(id)", method: "DELETE")
        Logger.scix.info("Deleted library \(id)")
    }

    // MARK: - Permissions

    /// Fetch permissions for a library
    public func fetchPermissions(libraryID: String) async throws -> [SciXPermission] {
        let (data, _) = try await makeRequest(path: "/permissions/\(libraryID)")

        // The API returns a peculiar format, try to parse it
        // Format could be {"<library_id>": [[email, permission], ...]}
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: [[String]]] {
                let permissions = json.values.first ?? []
                return permissions.compactMap { arr in
                    guard arr.count >= 2 else { return nil }
                    return SciXPermission(email: arr[0], permission: arr[1])
                }
            }
            throw SciXLibraryError.invalidResponse
        } catch let error as SciXLibraryError {
            throw error
        } catch {
            throw SciXLibraryError.decodingError(error)
        }
    }

    /// Set permission for a user on a library
    public func setPermission(
        libraryID: String,
        email: String,
        permission: CDSciXLibrary.PermissionLevel
    ) async throws {
        let request = SciXSetPermissionRequest(
            permissions: [(email: email, permission: permission.rawValue)]
        )

        let body = try encoder.encode(request)
        let (_, _) = try await makeRequest(path: "/permissions/\(libraryID)", method: "POST", body: body)

        Logger.scix.info("Set permission \(permission.rawValue) for \(email) on library \(libraryID)")
    }

    // MARK: - Ownership Transfer

    /// Transfer library ownership to another user (requires owner permission)
    public func transferOwnership(libraryID: String, toEmail: String) async throws {
        let request = SciXTransferOwnershipRequest(email: toEmail)
        let body = try encoder.encode(request)

        let (_, _) = try await makeRequest(path: "/transfer/\(libraryID)", method: "POST", body: body)

        Logger.scix.info("Transferred ownership of library \(libraryID) to \(toEmail)")
    }
}

// MARK: - Logger Extension

extension Logger {
    static let scix = Logger(subsystem: "com.imbib.PublicationManagerCore", category: "scix")
}
