//
//  PrivacyIndicatorBar.swift
//  impart (macOS)
//
//  Shows active provider and privacy status.
//

import SwiftUI
import MessageManagerCore
import ImpressAI

/// Bar showing the current AI provider and privacy status.
struct PrivacyIndicatorBar: View {
    @ObservedObject var viewModel: ResearchConversationViewModel
    @State private var providerInfo: ProviderInfo?

    var body: some View {
        HStack(spacing: 12) {
            // Provider badge
            HStack(spacing: 4) {
                Circle()
                    .fill(providerInfo?.isLocal == true ? Color.green : Color.blue)
                    .frame(width: 8, height: 8)

                Text(providerInfo?.name ?? "Not configured")
                    .font(.caption)
            }

            // Local/Cloud indicator
            privacyBadge

            Spacer()

            // Artifact count
            if !viewModel.attachedArtifacts.isEmpty {
                Label("\(viewModel.attachedArtifacts.count)", systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Token usage
            if let stats = viewModel.stats, stats.totalTokens > 0 {
                Label(formatTokens(stats.totalTokens), systemImage: "number")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        .task {
            await loadProviderInfo()
        }
    }

    private var privacyBadge: some View {
        let isLocal = providerInfo?.isLocal ?? false

        return HStack(spacing: 4) {
            Image(systemName: isLocal ? "lock.fill" : "cloud")
                .font(.caption2)

            Text(isLocal ? "Local" : "Cloud")
                .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(isLocal ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
        .clipShape(Capsule())
    }

    private func loadProviderInfo() async {
        // Load from ImpressAI settings
        let settings = AISettings.shared
        await settings.load()

        if let providerId = settings.selectedProviderId {
            let isLocal = providerId == "ollama" || providerId.contains("local")
            let name = settings.availableProviders.first { $0.id == providerId }?.name ?? providerId

            providerInfo = ProviderInfo(
                name: name,
                isLocal: isLocal
            )
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }
}

// MARK: - Provider Info

private struct ProviderInfo {
    let name: String
    let isLocal: Bool
}

#Preview {
    VStack {
        PrivacyIndicatorBar(viewModel: .preview)
    }
    .frame(width: 500)
}
