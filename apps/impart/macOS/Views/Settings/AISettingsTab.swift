//
//  AISettingsTab.swift
//  impart (macOS)
//
//  AI provider settings with privacy information.
//

import SwiftUI
import ImpressAI

/// AI settings tab with privacy header and embedded ImpressAI settings.
struct AISettingsTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Privacy header
            VStack(alignment: .leading, spacing: 8) {
                Label("Your Privacy", systemImage: "lock.shield")
                    .font(.headline)

                Text("The provider and model are one suite-wide selection shared by every impress app. On-device Apple Intelligence and local oMLX or Ollama models never leave this Mac; a cloud provider receives only the conversation you send. API keys stay in your macOS Keychain and are never synced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                HStack(spacing: 16) {
                    PrivacyFeatureView(
                        icon: "key.fill",
                        title: "Secure Storage",
                        detail: "API keys in Keychain"
                    )

                    PrivacyFeatureView(
                        icon: "internaldrive.fill",
                        title: "Local Data",
                        detail: "Conversations on device"
                    )

                    PrivacyFeatureView(
                        icon: "network.slash",
                        title: "Ollama Support",
                        detail: "Zero network option"
                    )
                }
            }
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)

            // Pair a phone/browser with the local AI server (port 8787).
            AIDevicePairingSection()

            // Embedded ImpressAI settings
            AISettingsView()

            Spacer()
        }
    }
}

/// Individual privacy feature indicator.
private struct PrivacyFeatureView: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    AISettingsTab()
        .frame(width: 550, height: 500)
}
