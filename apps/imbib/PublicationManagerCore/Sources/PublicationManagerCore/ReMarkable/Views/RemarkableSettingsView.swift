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
    @State private var userCode: String = ""
    @State private var pendingBackend: RemarkableCloudBackend?
    @State private var isConnecting = false
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
                // Authenticating state — user must enter code from reMarkable website
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect reMarkable")
                        .font(.headline)

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1. Visit the reMarkable device connection page:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Link("my.remarkable.com/device/browser/connect",
                                 destination: URL(string: "https://my.remarkable.com/device/browser/connect")!)
                                .font(.caption)

                            Divider()

                            Text("2. Enter the one-time code shown on that page:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("One-time code", text: $userCode)
                                .textFieldStyle(.roundedBorder)
                                #if os(macOS)
                                .frame(maxWidth: 200)
                                #endif
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack {
                        Button("Cancel") {
                            isAuthenticating = false
                            userCode = ""
                            pendingBackend = nil
                        }
                        .buttonStyle(.bordered)

                        Button {
                            connectWithUserCode()
                        } label: {
                            if isConnecting {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("Connecting...")
                                }
                            } else {
                                Text("Connect")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(userCode.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                    }
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
        let backend = RemarkableCloudBackend()
        pendingBackend = backend
        isAuthenticating = true
        errorMessage = nil
        // startAuthentication() generates a deviceID locally — no network call
        Task { _ = try? await backend.startAuthentication() }
    }

    private func connectWithUserCode() {
        guard let backend = pendingBackend else { return }
        let code = userCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }

        isConnecting = true
        errorMessage = nil

        Task {
            do {
                try await backend.completeRegistration(userCode: code)
                await MainActor.run {
                    isAuthenticating = false
                    isConnecting = false
                    userCode = ""
                    pendingBackend = nil
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
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
