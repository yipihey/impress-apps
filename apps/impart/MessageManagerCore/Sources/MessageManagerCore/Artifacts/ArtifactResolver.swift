//
//  ArtifactResolver.swift
//  MessageManagerCore
//
//  Resolver service for impress:// URIs across Impress suite apps.
//  Handles cross-app communication to fetch artifact details.
//

import Foundation
import OSLog

private let resolverLogger = Logger(subsystem: "com.impart", category: "artifact-resolver")

// MARK: - Resolved Artifact

/// A resolved artifact with full details fetched from the source app.
public struct ResolvedArtifact: Sendable {
    /// The original artifact reference.
    public let reference: ArtifactReference

    /// Whether resolution was successful.
    public let isResolved: Bool

    /// Additional data fetched from the source.
    public let resolvedData: ResolvedArtifactData?

    /// Error message if resolution failed.
    public let error: String?

    public init(
        reference: ArtifactReference,
        isResolved: Bool,
        resolvedData: ResolvedArtifactData? = nil,
        error: String? = nil
    ) {
        self.reference = reference
        self.isResolved = isResolved
        self.resolvedData = resolvedData
        self.error = error
    }
}

/// Data resolved from the source app.
public enum ResolvedArtifactData: Sendable {
    case paper(PaperArtifactData)
    case document(DocumentArtifactData)
    case repository(RepositoryArtifactData)
    case dataset(DatasetArtifactData)
}

/// Resolved paper data from imbib.
public struct PaperArtifactData: Codable, Sendable {
    public let citeKey: String
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let journal: String?
    public let doi: String?
    public let arxivId: String?
    public let abstract: String?
    public let pdfURL: URL?
    public let bibtex: String?

    public init(
        citeKey: String,
        title: String,
        authors: [String],
        year: Int? = nil,
        journal: String? = nil,
        doi: String? = nil,
        arxivId: String? = nil,
        abstract: String? = nil,
        pdfURL: URL? = nil,
        bibtex: String? = nil
    ) {
        self.citeKey = citeKey
        self.title = title
        self.authors = authors
        self.year = year
        self.journal = journal
        self.doi = doi
        self.arxivId = arxivId
        self.abstract = abstract
        self.pdfURL = pdfURL
        self.bibtex = bibtex
    }
}

/// Resolved document data from imprint.
public struct DocumentArtifactData: Codable, Sendable {
    public let documentId: String
    public let title: String
    public let version: String?
    public let lastModified: Date
    public let wordCount: Int?
    public let previewText: String?

    public init(
        documentId: String,
        title: String,
        version: String? = nil,
        lastModified: Date,
        wordCount: Int? = nil,
        previewText: String? = nil
    ) {
        self.documentId = documentId
        self.title = title
        self.version = version
        self.lastModified = lastModified
        self.wordCount = wordCount
        self.previewText = previewText
    }
}

/// Resolved repository data.
public struct RepositoryArtifactData: Codable, Sendable {
    public let host: String
    public let owner: String
    public let repo: String
    public let commit: String
    public let branch: String?
    public let description: String?
    public let language: String?
    public let stars: Int?
    public let lastCommitDate: Date?

    public init(
        host: String,
        owner: String,
        repo: String,
        commit: String,
        branch: String? = nil,
        description: String? = nil,
        language: String? = nil,
        stars: Int? = nil,
        lastCommitDate: Date? = nil
    ) {
        self.host = host
        self.owner = owner
        self.repo = repo
        self.commit = commit
        self.branch = branch
        self.description = description
        self.language = language
        self.stars = stars
        self.lastCommitDate = lastCommitDate
    }
}

/// Resolved dataset data.
public struct DatasetArtifactData: Codable, Sendable {
    public let provider: String
    public let datasetId: String
    public let version: String
    public let title: String
    public let description: String?
    public let size: Int64?
    public let format: String?
    public let license: String?

    public init(
        provider: String,
        datasetId: String,
        version: String,
        title: String,
        description: String? = nil,
        size: Int64? = nil,
        format: String? = nil,
        license: String? = nil
    ) {
        self.provider = provider
        self.datasetId = datasetId
        self.version = version
        self.title = title
        self.description = description
        self.size = size
        self.format = format
        self.license = license
    }
}

// MARK: - Artifact Resolver

/// Actor for resolving impress:// URIs to full artifact data.
public actor ArtifactResolver {

    // MARK: - Properties

    /// HTTP session for API requests.
    private let session: URLSession

    /// Cache of resolved artifacts.
    private var cache: [String: ResolvedArtifact] = [:]

    /// Cache expiration time.
    private let cacheExpiration: TimeInterval = 300 // 5 minutes

    /// Last cache cleanup time.
    private var lastCacheCleanup: Date = Date()

    /// Port for imbib HTTP API.
    private let imbibPort: Int = 23121

    /// Port for imprint HTTP API.
    private let imprintPort: Int = 23123

    // MARK: - Initialization

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Resolution

    /// Resolve an artifact URI to full data.
    public func resolve(_ uri: String) async throws -> ResolvedArtifact {
        // Check cache
        if let cached = cache[uri] {
            return cached
        }

        guard let artifactURI = ArtifactURI(uri: uri) else {
            throw ArtifactResolverError.invalidURI(uri)
        }

        let resolved: ResolvedArtifact

        switch artifactURI.type {
        case .paper:
            resolved = try await resolvePaper(uri: artifactURI)
        case .document:
            resolved = try await resolveDocument(uri: artifactURI)
        case .repository:
            resolved = try await resolveRepository(uri: artifactURI)
        case .dataset:
            resolved = try await resolveDataset(uri: artifactURI)
        default:
            resolved = ResolvedArtifact(
                reference: ArtifactReference(
                    uri: artifactURI,
                    displayName: artifactURI.displayName
                ),
                isResolved: false,
                error: "Unsupported artifact type: \(artifactURI.type)"
            )
        }

        // Cache the result
        cache[uri] = resolved

        return resolved
    }

    /// Resolve multiple URIs concurrently.
    public func resolveAll(_ uris: [String]) async -> [String: ResolvedArtifact] {
        await withTaskGroup(of: (String, ResolvedArtifact).self) { group in
            for uri in uris {
                group.addTask {
                    let resolved = try? await self.resolve(uri)
                    return (uri, resolved ?? ResolvedArtifact(
                        reference: ArtifactReference(
                            uri: ArtifactURI(type: .unknown, provider: "unknown", resourcePath: uri),
                            displayName: uri
                        ),
                        isResolved: false,
                        error: "Resolution failed"
                    ))
                }
            }

            var results: [String: ResolvedArtifact] = [:]
            for await (uri, resolved) in group {
                results[uri] = resolved
            }
            return results
        }
    }

    // MARK: - Paper Resolution (imbib)

    /// Resolve a paper from imbib.
    public func resolvePaper(citeKey: String) async throws -> ResolvedArtifact {
        let uri = ArtifactURI.paper(citeKey: citeKey)
        return try await resolvePaper(uri: uri)
    }

    private func resolvePaper(uri: ArtifactURI) async throws -> ResolvedArtifact {
        guard let citeKey = uri.citeKey else {
            throw ArtifactResolverError.invalidURI(uri.uri)
        }

        // Try imbib HTTP API
        let url = URL(string: "http://localhost:\(imbibPort)/api/publications/\(citeKey)")!

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw ArtifactResolverError.apiError("imbib returned status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }

            let decoder = JSONDecoder()
            let paperData = try decoder.decode(PaperArtifactData.self, from: data)

            let reference = ArtifactReference.paper(
                citeKey: citeKey,
                title: paperData.title,
                authors: paperData.authors,
                year: paperData.year,
                doi: paperData.doi,
                arxivId: paperData.arxivId
            )

            return ResolvedArtifact(
                reference: reference,
                isResolved: true,
                resolvedData: .paper(paperData)
            )
        } catch {
            resolverLogger.warning("Failed to resolve paper \(citeKey): \(error.localizedDescription)")

            // Return unresolved reference
            let reference = ArtifactReference(
                uri: uri,
                displayName: citeKey
            )

            return ResolvedArtifact(
                reference: reference,
                isResolved: false,
                error: error.localizedDescription
            )
        }
    }

    // MARK: - Document Resolution (imprint)

    /// Resolve a document from imprint.
    public func resolveDocument(id documentId: String) async throws -> ResolvedArtifact {
        let uri = ArtifactURI.document(id: documentId)
        return try await resolveDocument(uri: uri)
    }

    private func resolveDocument(uri: ArtifactURI) async throws -> ResolvedArtifact {
        let documentId = uri.resourcePath.replacingOccurrences(of: "documents/", with: "")

        // Try imprint HTTP API
        let url = URL(string: "http://localhost:\(imprintPort)/api/documents/\(documentId)")!

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw ArtifactResolverError.apiError("imprint returned status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let docData = try decoder.decode(DocumentArtifactData.self, from: data)

            let reference = ArtifactReference.document(
                id: documentId,
                title: docData.title,
                version: docData.version
            )

            return ResolvedArtifact(
                reference: reference,
                isResolved: true,
                resolvedData: .document(docData)
            )
        } catch {
            resolverLogger.warning("Failed to resolve document \(documentId): \(error.localizedDescription)")

            let reference = ArtifactReference(
                uri: uri,
                displayName: documentId
            )

            return ResolvedArtifact(
                reference: reference,
                isResolved: false,
                error: error.localizedDescription
            )
        }
    }

    // MARK: - Repository Resolution

    /// Resolve a repository.
    public func resolveRepository(
        host: String,
        owner: String,
        repo: String,
        commit: String
    ) async throws -> ResolvedArtifact {
        let uri = ArtifactURI.repository(host: host, owner: owner, repo: repo, commit: commit)
        return try await resolveRepository(uri: uri)
    }

    private func resolveRepository(uri: ArtifactURI) async throws -> ResolvedArtifact {
        guard let components = uri.repositoryComponents else {
            throw ArtifactResolverError.invalidURI(uri.uri)
        }

        // For GitHub, use the public API
        if components.host == "github.com" {
            let apiURL = URL(string: "https://api.github.com/repos/\(components.owner)/\(components.repo)")!

            do {
                var request = URLRequest(url: apiURL)
                request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    throw ArtifactResolverError.apiError("GitHub API returned status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }

                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

                let repoData = RepositoryArtifactData(
                    host: components.host,
                    owner: components.owner,
                    repo: components.repo,
                    commit: uri.version ?? "HEAD",
                    branch: json?["default_branch"] as? String,
                    description: json?["description"] as? String,
                    language: json?["language"] as? String,
                    stars: json?["stargazers_count"] as? Int
                )

                let reference = ArtifactReference.repository(
                    host: components.host,
                    owner: components.owner,
                    repo: components.repo,
                    commit: uri.version ?? "HEAD",
                    title: "\(components.owner)/\(components.repo)"
                )

                return ResolvedArtifact(
                    reference: reference,
                    isResolved: true,
                    resolvedData: .repository(repoData)
                )
            } catch {
                resolverLogger.warning("Failed to resolve repository: \(error.localizedDescription)")
            }
        }

        // Return unresolved reference
        let reference = ArtifactReference.repository(
            host: components.host,
            owner: components.owner,
            repo: components.repo,
            commit: uri.version ?? "HEAD"
        )

        return ResolvedArtifact(
            reference: reference,
            isResolved: false,
            error: "Repository resolution not available"
        )
    }

    // MARK: - Dataset Resolution

    private func resolveDataset(uri: ArtifactURI) async throws -> ResolvedArtifact {
        // Placeholder - would integrate with data providers like Zenodo, Figshare
        let reference = ArtifactReference(
            uri: uri,
            displayName: uri.displayName
        )

        return ResolvedArtifact(
            reference: reference,
            isResolved: false,
            error: "Dataset resolution not yet implemented"
        )
    }

    // MARK: - Cache Management

    /// Clear the resolution cache.
    public func clearCache() {
        cache.removeAll()
        lastCacheCleanup = Date()
    }

    /// Get cached artifact if available.
    public func getCached(_ uri: String) -> ResolvedArtifact? {
        cache[uri]
    }
}

// MARK: - Errors

/// Errors from artifact resolution.
public enum ArtifactResolverError: LocalizedError {
    case invalidURI(String)
    case apiError(String)
    case timeout
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURI(let uri):
            return "Invalid artifact URI: \(uri)"
        case .apiError(let message):
            return "API error: \(message)"
        case .timeout:
            return "Resolution timed out"
        case .notFound(let uri):
            return "Artifact not found: \(uri)"
        }
    }
}
