//
//  CredentialEntryView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI

// MARK: - Credential Entry View

/// View for entering API credentials for a source.
public struct CredentialEntryView: View {

    let sourceInfo: SourceCredentialInfo
    @Binding var apiKey: String
    @Binding var email: String
    let onSave: () -> Void
    let onDelete: () -> Void

    public init(
        sourceInfo: SourceCredentialInfo,
        apiKey: Binding<String>,
        email: Binding<String>,
        onSave: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.sourceInfo = sourceInfo
        self._apiKey = apiKey
        self._email = email
        self.onSave = onSave
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text(sourceInfo.sourceName)
                    .font(.headline)

                Spacer()

                Image(systemName: sourceInfo.status.iconName)
                    .foregroundStyle(statusColor)
            }

            // Status description
            Text(sourceInfo.requirement.displayDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // API Key field
            if needsAPIKey {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    SecureField("Enter API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Email field
            if needsEmail {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Email")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Enter email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                }
            }

            // Registration link
            if let url = sourceInfo.registrationURL {
                Link(destination: url) {
                    Label("Get API Key", systemImage: "arrow.up.right.square")
                        .font(.subheadline)
                }
            }

            // Buttons
            HStack {
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)

                if hasCredentials {
                    Button("Delete", role: .destructive, action: onDelete)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        #if os(macOS)
        .frame(minWidth: 300)
        #endif
    }

    private var needsAPIKey: Bool {
        switch sourceInfo.requirement {
        case .apiKey, .apiKeyAndEmail, .apiKeyOptional:
            return true
        default:
            return false
        }
    }

    private var needsEmail: Bool {
        switch sourceInfo.requirement {
        case .email, .apiKeyAndEmail, .emailOptional:
            return true
        default:
            return false
        }
    }

    private var canSave: Bool {
        switch sourceInfo.requirement {
        case .none:
            return false
        case .apiKey:
            return !apiKey.isEmpty
        case .email:
            return !email.isEmpty && email.contains("@")
        case .apiKeyAndEmail:
            return !apiKey.isEmpty && !email.isEmpty && email.contains("@")
        case .apiKeyOptional:
            return apiKey.isEmpty || apiKey.count >= 8
        case .emailOptional:
            return email.isEmpty || email.contains("@")
        }
    }

    private var hasCredentials: Bool {
        switch sourceInfo.status {
        case .valid, .optionalValid:
            return true
        default:
            return false
        }
    }

    private var statusColor: Color {
        switch sourceInfo.status {
        case .notRequired, .valid, .optionalValid:
            return .green
        case .missing, .invalid:
            return .red
        case .optionalMissing:
            return .orange
        }
    }
}

// MARK: - Source Credentials List

/// List of all sources with their credential status.
public struct SourceCredentialsList: View {

    let credentials: [SourceCredentialInfo]
    let onSelectSource: (SourceCredentialInfo) -> Void

    public init(
        credentials: [SourceCredentialInfo],
        onSelectSource: @escaping (SourceCredentialInfo) -> Void
    ) {
        self.credentials = credentials
        self.onSelectSource = onSelectSource
    }

    public var body: some View {
        List {
            ForEach(credentials) { info in
                SourceCredentialRow(info: info)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelectSource(info)
                    }
            }
        }
    }
}

// MARK: - Source Credential Row

public struct SourceCredentialRow: View {
    let info: SourceCredentialInfo

    public init(info: SourceCredentialInfo) {
        self.info = info
    }

    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.sourceName)
                    .font(.headline)

                Text(info.status.displayDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: info.status.iconName)
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch info.status {
        case .notRequired, .valid, .optionalValid:
            return .green
        case .missing, .invalid:
            return .red
        case .optionalMissing:
            return .orange
        }
    }
}
