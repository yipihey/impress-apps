//
//  DepositTarget.swift
//  ImpressDeposit
//
//  Protocol mirroring `SourcePlugin` but for outbound publishing to a
//  repository (Zenodo, OSF, Figshare, …). Per ADR-0014 D58.
//

import Foundation

// MARK: - Inputs

/// A single artifact being deposited to a repository.
public struct DepositArtifact: Sendable {
    /// User-facing title for the deposition.
    public var title: String

    /// Long-form description (abstract / readme content).
    public var description: String

    /// Author list. Each entry is `(displayName, optional ORCID)`.
    public var authors: [DepositAuthor]

    /// SPDX identifier for the license (e.g. `CC-BY-4.0`). Optional but
    /// strongly recommended — repositories typically require one.
    public var license: String?

    /// Free-form keywords / tags applied to the deposition.
    public var keywords: [String]

    /// File payload — what actually gets uploaded.
    public var file: DepositFile

    /// Optional Zenodo community / OSF project ID. Repository-specific
    /// behaviour: a Zenodo `community` slug, an OSF `project` GUID.
    public var community: String?

    public init(
        title: String,
        description: String = "",
        authors: [DepositAuthor] = [],
        license: String? = nil,
        keywords: [String] = [],
        file: DepositFile,
        community: String? = nil
    ) {
        self.title = title
        self.description = description
        self.authors = authors
        self.license = license
        self.keywords = keywords
        self.file = file
        self.community = community
    }
}

/// A single author / contributor on a deposition.
public struct DepositAuthor: Sendable, Hashable {
    public let name: String
    public let orcid: String?
    public let affiliation: String?

    public init(name: String, orcid: String? = nil, affiliation: String? = nil) {
        self.name = name
        self.orcid = orcid
        self.affiliation = affiliation
    }
}

/// File payload for a deposition. Either an on-disk URL (preferred —
/// streams without loading the whole thing into memory) or in-memory data.
public struct DepositFile: Sendable {
    public enum Body: Sendable {
        case fileURL(URL)
        case data(Data, mimeType: String)
    }

    /// Filename as it should appear in the repository (not necessarily
    /// the same as the local filename).
    public let filename: String

    public let body: Body

    public init(filename: String, body: Body) {
        self.filename = filename
        self.body = body
    }
}

// MARK: - Results

/// Successful deposit result.
public struct DepositResult: Sendable, Hashable {
    /// Minted or assigned DOI (e.g. `10.5281/zenodo.123456`).
    public let doi: String

    /// Public landing-page URL.
    public let repositoryURL: URL

    /// Repository-internal record ID (Zenodo deposition id, OSF GUID, …).
    public let recordID: String

    public init(doi: String, repositoryURL: URL, recordID: String) {
        self.doi = doi
        self.repositoryURL = repositoryURL
        self.recordID = recordID
    }
}

/// Progress callback payload during a deposit. Emitted at least once per
/// significant phase (create record, upload bytes, publish).
public struct UploadProgress: Sendable, Hashable {
    public enum Phase: String, Sendable {
        case creatingRecord
        case uploading
        case publishing
        case completed
    }

    public let phase: Phase
    public let bytesSent: Int64
    public let totalBytes: Int64

    public var fractionComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesSent) / Double(totalBytes)
    }

    public init(phase: Phase, bytesSent: Int64 = 0, totalBytes: Int64 = 0) {
        self.phase = phase
        self.bytesSent = bytesSent
        self.totalBytes = totalBytes
    }
}

// MARK: - Errors

public enum DepositError: LocalizedError, Sendable {
    case missingCredential(target: String)
    case invalidArtifact(reason: String)
    case httpError(statusCode: Int, body: String?)
    case networkError(underlying: String)
    case noDOIReturned
    case rateLimited(retryAfter: TimeInterval?)

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let target):
            return "No \(target) credential is configured. Add a token in Settings → Sources → \(target)."
        case .invalidArtifact(let reason):
            return "Cannot deposit: \(reason)"
        case .httpError(let code, let body):
            return "Repository returned HTTP \(code)\(body.map { ": \($0)" } ?? "")"
        case .networkError(let underlying):
            return "Network error: \(underlying)"
        case .noDOIReturned:
            return "Repository accepted the deposit but did not return a DOI."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate-limited. Try again in \(Int(retryAfter)) seconds."
            }
            return "Rate-limited. Try again shortly."
        }
    }
}

// MARK: - Credential descriptor

public enum DepositCredentialRequirement: Sendable {
    case none
    case apiToken(label: String, helpURL: URL?)
}

public struct DepositRateLimit: Sendable {
    public let requestsPerHour: Int
    public init(requestsPerHour: Int) { self.requestsPerHour = requestsPerHour }
}

// MARK: - Protocol

public protocol DepositTarget: Sendable {
    /// Stable identifier (e.g. `"zenodo"`, `"osf"`). Used as keychain key.
    var id: String { get }

    /// Display name for UI ("Zenodo", "OSF").
    var displayName: String { get }

    /// What credential the user must configure before depositing.
    var credentialRequirement: DepositCredentialRequirement { get }

    /// Rate-limit hint — informs the caller's throttling.
    var rateLimit: DepositRateLimit { get }

    /// Run the full create-upload-publish workflow. The progress closure is
    /// called from arbitrary threads; consumers should hop to the main
    /// actor before touching UI state.
    func deposit(
        artifact: DepositArtifact,
        progress: @Sendable @escaping (UploadProgress) async -> Void
    ) async throws -> DepositResult
}
