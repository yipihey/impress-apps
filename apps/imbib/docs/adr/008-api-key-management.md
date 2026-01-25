# ADR-008: API Key Management

## Status

Accepted

## Date

2026-01-04

## Context

Several publication sources require API keys:

| Source | Requirement | Notes |
|--------|-------------|-------|
| NASA ADS | Required | 5000 requests/day with key |
| PubMed | Recommended | 10 req/sec with key vs 3 without |
| Semantic Scholar | Optional | Higher rate limits with key |
| Crossref | Optional | Polite pool access with email |
| OpenAlex | Optional | Higher rate limits with email |

We need to:
- Store API keys securely
- Provide UI for key management
- Handle missing/invalid keys gracefully
- Support different auth types (API key, email-as-identifier)

## Decision

Use **Keychain** for secure storage with a **centralized credential manager**:

1. Store sensitive credentials in Keychain (not UserDefaults)
2. Provide Settings UI for credential management
3. Each source declares its authentication requirements
4. Graceful degradation when credentials missing
5. Sync credentials via iCloud Keychain (optional, user-controlled)

## Rationale

### Why Keychain?

| Storage Option | Security | Sync | Appropriate For |
|----------------|----------|------|-----------------|
| UserDefaults | None | iCloud | Non-sensitive preferences |
| Keychain | Encrypted | iCloud Keychain | API keys, passwords |
| Core Data | App-level | CloudKit | User data |
| Secure Enclave | Hardware | None | Biometric, high-security |

API keys grant access to services and have rate limit implications. Keychain is the appropriate storage.

### Why Not Environment Variables?

- Not available on iOS
- Requires app rebuild to change
- Can't sync across devices

### Why Graceful Degradation?

Users should be able to:
- Try the app before entering API keys
- Use sources that don't require keys
- Understand what they're missing

## Implementation

### Credential Types

```swift
public enum CredentialType: String, Codable, CaseIterable {
    case apiKey          // Bearer token or query param
    case email           // Polite pool identifier (Crossref, OpenAlex)
    case apiKeyWithEmail // Both required (some enterprise APIs)
}

public struct SourceCredentialRequirement: Codable {
    let sourceID: String
    let type: CredentialType
    let isRequired: Bool
    let registrationURL: URL?
    let description: String
}
```

### SourceMetadata Extension

```swift
public struct SourceMetadata: Codable, Identifiable, Sendable {
    // ... existing fields ...

    /// Authentication requirements
    public let credentialRequirement: SourceCredentialRequirement?

    /// What features are unavailable without credentials
    public let unauthenticatedLimitations: [String]?
}

// Example
let adsMetadata = SourceMetadata(
    id: "ads",
    name: "NASA ADS",
    // ...
    credentialRequirement: SourceCredentialRequirement(
        sourceID: "ads",
        type: .apiKey,
        isRequired: true,
        registrationURL: URL(string: "https://ui.adsabs.harvard.edu/user/settings/token"),
        description: "ADS requires an API key. Get one free at the ADS website."
    ),
    unauthenticatedLimitations: ["Search unavailable without API key"]
)
```

### Credential Manager

```swift
public actor CredentialManager {
    public static let shared = CredentialManager()

    private let keychain = KeychainWrapper.standard

    // MARK: - Storage

    public func store(apiKey: String, for sourceID: String) throws {
        let key = keychainKey(for: sourceID, type: .apiKey)
        guard keychain.set(apiKey, forKey: key, withAccessibility: .afterFirstUnlock) else {
            throw CredentialError.storageFailed
        }
    }

    public func store(email: String, for sourceID: String) throws {
        let key = keychainKey(for: sourceID, type: .email)
        guard keychain.set(email, forKey: key, withAccessibility: .afterFirstUnlock) else {
            throw CredentialError.storageFailed
        }
    }

    public func retrieve(for sourceID: String, type: CredentialType) -> String? {
        let key = keychainKey(for: sourceID, type: type)
        return keychain.string(forKey: key)
    }

    public func delete(for sourceID: String, type: CredentialType) {
        let key = keychainKey(for: sourceID, type: type)
        keychain.removeObject(forKey: key)
    }

    // MARK: - Validation

    public func hasValidCredentials(for source: SourceMetadata) -> Bool {
        guard let requirement = source.credentialRequirement else {
            return true  // No credentials required
        }

        switch requirement.type {
        case .apiKey:
            return retrieve(for: source.id, type: .apiKey) != nil
        case .email:
            return retrieve(for: source.id, type: .email) != nil
        case .apiKeyWithEmail:
            return retrieve(for: source.id, type: .apiKey) != nil &&
                   retrieve(for: source.id, type: .email) != nil
        }
    }

    // MARK: - Private

    private func keychainKey(for sourceID: String, type: CredentialType) -> String {
        "com.imbib.source.\(sourceID).\(type.rawValue)"
    }
}

public enum CredentialError: LocalizedError {
    case storageFailed
    case notFound
    case invalid

    public var errorDescription: String? {
        switch self {
        case .storageFailed: return "Failed to store credential securely"
        case .notFound: return "Credential not found"
        case .invalid: return "Credential is invalid"
        }
    }
}
```

### Source Plugin Integration

```swift
public actor ADSSource: SourcePlugin {
    public let metadata = SourceMetadata(
        id: "ads",
        name: "NASA ADS",
        // ... with credentialRequirement
    )

    private var apiKey: String? {
        get async {
            await CredentialManager.shared.retrieve(for: "ads", type: .apiKey)
        }
    }

    public func search(query: String) async throws -> [SearchResult] {
        guard let key = await apiKey else {
            throw SourceError.authenticationRequired
        }

        var request = URLRequest(url: searchURL(for: query))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        // ... execute request
    }
}
```

### Graceful Degradation

```swift
public actor SourceManager {
    /// Returns sources that can be used (have credentials or don't require them)
    public func availableSources() async -> [SourceMetadata] {
        await plugins.values.asyncFilter { plugin in
            await CredentialManager.shared.hasValidCredentials(for: plugin.metadata)
        }.map { $0.metadata }
    }

    /// Returns sources that need credentials
    public func unavailableSources() async -> [SourceMetadata] {
        await plugins.values.asyncFilter { plugin in
            guard let req = plugin.metadata.credentialRequirement else { return false }
            return req.isRequired &&
                   !(await CredentialManager.shared.hasValidCredentials(for: plugin.metadata))
        }.map { $0.metadata }
    }
}
```

### Settings UI

```swift
struct SourceCredentialsView: View {
    @State private var sources: [SourceMetadata] = []
    @State private var credentials: [String: String] = [:]

    var body: some View {
        Form {
            Section("API Keys") {
                ForEach(sources.filter { $0.credentialRequirement != nil }) { source in
                    SourceCredentialRow(source: source)
                }
            }

            Section {
                Text("API keys are stored securely in your device's Keychain and can sync via iCloud Keychain if enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Source Credentials")
    }
}

struct SourceCredentialRow: View {
    let source: SourceMetadata
    @State private var apiKey: String = ""
    @State private var isEditing = false
    @State private var hasCredential = false

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(source.name)
                if let req = source.credentialRequirement {
                    Text(req.isRequired ? "Required" : "Optional")
                        .font(.caption)
                        .foregroundStyle(req.isRequired ? .red : .secondary)
                }
            }

            Spacer()

            if hasCredential {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Button(hasCredential ? "Edit" : "Add") {
                isEditing = true
            }
        }
        .sheet(isPresented: $isEditing) {
            CredentialEntrySheet(source: source, onSave: { key in
                Task {
                    try await CredentialManager.shared.store(apiKey: key, for: source.id)
                    hasCredential = true
                }
            })
        }
        .task {
            hasCredential = await CredentialManager.shared.hasValidCredentials(for: source)
        }
    }
}

struct CredentialEntrySheet: View {
    let source: SourceMetadata
    let onSave: (String) -> Void

    @State private var apiKey = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API Key", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                }

                if let requirement = source.credentialRequirement {
                    Section {
                        Text(requirement.description)

                        if let url = requirement.registrationURL {
                            Link("Get API Key", destination: url)
                        }
                    }
                }
            }
            .navigationTitle(source.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(apiKey)
                        dismiss()
                    }
                    .disabled(apiKey.isEmpty)
                }
            }
        }
    }
}
```

### Search UI Integration

```swift
struct SearchView: View {
    @State private var viewModel: SearchViewModel
    @State private var showCredentialsPrompt = false

    var body: some View {
        VStack {
            // Search UI...

            if !viewModel.unavailableSources.isEmpty {
                Button {
                    showCredentialsPrompt = true
                } label: {
                    Label(
                        "\(viewModel.unavailableSources.count) sources need API keys",
                        systemImage: "key"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
        .sheet(isPresented: $showCredentialsPrompt) {
            NavigationStack {
                SourceCredentialsView()
            }
        }
    }
}
```

## Consequences

### Positive

- API keys stored securely (encrypted at rest)
- iCloud Keychain sync available (user choice)
- Clear UI for credential management
- Graceful degradation for missing credentials
- Sources self-document their requirements

### Negative

- Keychain API is verbose (mitigated by wrapper)
- Users must obtain API keys manually
- Some sources inaccessible until keys added

### Mitigations

- Direct links to API key registration pages
- Clear messaging about what's unavailable
- Email-based auth (Crossref, OpenAlex) is frictionless
- Most-used sources (arXiv, Crossref) work without keys

## Alternatives Considered

### UserDefaults Storage

Insecure. API keys would be readable by anyone with device access or backup.

### Built-in API Keys

Including our own keys would:
- Violate most APIs' terms of service
- Create rate limit issues at scale
- Require server-side proxy (complexity, cost)

### OAuth Flow

Some APIs support OAuth, but most academic sources use simple API keys. Would add complexity for minimal benefit.
