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

                Text("API keys are stored in your macOS Keychain and never synced. Conversations stay on your device. When you send a message, only that conversation is sent to your chosen AI provider.")
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
