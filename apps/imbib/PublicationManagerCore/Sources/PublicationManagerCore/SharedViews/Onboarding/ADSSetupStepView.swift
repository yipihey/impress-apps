//
//  ADSSetupStepView.swift
//  PublicationManagerCore
//
//  Onboarding step for configuring ADS API key.
//

import SwiftUI
import OSLog

/// Onboarding step for configuring the NASA ADS/SciX API key.
///
/// Guides users through obtaining and entering their API key,
/// which enables searching NASA ADS and SciX (Science Explorer).
public struct ADSSetupStepView: View {

    // MARK: - Properties

    /// Whether the user already has an ADS API key configured.
    let hasExistingKey: Bool

    /// Called when user skips this step.
    let onSkip: () -> Void

    /// Called when user saves and continues.
    let onContinue: () -> Void

    // MARK: - State

    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var showError = false
    @State private var errorMessage = ""

    // MARK: - Constants

    private static let adsTokenURL = URL(string: "https://ui.adsabs.harvard.edu/user/settings/token")!

    // MARK: - Initialization

    public init(
        hasExistingKey: Bool,
        onSkip: @escaping () -> Void,
        onContinue: @escaping () -> Void
    ) {
        self.hasExistingKey = hasExistingKey
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
                    // Why ADS?
                    whyADSSection

                    // Already configured badge
                    if hasExistingKey {
                        alreadyConfiguredBadge
                    }

                    // API Key entry
                    apiKeyEntrySection

                    // Get API Key link
                    getAPIKeyLink
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
            }

            Spacer()

            Divider()

            // Buttons
            buttonSection
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.title)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Configure NASA ADS/SciX API Key")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Enable searching NASA ADS/SciX databases")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
    }

    // MARK: - Why ADS Section

    private var whyADSSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why NASA ADS/SciX?")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                benefitRow(icon: "magnifyingglass", text: "Search millions of astronomy and physics papers")
                benefitRow(icon: "quote.bubble", text: "Access citation counts and metrics")
                benefitRow(icon: "doc.text", text: "Download BibTeX entries directly")
                benefitRow(icon: "link", text: "Find related papers and references")
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.1))
        )
    }

    private func benefitRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)

            Text(text)
                .font(.subheadline)
        }
    }

    // MARK: - Already Configured Badge

    private var alreadyConfiguredBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            Text("API key already configured")
                .font(.subheadline)
                .fontWeight(.medium)

            Text("You can update it below if needed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.opacity(0.1))
        )
    }

    // MARK: - API Key Entry Section

    private var apiKeyEntrySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADS API Key")
                .font(.subheadline)
                .fontWeight(.medium)

            SecureField("Paste your API key here", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

            Text("Your API key is stored securely in the system Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Get API Key Link

    private var getAPIKeyLink: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Don't have an API key?")
                .font(.subheadline)
                .fontWeight(.medium)

            Link(destination: Self.adsTokenURL) {
                HStack(spacing: 6) {
                    Text("Create one at ADS")
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.subheadline)
            }

            Text("You'll need to create a free ADS account first.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    Text(apiKey.isEmpty ? "Continue" : "Save & Continue")
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
        // If no key entered, just continue (user chose not to configure)
        guard !apiKey.isEmpty else {
            onContinue()
            return
        }

        // Validate key format (basic check)
        guard apiKey.count >= 8 else {
            errorMessage = "API key appears to be too short. Please check and try again."
            showError = true
            return
        }

        isSaving = true

        Task {
            do {
                try await CredentialManager.shared.storeAPIKey(apiKey, for: "ads")
                Logger.library.infoCapture("ADS API key saved during onboarding", category: "onboarding")

                await MainActor.run {
                    isSaving = false
                    onContinue()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = "Failed to save API key: \(error.localizedDescription)"
                    showError = true
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ADSSetupStepView(
        hasExistingKey: false,
        onSkip: { },
        onContinue: { }
    )
    .frame(width: 550, height: 500)
}

#Preview("With Existing Key") {
    ADSSetupStepView(
        hasExistingKey: true,
        onSkip: { },
        onContinue: { }
    )
    .frame(width: 550, height: 500)
}
