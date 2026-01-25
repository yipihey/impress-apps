//
//  ProxySetupStepView.swift
//  PublicationManagerCore
//
//  Onboarding step for configuring library proxy settings.
//

import SwiftUI
import OSLog

/// Onboarding step for configuring library proxy settings.
///
/// Guides users through setting up their institutional proxy
/// to access publisher PDFs that require authentication.
public struct ProxySetupStepView: View {

    // MARK: - Properties

    /// Called when user skips this step.
    let onSkip: () -> Void

    /// Called when user saves and continues.
    let onContinue: () -> Void

    // MARK: - State

    @State private var proxyEnabled = false
    @State private var proxyURL = ""
    @State private var selectedProxy: String?
    @State private var isSaving = false

    // MARK: - Initialization

    public init(
        onSkip: @escaping () -> Void,
        onContinue: @escaping () -> Void
    ) {
        self.onSkip = onSkip
        self.onContinue = onContinue
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            headerSection

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Why proxy?
                    whyProxySection

                    // Enable toggle
                    enableToggleSection

                    // Proxy URL entry
                    if proxyEnabled {
                        proxyURLSection
                    }

                    // Info box
                    infoBox
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
            }

            Spacer()

            Divider()

            // Buttons
            buttonSection
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "building.columns.fill")
                    .font(.title)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Library Proxy Setup")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Access publisher PDFs through your institution")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
    }

    // MARK: - Why Proxy Section

    private var whyProxySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What is a library proxy?")
                .font(.headline)

            Text("Many academic publishers restrict PDF access to subscribers. If your institution has journal subscriptions, a library proxy lets you access these PDFs from anywhere.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                benefitRow(icon: "doc.fill", text: "Download publisher PDFs directly")
                benefitRow(icon: "globe", text: "Access from anywhere, not just campus")
                benefitRow(icon: "lock.open.fill", text: "Bypass paywalls with your institutional access")
            }
            .padding(.top, 4)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.1))
        )
    }

    private func benefitRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.blue)
                .frame(width: 20)

            Text(text)
                .font(.subheadline)
        }
    }

    // MARK: - Enable Toggle Section

    private var enableToggleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable library proxy", isOn: $proxyEnabled)
                .font(.subheadline)
                .fontWeight(.medium)

            Text("When enabled, PDF downloads will route through your institution's proxy.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Proxy URL Section

    private var proxyURLSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Proxy URL field - always shown so users can paste any URL
            VStack(alignment: .leading, spacing: 8) {
                Text("Proxy URL")
                    .font(.subheadline)
                    .fontWeight(.medium)

                TextField("https://proxy.university.edu/login?url=", text: $proxyURL)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .onChange(of: proxyURL) { _, newValue in
                        // Clear preset selection if user manually edits to something different
                        if let selected = selectedProxy,
                           let preset = PDFSettings.commonProxies.first(where: { $0.name == selected }),
                           newValue != preset.url {
                            selectedProxy = nil
                        }
                    }

                Text("Enter your institution's EZproxy URL, or select from common presets below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Common proxies menu - for quick selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Common institutions")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Menu {
                    ForEach(PDFSettings.commonProxies, id: \.url) { proxy in
                        Button(proxy.name) {
                            selectedProxy = proxy.name
                            proxyURL = proxy.url
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedProxy ?? "Select to auto-fill...")
                            .foregroundStyle(selectedProxy == nil ? .secondary : .primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Info Box

    private var infoBox: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Not sure?")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("You can configure this later in Settings. Contact your library's IT support for your institution's proxy URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.1))
        )
    }

    // MARK: - Button Section

    private var buttonSection: some View {
        HStack {
            Button("Skip") {
                onSkip()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                saveAndContinue()
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 8)
                } else {
                    Text(proxyEnabled && !proxyURL.isEmpty ? "Save & Continue" : "Continue")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }

    // MARK: - Actions

    private func saveAndContinue() {
        // If proxy not enabled or no URL, just continue
        guard proxyEnabled, !proxyURL.isEmpty else {
            onContinue()
            return
        }

        isSaving = true

        Task {
            await PDFSettingsStore.shared.updateLibraryProxy(url: proxyURL, enabled: true)
            Logger.library.infoCapture("Library proxy configured during onboarding: \(proxyURL)", category: "onboarding")

            await MainActor.run {
                isSaving = false
                onContinue()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ProxySetupStepView(
        onSkip: { },
        onContinue: { }
    )
    .frame(width: 550, height: 550)
}
