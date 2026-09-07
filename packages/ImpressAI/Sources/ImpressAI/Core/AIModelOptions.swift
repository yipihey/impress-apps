import Foundation

/// One provider's selectable models, with the readiness that explains why
/// they can (or cannot) run right now.
///
/// Every model picker in the suite is built from these groups, so the answer
/// to "which models may I choose?" is computed once. Before this type each
/// picker asked a provider for `metadata.models` — the *static* catalogue —
/// which listed every cloud model whether or not a key was configured and
/// could never show a discovery-only host such as oMLX, whose catalogue entry
/// declares no static models at all.
public struct AIModelOptionGroup: Identifiable, Sendable, Equatable {
    /// Catalogue provider id (`omlx`, `anthropic`, `apple-on-device`, …).
    public let providerId: String
    /// The provider's display name, as the catalogue spells it.
    public let providerName: String
    /// What the registry last reported for this provider.
    public let readiness: AIProviderReadiness
    /// Selectable models, helpers already removed.
    public let models: [AIModelReference]
    /// Whether the models came from the host rather than the catalogue.
    public let isDiscovered: Bool

    public var id: String { providerId }

    /// Whether a request routed here runs without further setup.
    public var isUsable: Bool { readiness.isReady }

    /// What a picker section should say: the provider, plus the reason it is
    /// not usable when that is the case.
    public var sectionTitle: String {
        guard let hint = setupHint else { return providerName }
        return "\(providerName) — \(hint)"
    }

    /// A short reason the provider cannot serve a request, or nil when it can.
    public var setupHint: String? {
        switch readiness {
        case .ready, .foreign:
            return nil
        case .empty:
            return "no models"
        case .needsCredentials:
            return "needs an API key"
        case .needsEndpoint:
            return "needs an endpoint"
        case .unreachable:
            return "not running"
        case .foreignUnavailable:
            return "not available on this device"
        }
    }

    public init(
        providerId: String,
        providerName: String,
        readiness: AIProviderReadiness,
        models: [AIModelReference],
        isDiscovered: Bool = false
    ) {
        self.providerId = providerId
        self.providerName = providerName
        self.readiness = readiness
        self.models = models
        self.isDiscovered = isDiscovered
    }
}

/// Builds the model options every picker shows.
public enum AIModelOptions {

    /// Group and order the options. Pure, so the rules below are testable
    /// without a registry or a network:
    ///
    /// - helper pseudo-models are never offered (they are not chat models);
    /// - a provider with no models at all is dropped — an empty section is
    ///   noise, not information;
    /// - usable providers come first, each partition keeping the catalogue
    ///   order it was given, so the local host a researcher just started
    ///   outranks eight cloud providers they have never configured.
    public static func groups(
        providers: [AIProviderMetadata],
        readiness: [String: AIProviderReadiness],
        discovered: [String: [AIModel]] = [:],
        enabled: Set<String> = []
    ) -> [AIModelOptionGroup] {
        let groups: [AIModelOptionGroup] = providers.compactMap { provider in
            let isDiscovered = discovered[provider.id] != nil
            var models = (discovered[provider.id] ?? provider.models).filter { !$0.isHelper }
            if !enabled.isEmpty {
                // Settings › AI decides which models the suite may use; the
                // per-task pickers choose among those and nothing else.
                models = models.filter { enabled.contains("\(provider.id):\($0.id)") }
            }
            guard !models.isEmpty else { return nil }
            return AIModelOptionGroup(
                providerId: provider.id,
                providerName: provider.name,
                readiness: readiness[provider.id] ?? .unreachable,
                models: models.map { AIModelReference.from(provider: provider, model: $0) },
                isDiscovered: isDiscovered
            )
        }
        return groups.filter(\.isUsable) + groups.filter { !$0.isUsable }
    }

    /// Groups that are guaranteed to contain `selection`.
    ///
    /// A stored assignment outlives the host that serves it: quit oMLX and its
    /// group disappears, because a provider with no models is dropped. Without
    /// this the picker would render a selection it has no row for — SwiftUI
    /// shows that as blank, which reads as "nothing is assigned" and invites
    /// the user to overwrite an assignment that was fine.
    public static func groups(
        _ groups: [AIModelOptionGroup],
        including selection: AIModelReference?
    ) -> [AIModelOptionGroup] {
        guard let selection,
              !groups.contains(where: { group in group.models.contains { $0.id == selection.id } })
        else { return groups }
        let name = selection.displayName.components(separatedBy: " - ").first ?? selection.providerId
        return groups + [
            AIModelOptionGroup(
                providerId: selection.providerId,
                providerName: name,
                readiness: .unreachable,
                models: [selection]
            )
        ]
    }

    /// Load the options from the registry: providers that are ready are asked
    /// what they actually serve, everything else falls back to the catalogue.
    ///
    /// Discovery runs concurrently, so the cost is one round trip rather than
    /// one per provider, and an unready provider is never probed at all.
    /// The options a per-task picker should offer: the enabled set when the
    /// researcher curated one, everything otherwise.
    public static func loadEnabled(from manager: AIProviderManager) async -> [AIModelOptionGroup] {
        let enabled = Set(await manager.enabledModels.map(\.id))
        return await load(from: manager, enabled: enabled)
    }

    public static func load(
        from manager: AIProviderManager,
        enabled: Set<String> = []
    ) async -> [AIModelOptionGroup] {
        await manager.registerBuiltInProviders()
        let providers = await manager.allProviderMetadata
        let descriptors = await manager.descriptors
        var readiness: [String: AIProviderReadiness] = [:]
        for provider in providers {
            readiness[provider.id] = descriptors.first { $0.id == provider.id }?.readiness
                ?? (provider.category == .local ? .unreachable : .needsCredentials)
        }

        let discoverable = providers.filter { readiness[$0.id]?.isReady == true }.map(\.id)
        var discovered: [String: [AIModel]] = [:]
        await withTaskGroup(of: (String, [AIModel]?).self) { group in
            for providerId in discoverable {
                group.addTask {
                    (providerId, try? await manager.models(for: providerId))
                }
            }
            for await (providerId, models) in group {
                if let models, !models.isEmpty { discovered[providerId] = models }
            }
        }

        return groups(
            providers: providers, readiness: readiness, discovered: discovered, enabled: enabled)
    }
}
