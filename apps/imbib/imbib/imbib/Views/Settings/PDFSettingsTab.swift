//
//  PDFSettingsTab.swift
//  imbib
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
import PublicationManagerCore

// MARK: - PDF Settings Tab

struct PDFSettingsTab: View {

    // MARK: - State

    @State private var sourcePriority: PDFSourcePriority = .preprint
    @State private var proxyEnabled: Bool = false
    @State private var proxyURL: String = ""
    @State private var autoDownloadEnabled: Bool = true
    @State private var isLoading = true

    // MARK: - Body

    var body: some View {
        Form {
            Section {
                downloadBehaviorSection
            } header: {
                Text("Download Behavior")
            } footer: {
                Text("When enabled, PDFs will download automatically when you view the PDF tab.")
            }

            Section {
                sourcePrioritySection
            } header: {
                Text("PDF Source Priority")
            } footer: {
                Text("Choose which PDF source to try first when viewing papers.")
            }

            Section {
                proxySection
            } header: {
                Text("Library Proxy")
            } footer: {
                Text("Configure your institution's proxy to access paywalled publisher PDFs.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal)
        .task {
            await loadSettings()
        }
    }

    // MARK: - Download Behavior Section

    private var downloadBehaviorSection: some View {
        Toggle("Automatically download PDFs when in PDF view", isOn: $autoDownloadEnabled)
            .onChange(of: autoDownloadEnabled) { _, newValue in
                Task { await saveAutoDownloadSetting() }
            }
            .help("Download PDFs automatically when viewing papers")
            .accessibilityIdentifier(AccessibilityID.Settings.PDF.autoDownloadToggle)
    }

    // MARK: - Source Priority Section

    private var sourcePrioritySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(PDFSourcePriority.allCases, id: \.self) { priority in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: sourcePriority == priority ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(sourcePriority == priority ? Color.accentColor : .secondary)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(priority.displayName)
                            .font(.body)

                        Text(priority.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    sourcePriority = priority
                    Task { await saveSourcePriority() }
                }
                .help(priority == .preprint ? "Try free preprints (arXiv) first" : "Try publisher version first")
            }
        }
    }

    // MARK: - Proxy Section

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use library proxy for publisher PDFs", isOn: $proxyEnabled)
                .onChange(of: proxyEnabled) { _, _ in
                    Task { await saveProxySettings() }
                }
                .help("Route publisher requests through your institution's proxy")

            if proxyEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Proxy URL", text: $proxyURL, prompt: Text("https://your-institution.edu/login?url="))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: proxyURL) { _, _ in
                            // Debounce saves
                            Task {
                                try? await Task.sleep(for: .milliseconds(500))
                                await saveProxySettings()
                            }
                        }
                        .help("Your institution's proxy prefix")
                        .accessibilityIdentifier(AccessibilityID.Settings.PDF.pdfFolderField)

                    Text("Enter your institution's proxy URL prefix")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    commonProxiesMenu
                }
            }
        }
    }

    // MARK: - Common Proxies Menu

    private var commonProxiesMenu: some View {
        HStack {
            Text("Common proxies:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                ForEach(PDFSettings.commonProxies, id: \.url) { proxy in
                    Button(proxy.name) {
                        proxyURL = proxy.url
                        Task { await saveProxySettings() }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Select")
                        .font(.caption)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Choose from common institutions")
        }
    }

    // MARK: - Settings Management

    private func loadSettings() async {
        let settings = await PDFSettingsStore.shared.settings
        sourcePriority = settings.sourcePriority
        proxyEnabled = settings.proxyEnabled
        proxyURL = settings.libraryProxyURL
        autoDownloadEnabled = settings.autoDownloadEnabled
        isLoading = false
    }

    private func saveSourcePriority() async {
        await PDFSettingsStore.shared.updateSourcePriority(sourcePriority)
    }

    private func saveProxySettings() async {
        await PDFSettingsStore.shared.updateLibraryProxy(url: proxyURL, enabled: proxyEnabled)
    }

    private func saveAutoDownloadSetting() async {
        await PDFSettingsStore.shared.updateAutoDownload(enabled: autoDownloadEnabled)
    }
}

// MARK: - Preview

#Preview {
    PDFSettingsTab()
        .frame(width: 500, height: 400)
}
