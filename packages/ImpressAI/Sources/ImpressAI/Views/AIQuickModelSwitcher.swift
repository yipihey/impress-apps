import SwiftUI

/// Menu content for switching the suite-wide model without opening Settings:
/// the current selection as a header, an inline model picker with the host's
/// badges folded into the titles, a provider submenu, refresh, and a jump to
/// the full pane. Mount inside a `Menu` (see `AIStatusMenuButton`).
@MainActor
public struct AIQuickModelSwitcher: View {
    @State private var settings: AISettings
    private let openSettings: (() -> Void)?

    /// - Parameters:
    ///   - settings: The settings projection (the shared one when nil).
    ///   - openSettings: Shown as "AI Settings…" when provided.
    public init(settings: AISettings? = nil, openSettings: (() -> Void)? = nil) {
        _settings = State(wrappedValue: settings ?? AISettings.shared)
        self.openSettings = openSettings
    }

    public var body: some View {
        Group {
            Section(settings.selectionSummary) {
                if settings.availableModels.isEmpty {
                    Text(settings.isRefreshingModels ? "Discovering models…" : "No models available")
                } else {
                    Picker("Model", selection: $settings.selectedModelId) {
                        ForEach(settings.availableModels) { model in
                            Text(Self.title(for: model))
                                .tag(Optional(model.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }

            Menu("Provider") {
                Picker("Provider", selection: $settings.selectedProviderId) {
                    Text("Automatic").tag(String?.none)
                    ForEach(AISettingsView.categoryOrder, id: \.self) { category in
                        if let providers = settings.providersByCategory[category], !providers.isEmpty {
                            Section(category.displayName) {
                                ForEach(providers) { provider in
                                    Text(provider.name).tag(Optional(provider.id))
                                }
                            }
                        }
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Divider()

            Button("Refresh Models") {
                Task { await settings.refreshModels() }
            }
            .disabled(settings.isRefreshingModels || settings.displayedProviderId == nil)

            if let openSettings {
                Button("AI Settings…", action: openSettings)
            }
        }
        .task {
            await settings.load()
        }
    }

    /// "Qwen3.5 4B 4bit · loaded · 262K ctx · vision · server default".
    static func title(for model: AIModel) -> String {
        var parts = [model.name]
        if model.isLoaded == true { parts.append("loaded") }
        if let context = model.contextWindow { parts.append("\(Self.compact(context)) ctx") }
        if model.capabilities?.contains(.vision) == true { parts.append("vision") }
        if model.isServerDefault { parts.append("server default") }
        return parts.joined(separator: " · ")
    }

    static func compact(_ number: Int) -> String {
        if number >= 1_000_000 { return String(format: "%.1fM", Double(number) / 1_000_000) }
        if number >= 1_000 { return "\(number / 1_000)K" }
        return "\(number)"
    }
}
