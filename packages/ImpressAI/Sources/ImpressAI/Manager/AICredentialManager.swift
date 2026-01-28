import Foundation
import KeychainSwift

/// Manages secure storage of AI provider credentials.
public actor AICredentialManager {
    /// Shared singleton instance.
    public static let shared = AICredentialManager()

    private var _keychain: KeychainSwift?
    private let keychainPrefix = "com.impressai.credentials"

    /// Lazily initialized Keychain to defer permission dialog.
    private var keychain: KeychainSwift {
        if _keychain == nil {
            let keychain = KeychainSwift()
            keychain.synchronizable = false
            _keychain = keychain
        }
        return _keychain!
    }

    public init() {}

    /// Stores a credential value for a provider field.
    ///
    /// - Parameters:
    ///   - value: The credential value to store.
    ///   - providerId: The provider identifier.
    ///   - field: The credential field identifier.
    /// - Throws: `AIError.credentialError` if storage fails.
    public func store(_ value: String, for providerId: String, field: String) async throws {
        let key = makeKey(providerId: providerId, field: field)

        if value.isEmpty {
            keychain.delete(key)
        } else {
            guard keychain.set(value, forKey: key) else {
                throw AIError.credentialError("Failed to store credential")
            }
        }
    }

    /// Retrieves a credential value for a provider field.
    ///
    /// - Parameters:
    ///   - providerId: The provider identifier.
    ///   - field: The credential field identifier.
    /// - Returns: The credential value, or nil if not found.
    public func retrieve(for providerId: String, field: String) async -> String? {
        let key = makeKey(providerId: providerId, field: field)
        return keychain.get(key)
    }

    /// Checks if a credential exists for a provider field.
    ///
    /// - Parameters:
    ///   - providerId: The provider identifier.
    ///   - field: The credential field identifier.
    /// - Returns: True if the credential exists and is non-empty.
    public func hasCredential(for providerId: String, field: String) async -> Bool {
        let value = await retrieve(for: providerId, field: field)
        return value != nil && !value!.isEmpty
    }

    /// Deletes a credential for a provider field.
    ///
    /// - Parameters:
    ///   - providerId: The provider identifier.
    ///   - field: The credential field identifier.
    public func delete(for providerId: String, field: String) async {
        let key = makeKey(providerId: providerId, field: field)
        keychain.delete(key)
    }

    /// Deletes all credentials for a provider.
    ///
    /// - Parameter providerId: The provider identifier.
    public func deleteAll(for providerId: String) async {
        // We can't enumerate keys efficiently, so this is a best-effort
        // Delete common field names
        let commonFields = ["apiKey", "endpoint", "authToken", "email", "orgId"]
        for field in commonFields {
            await delete(for: providerId, field: field)
        }
    }

    /// Validates an API key format.
    ///
    /// - Parameters:
    ///   - value: The API key to validate.
    ///   - providerId: Optional provider ID for provider-specific validation.
    /// - Returns: True if the format appears valid.
    public nonisolated func validateAPIKey(_ value: String, for providerId: String? = nil) -> Bool {
        guard !value.isEmpty else { return false }

        // Provider-specific validation
        if let providerId = providerId {
            switch providerId {
            case "anthropic":
                return value.hasPrefix("sk-ant-")
            case "openai":
                return value.hasPrefix("sk-")
            case "google":
                return value.count >= 20
            case "openrouter":
                return value.hasPrefix("sk-or-")
            default:
                break
            }
        }

        // Generic validation: must be at least 10 characters
        return value.count >= 10
    }

    // MARK: - Private Methods

    private func makeKey(providerId: String, field: String) -> String {
        "\(keychainPrefix).\(providerId).\(field)"
    }
}

/// Status of credentials for a provider.
public struct AIProviderCredentialInfo: Sendable, Identifiable {
    public var id: String { providerId }

    /// The provider identifier.
    public let providerId: String

    /// The provider's human-readable name.
    public let providerName: String

    /// Status of each credential field.
    public let fieldStatus: [String: AICredentialFieldStatus]

    /// Whether all required credentials are configured.
    public var isConfigured: Bool {
        fieldStatus.values.allSatisfy { status in
            switch status {
            case .valid, .notRequired:
                return true
            case .missing, .invalid:
                return false
            }
        }
    }

    public init(providerId: String, providerName: String, fieldStatus: [String: AICredentialFieldStatus]) {
        self.providerId = providerId
        self.providerName = providerName
        self.fieldStatus = fieldStatus
    }
}

/// Status of a single credential field.
public enum AICredentialFieldStatus: Sendable {
    /// Credential is present and appears valid.
    case valid

    /// Credential is not required for this provider.
    case notRequired

    /// Credential is missing.
    case missing

    /// Credential is present but invalid.
    case invalid(reason: String)

    /// Whether this status allows the provider to function.
    public var isUsable: Bool {
        switch self {
        case .valid, .notRequired:
            return true
        case .missing, .invalid:
            return false
        }
    }
}
