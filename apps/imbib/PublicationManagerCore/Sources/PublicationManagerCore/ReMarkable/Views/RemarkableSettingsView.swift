//
//  RemarkableSettingsView.swift
//  PublicationManagerCore
//
//  SwiftUI settings view for reMarkable integration.
//  ADR-019: reMarkable Tablet Integration
//

import SwiftUI
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "remarkableSettings")

// MARK: - Settings View

/// Settings view for configuring reMarkable integration.
public struct RemarkableSettingsView: View {
    @State private var settings = RemarkableSettingsStore.shared
    @State private var isAuthenticating = false
    @State private var authCode: String?
    @State private var showDisconnectConfirmation = false
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        Form {
            // Connection Section
            connectionSection

            // Sync Options Section
            if settings.isAvailable {
                syncOptionsSection
                organizationSection
                annotationOptionsSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle("reMarkable")
        #if os(macOS)
        .frame(minWidth: 450)
        #endif
        .alert("Disconnect reMarkable?", isPresented: $showDisconnectConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                settings.clearCredentials()
            }
        } message: {
            Text("This will remove the connection to your reMarkable account. You can reconnect at any time.")
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Connection Section

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            if settings.isAuthenticated {
                // Connected state
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text("Connected")
                            .font(.headline)
                        if let deviceName = settings.deviceName {
                            Text(deviceName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Disconnect") {
                        showDisconnectConfirmation = true
                    }
                    .buttonStyle(.bordered)
                }
            } else if isAuthenticating {
                // Authenticating state
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting...")
                    }

                    if let code = authCode {
                        GroupBox {
                            VStack(spacing: 8) {
                                Text("Enter this code at:")
                                    .font(.caption)
                                Link("my.remarkable.com/device/browser/connect",
                                     destination: URL(string: "https://my.remarkable.com/device/browser/connect")!)
                                    .font(.caption)

                                Text(code)
                                    .font(.system(.title, design: .monospaced))
                                    .fontWeight(.bold)
                                    .padding()
                                    .background(Color.secondary.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Button("Copy Code") {
                                    #if os(macOS)
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(code, forType: .string)
                                    #else
                                    UIPasteboard.general.string = code
                                    #endif
                                }
                                .buttonStyle(.bordered)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    Button("Cancel") {
                        isAuthenticating = false
                        authCode = nil
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                // Disconnected state
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "tablet")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text("Connect your reMarkable")
                                .font(.headline)
                            Text("Sync PDFs and import annotations from your reMarkable tablet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        startAuthentication()
                    } label: {
                        Label("Connect to reMarkable Cloud", systemImage: "link")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } header: {
            Text("Connection")
        } footer: {
            if !settings.isAuthenticated && !isAuthenticating {
                Text("Connect to sync your PDFs to reMarkable and import your handwritten annotations back to imbib.")
            }
        }
    }

    // MARK: - Sync Options Section

    @ViewBuilder
    private var syncOptionsSection: some View {
        Section {
            Toggle("Automatic Sync", isOn: $settings.autoSyncEnabled)

            if settings.autoSyncEnabled {
                Picker("Sync Interval", selection: $settings.syncInterval) {
                    Text("Every 15 minutes").tag(TimeInterval(900))
                    Text("Every hour").tag(TimeInterval(3600))
                    Text("Every 6 hours").tag(TimeInterval(21600))
                    Text("Daily").tag(TimeInterval(86400))
                }
            }

            Picker("Conflict Resolution", selection: $settings.conflictResolution) {
                ForEach(ConflictResolution.allCases, id: \.self) { resolution in
                    Text(resolution.displayName).tag(resolution)
                }
            }
        } header: {
            Text("Sync Options")
        }
    }

    // MARK: - Organization Section

    @ViewBuilder
    private var organizationSection: some View {
        Section {
            TextField("Root Folder Name", text: $settings.rootFolderName)
                .textFieldStyle(.roundedBorder)

            Toggle("Create Folders by Collection", isOn: $settings.createFoldersByCollection)

            Toggle("Use Reading Queue Folder", isOn: $settings.useReadingQueueFolder)
        } header: {
            Text("Organization")
        } footer: {
            Text("Documents will be organized in a '\(settings.rootFolderName)' folder on your reMarkable.")
        }
    }

    // MARK: - Annotation Options Section

    @ViewBuilder
    private var annotationOptionsSection: some View {
        Section {
            Toggle("Import Highlights", isOn: $settings.importHighlights)
            Toggle("Import Handwritten Notes", isOn: $settings.importInkNotes)

            if settings.importInkNotes {
                Toggle("Enable OCR for Handwriting", isOn: $settings.enableOCR)
            }
        } header: {
            Text("Annotation Import")
        } footer: {
            if settings.enableOCR {
                Text("OCR will attempt to convert your handwritten notes to searchable text.")
            }
        }
    }

    // MARK: - Authentication

    private func startAuthentication() {
        isAuthenticating = true
        errorMessage = nil

        Task {
            do {
                // Start authentication flow
                let backend = RemarkableCloudBackend()
                let codeResponse = try await backend.startAuthentication()
                authCode = codeResponse.userCode

                // Poll for completion
                try await backend.pollForAuthCompletion(deviceCode: codeResponse.deviceCode)

                await MainActor.run {
                    isAuthenticating = false
                    authCode = nil
                    // Settings store will be updated by the backend
                }
            } catch {
                await MainActor.run {
                    isAuthenticating = false
                    authCode = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        RemarkableSettingsView()
    }
}
