//
//  ImbibSettingsView.swift
//  imprint
//
//  Settings view for imbib integration configuration.
//

import SwiftUI

/// Settings view for imbib citation manager integration.
struct ImbibSettingsView: View {
    private var imbibService = ImbibIntegrationService.shared

    @AppStorage("showCitedPapersSidebar") private var showCitedPapersSidebar = true
    @AppStorage("autoSyncBibliography") private var autoSyncBibliography = false
    @AppStorage("bibliographyFileName") private var bibliographyFileName = "references.bib"

    @State private var isCheckingConnection = false
    @State private var lastConnectionCheck: Date?

    var body: some View {
        Form {
            connectionSection
            featuresSection
            bibliographySection
            actionsSection
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            Task {
                await checkConnection()
            }
        }
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        Section {
            HStack {
                if isCheckingConnection {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking connection...")
                        .foregroundStyle(.secondary)
                } else if imbibService.isAvailable {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text("imbib is installed")
                        if imbibService.isAutomationEnabled {
                            Text("Automation enabled")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Automation disabled - enable in imbib Settings")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading) {
                        Text("imbib is not installed")
                        Text("Install imbib to use citation features")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("Refresh") {
                    Task {
                        await checkConnection()
                    }
                }
                .disabled(isCheckingConnection)
            }

            if let lastCheck = lastConnectionCheck {
                Text("Last checked: \(lastCheck, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Connection")
        } footer: {
            if !imbibService.isAvailable {
                Text("imbib is a scientific publication manager that integrates with imprint for seamless citation management.")
            }
        }
    }

    // MARK: - Features Section

    private var featuresSection: some View {
        Section("Features") {
            Toggle("Show cited papers in sidebar", isOn: $showCitedPapersSidebar)
                .disabled(!imbibService.isAvailable)
                .accessibilityIdentifier("settings.imbib.citedPapersSidebar")

            Toggle("Auto-sync bibliography on save", isOn: $autoSyncBibliography)
                .disabled(!imbibService.isAvailable)
                .accessibilityIdentifier("settings.imbib.autoSyncBib")

            if autoSyncBibliography {
                HStack {
                    Text("Bibliography file name:")
                    TextField("references.bib", text: $bibliographyFileName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .accessibilityIdentifier("settings.imbib.bibFileName")
                }
            }
        }
    }

    // MARK: - Bibliography Section

    private var bibliographySection: some View {
        Section {
            HStack {
                VStack(alignment: .leading) {
                    Text("Generate Bibliography")
                        .font(.headline)
                    Text("Create a .bib file from citations in the current document")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Generate...") {
                    NotificationCenter.default.post(name: .exportBibliography, object: nil)
                }
                .disabled(!imbibService.isAvailable || !imbibService.isAutomationEnabled)
            }

            if !imbibService.isAutomationEnabled && imbibService.isAvailable {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Enable automation in imbib to generate bibliographies")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Bibliography")
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        Section("Actions") {
            Button {
                imbibService.openImbib()
            } label: {
                Label("Open imbib", systemImage: "arrow.up.forward.app")
            }
            .disabled(!imbibService.isAvailable)

            Button {
                imbibService.openAutomationSettings()
            } label: {
                Label("Open imbib Automation Settings", systemImage: "gear")
            }
            .disabled(!imbibService.isAvailable)
        }
    }

    // MARK: - Helpers

    private func checkConnection() async {
        isCheckingConnection = true
        await imbibService.checkAvailability()
        isCheckingConnection = false
        lastConnectionCheck = Date()
    }
}

#Preview {
    ImbibSettingsView()
        .frame(width: 500, height: 400)
}
