//
//  CredentialTypes.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation

// MARK: - Credential Type

/// Types of credentials that can be stored
public enum CredentialType: String, Sendable, CaseIterable {
    case apiKey
    case email

    public var displayName: String {
        switch self {
        case .apiKey: return "API Key"
        case .email: return "Email"
        }
    }

    /// Keychain key suffix for this credential type
    var keychainSuffix: String {
        rawValue
    }
}

// MARK: - Stored Credential

/// A credential stored for a specific source
public struct StoredCredential: Sendable, Equatable {
    public let sourceID: String
    public let type: CredentialType
    public let value: String
    public let dateStored: Date

    public init(
        sourceID: String,
        type: CredentialType,
        value: String,
        dateStored: Date = Date()
    ) {
        self.sourceID = sourceID
        self.type = type
        self.value = value
        self.dateStored = dateStored
    }
}

// MARK: - Credential Status

/// Status of credentials for a source
public enum CredentialStatus: Sendable, Equatable {
    /// No credentials needed for this source
    case notRequired

    /// Credentials required but not stored
    case missing

    /// Credentials stored and valid
    case valid

    /// Credentials stored but invalid/expired
    case invalid(reason: String)

    /// Credentials optional and not stored
    case optionalMissing

    /// Credentials optional and stored
    case optionalValid

    public var isUsable: Bool {
        switch self {
        case .notRequired, .valid, .optionalMissing, .optionalValid:
            return true
        case .missing, .invalid:
            return false
        }
    }

    public var displayDescription: String {
        switch self {
        case .notRequired:
            return "No credentials required"
        case .missing:
            return "Credentials required"
        case .valid:
            return "Credentials configured"
        case .invalid(let reason):
            return "Invalid: \(reason)"
        case .optionalMissing:
            return "Optional credentials not set"
        case .optionalValid:
            return "Optional credentials configured"
        }
    }

    public var iconName: String {
        switch self {
        case .notRequired, .valid, .optionalValid:
            return "checkmark.circle.fill"
        case .missing, .invalid:
            return "exclamationmark.circle.fill"
        case .optionalMissing:
            return "info.circle"
        }
    }
}

// MARK: - Source Credential Info

/// Complete credential information for a source
public struct SourceCredentialInfo: Sendable, Identifiable, Equatable {
    public let sourceID: String
    public let sourceName: String
    public let requirement: CredentialRequirement
    public let status: CredentialStatus
    public let registrationURL: URL?

    public var id: String { sourceID }

    public init(
        sourceID: String,
        sourceName: String,
        requirement: CredentialRequirement,
        status: CredentialStatus,
        registrationURL: URL? = nil
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.requirement = requirement
        self.status = status
        self.registrationURL = registrationURL
    }
}
