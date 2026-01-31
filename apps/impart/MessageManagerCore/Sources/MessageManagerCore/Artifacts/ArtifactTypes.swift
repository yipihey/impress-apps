//
//  ArtifactTypes.swift
//  MessageManagerCore
//
//  Artifact type definitions and impress:// URI scheme for research conversations.
//  Artifacts are versioned references to external resources that can be tracked
//  through the provenance system.
//

import Foundation

// MARK: - Artifact Type

/// Types of artifacts that can be referenced in research conversations.
public enum ArtifactType: String, Codable, Sendable, CaseIterable {
    /// Paper from imbib library (impress://imbib/papers/{citeKey})
    case paper

    /// Document from imprint (impress://imprint/documents/{id})
    case document

    /// Git repository (impress://repos/{host}/{owner}/{repo}@{commit})
    case repository

    /// Dataset (impress://data/{provider}/{dataset}@{version})
    case dataset

    /// Robot/hardware configuration (impress://robots/{namespace}/{robot}@{config})
    case robot

    /// Real-time data stream (impress://streams/{provider}/{stream})
    case stream

    /// External URL (for non-impress resources)
    case externalUrl

    /// Unknown or unrecognized artifact type
    case unknown

    /// Human-readable display name for the artifact type.
    public var displayName: String {
        switch self {
        case .paper: return "Paper"
        case .document: return "Document"
        case .repository: return "Repository"
        case .dataset: return "Dataset"
        case .robot: return "Robot/Hardware"
        case .stream: return "Data Stream"
        case .externalUrl: return "External Link"
        case .unknown: return "Unknown"
        }
    }

    /// SF Symbol icon name for the artifact type.
    public var iconName: String {
        switch self {
        case .paper: return "doc.text"
        case .document: return "doc.richtext"
        case .repository: return "chevron.left.forwardslash.chevron.right"
        case .dataset: return "tablecells"
        case .robot: return "gearshape.2"
        case .stream: return "waveform.path.ecg"
        case .externalUrl: return "link"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - Artifact URI

/// Parsed impress:// URI for artifact references.
/// Supports versioned references for reproducibility.
public struct ArtifactURI: Hashable, Codable, Sendable {
    /// The full URI string (e.g., "impress://imbib/papers/Fowler2012")
    public let uri: String

    /// The artifact type determined from the URI path
    public let type: ArtifactType

    /// The app or provider portion (e.g., "imbib", "repos", "data")
    public let provider: String

    /// Resource path within the provider
    public let resourcePath: String

    /// Version identifier if present (git SHA, timestamp, version number)
    public let version: String?

    /// Query parameters if any
    public let queryParameters: [String: String]

    /// Initialize with a URI string, parsing it into components.
    public init?(uri: String) {
        guard let url = URL(string: uri),
              url.scheme == "impress" else {
            return nil
        }

        self.uri = uri

        // Parse host as provider (e.g., "imbib", "repos")
        guard let host = url.host else { return nil }
        self.provider = host

        // Parse path and extract version if present (using @ notation)
        var path = url.path
        if path.hasPrefix("/") {
            path = String(path.dropFirst())
        }

        // Check for version suffix (e.g., "repo@abc123")
        if let atIndex = path.lastIndex(of: "@") {
            self.resourcePath = String(path[..<atIndex])
            self.version = String(path[path.index(after: atIndex)...])
        } else {
            self.resourcePath = path
            self.version = nil
        }

        // Parse query parameters
        var params: [String: String] = [:]
        if let components = URLComponents(string: uri),
           let queryItems = components.queryItems {
            for item in queryItems {
                params[item.name] = item.value ?? ""
            }
        }
        self.queryParameters = params

        // Determine artifact type from provider and path
        self.type = Self.determineType(provider: host, path: self.resourcePath)
    }

    /// Create a new artifact URI with explicit components.
    public init(
        type: ArtifactType,
        provider: String,
        resourcePath: String,
        version: String? = nil,
        queryParameters: [String: String] = [:]
    ) {
        self.type = type
        self.provider = provider
        self.resourcePath = resourcePath
        self.version = version
        self.queryParameters = queryParameters

        // Construct URI string
        var uriString = "impress://\(provider)/\(resourcePath)"
        if let version = version {
            uriString += "@\(version)"
        }
        if !queryParameters.isEmpty {
            let queryString = queryParameters
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "&")
            uriString += "?\(queryString)"
        }
        self.uri = uriString
    }

    /// Determine artifact type from provider and path.
    private static func determineType(provider: String, path: String) -> ArtifactType {
        switch provider {
        case "imbib":
            if path.hasPrefix("papers/") {
                return .paper
            }
            return .unknown

        case "imprint":
            if path.hasPrefix("documents/") {
                return .document
            }
            return .unknown

        case "repos":
            return .repository

        case "data":
            return .dataset

        case "robots":
            return .robot

        case "streams":
            return .stream

        default:
            return .unknown
        }
    }

    /// Display name derived from the resource path.
    public var displayName: String {
        // Extract the last path component as a reasonable display name
        let components = resourcePath.split(separator: "/")
        if let last = components.last {
            return String(last)
        }
        return resourcePath
    }
}

// MARK: - URI Builders

public extension ArtifactURI {
    /// Create a paper artifact URI.
    /// - Parameters:
    ///   - citeKey: The BibTeX cite key
    ///   - version: Optional version (timestamp or sync token)
    static func paper(citeKey: String, version: String? = nil) -> ArtifactURI {
        ArtifactURI(
            type: .paper,
            provider: "imbib",
            resourcePath: "papers/\(citeKey)",
            version: version
        )
    }

    /// Create a document artifact URI.
    /// - Parameters:
    ///   - documentId: The document identifier
    ///   - version: Optional version identifier
    static func document(id documentId: String, version: String? = nil) -> ArtifactURI {
        ArtifactURI(
            type: .document,
            provider: "imprint",
            resourcePath: "documents/\(documentId)",
            version: version
        )
    }

    /// Create a repository artifact URI.
    /// - Parameters:
    ///   - host: Repository host (e.g., "github.com", "gitlab.com")
    ///   - owner: Repository owner
    ///   - repo: Repository name
    ///   - commit: Git commit SHA (required for reproducibility)
    static func repository(
        host: String,
        owner: String,
        repo: String,
        commit: String
    ) -> ArtifactURI {
        ArtifactURI(
            type: .repository,
            provider: "repos",
            resourcePath: "\(host)/\(owner)/\(repo)",
            version: commit
        )
    }

    /// Create a dataset artifact URI.
    /// - Parameters:
    ///   - provider: Data provider (e.g., "zenodo", "figshare")
    ///   - dataset: Dataset identifier
    ///   - version: Dataset version
    static func dataset(
        provider dataProvider: String,
        dataset: String,
        version: String
    ) -> ArtifactURI {
        ArtifactURI(
            type: .dataset,
            provider: "data",
            resourcePath: "\(dataProvider)/\(dataset)",
            version: version
        )
    }

    /// Create a robot/hardware configuration artifact URI.
    /// - Parameters:
    ///   - namespace: Robot namespace
    ///   - robot: Robot identifier
    ///   - config: Configuration version
    static func robot(
        namespace: String,
        robot: String,
        config: String
    ) -> ArtifactURI {
        ArtifactURI(
            type: .robot,
            provider: "robots",
            resourcePath: "\(namespace)/\(robot)",
            version: config
        )
    }

    /// Create a data stream artifact URI.
    /// - Parameters:
    ///   - provider: Stream provider
    ///   - stream: Stream identifier
    static func stream(
        provider streamProvider: String,
        stream: String
    ) -> ArtifactURI {
        ArtifactURI(
            type: .stream,
            provider: "streams",
            resourcePath: "\(streamProvider)/\(stream)"
        )
    }

    /// Create an external URL artifact.
    /// - Parameter url: The external URL
    static func externalURL(_ url: URL) -> ArtifactURI {
        ArtifactURI(
            type: .externalUrl,
            provider: "external",
            resourcePath: url.absoluteString
        )
    }
}

// MARK: - Mention Type

/// How an artifact was mentioned in a message.
public enum ArtifactMentionType: String, Codable, Sendable {
    /// First introduction of the artifact to the conversation
    case introduced

    /// Subsequent reference to a previously introduced artifact
    case referenced

    /// Artifact was cited as supporting evidence
    case cited

    /// Discussion concluded with this artifact
    case concluded

    /// Artifact was explicitly linked to another artifact
    case linked

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .introduced: return "Introduced"
        case .referenced: return "Referenced"
        case .cited: return "Cited"
        case .concluded: return "Concluded"
        case .linked: return "Linked"
        }
    }
}

// MARK: - Artifact Metadata

/// Additional metadata that can be stored with an artifact reference.
public struct ArtifactMetadata: Codable, Sendable, Equatable {
    /// Title or name of the artifact
    public var title: String?

    /// Authors or contributors
    public var authors: [String]?

    /// Publication or creation date
    public var date: Date?

    /// DOI if applicable
    public var doi: String?

    /// arXiv ID if applicable
    public var arxivId: String?

    /// Abstract or description
    public var abstract: String?

    /// Tags or keywords
    public var tags: [String]?

    /// Custom key-value pairs for extensibility
    public var custom: [String: String]?

    public init(
        title: String? = nil,
        authors: [String]? = nil,
        date: Date? = nil,
        doi: String? = nil,
        arxivId: String? = nil,
        abstract: String? = nil,
        tags: [String]? = nil,
        custom: [String: String]? = nil
    ) {
        self.title = title
        self.authors = authors
        self.date = date
        self.doi = doi
        self.arxivId = arxivId
        self.abstract = abstract
        self.tags = tags
        self.custom = custom
    }
}

// MARK: - URI Pattern Matching

public extension ArtifactURI {
    /// Check if this URI matches a pattern.
    /// Supports wildcards (*) in the pattern.
    func matches(pattern: String) -> Bool {
        guard let patternURI = ArtifactURI(uri: pattern) else {
            return false
        }

        // Provider must match (no wildcards)
        if patternURI.provider != provider && patternURI.provider != "*" {
            return false
        }

        // Check resource path with wildcards
        let patternPath = patternURI.resourcePath
        let resourcePath = self.resourcePath

        // Simple wildcard matching
        if patternPath == "*" {
            return true
        }

        if patternPath.hasSuffix("/*") {
            let prefix = String(patternPath.dropLast(2))
            return resourcePath.hasPrefix(prefix)
        }

        return patternPath == resourcePath
    }

    /// Extract the cite key from a paper URI.
    var citeKey: String? {
        guard type == .paper else { return nil }
        let components = resourcePath.split(separator: "/")
        guard components.count >= 2, components[0] == "papers" else { return nil }
        return String(components[1])
    }

    /// Extract repository components from a repository URI.
    var repositoryComponents: (host: String, owner: String, repo: String)? {
        guard type == .repository else { return nil }
        let components = resourcePath.split(separator: "/")
        guard components.count >= 3 else { return nil }
        return (
            host: String(components[0]),
            owner: String(components[1]),
            repo: String(components[2])
        )
    }
}
