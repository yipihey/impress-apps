import Foundation
import ImpressKit
import ImpressLogging

/// One-time import of the selection the Swift layer used to keep in
/// `SharedDefaults.suite` (and imprint's standard-domain mirror) into the
/// Rust-owned preferences file. Runs once per device: Rust records the
/// import, and the legacy keys are removed afterwards so nothing can read
/// stale state again.
///
/// Rust decides what survives — an `openai-compatible` selection pointing at
/// oMLX's loopback endpoint becomes `omlx`, helper pseudo-models such as
/// `MarkItDown` are dropped, unknown providers are ignored — and reports it;
/// this side logs the facts under `ai.migration`.
public enum AIPreferencesMigration {
    static let selectedProviderKey = "impressai.selectedProviderId"
    static let selectedModelKey = "impressai.selectedModelId"
    static let automaticallyStartOMLXKey = "impressai.automaticallyStartOMLX"
    static let taskCategoryAssignmentsKey = "impressai.taskCategoryAssignments"
    /// The pre-ADR-0029 `AITextCompletionService` mirror in the app's own domain.
    static let standardDomainSelectionKey = "impressai.selectedProvider"
    /// Providers whose endpoint used to live in the keychain as a credential
    /// field; endpoints are preferences now.
    static let endpointProviderIds = ["openai-compatible", "ollama"]

    /// Import if Rust has not recorded one yet. Returns the preferences in
    /// force afterwards (nil when the bridge is unavailable).
    @discardableResult
    public static func runIfNeeded(
        bridge: any AIBridge,
        credentials: AICredentialManager,
        defaults: UserDefaults = SharedDefaults.suite,
        standardDefaults: UserDefaults = .standard
    ) async -> AIPreferences? {
        let current: AIPreferences
        do {
            current = try await bridge.preferences()
        } catch {
            logError("Migration: could not read AI preferences: \(error.localizedDescription)", category: "ai.migration")
            return nil
        }
        if current.migratedFromSharedDefaults {
            return current
        }

        let legacy = await collectLegacy(credentials: credentials, defaults: defaults)
        logInfo(
            "Migration: importing legacy AI selection provider=\(legacy.selectedProviderId ?? "<none>") model=\(legacy.selectedModelId ?? "<none>") autoStart=\(legacy.autoStartOMLX.map(String.init) ?? "<unset>") categories=\(legacy.taskCategoryAssignmentsJSON == nil ? "none" : "present") endpoints=\(legacy.endpoints.keys.sorted().joined(separator: ","))",
            category: "ai.migration"
        )

        // The bearer configured for the generic server was, in practice, the
        // oMLX bearer; carry it over unless oMLX already has its own.
        if let bearer = await credentials.retrieve(for: "openai-compatible", field: "apiKey"),
           !bearer.isEmpty,
           await credentials.retrieve(for: "omlx", field: "apiKey") == nil {
            do {
                try await credentials.store(bearer, for: "omlx", field: "apiKey")
                logInfo("Migration: copied the openai-compatible bearer to omlx", category: "ai.migration")
            } catch {
                logError("Migration: could not copy the bearer to omlx: \(error.localizedDescription)", category: "ai.migration")
            }
        }

        let imported: AIPreferences
        do {
            imported = try await bridge.importLegacyPreferences(legacy)
        } catch {
            logError("Migration: Rust rejected the legacy import: \(error.localizedDescription)", category: "ai.migration")
            return nil
        }

        for key in [selectedProviderKey, selectedModelKey, automaticallyStartOMLXKey, taskCategoryAssignmentsKey] {
            defaults.removeObject(forKey: key)
        }
        standardDefaults.removeObject(forKey: standardDomainSelectionKey)
        for providerId in endpointProviderIds {
            await credentials.delete(for: providerId, field: "endpoint")
        }
        let selection = imported.selected.map { "\($0.providerId)/\($0.modelId ?? "<none>")" } ?? "<none>"
        logInfo(
            "Migration: done — selection now \(selection), \(imported.taskAssignments.count) task categories, legacy keys removed",
            category: "ai.migration"
        )
        return imported
    }

    static func collectLegacy(credentials: AICredentialManager, defaults: UserDefaults) async -> AILegacyPreferences {
        var endpoints: [String: String] = [:]
        for providerId in endpointProviderIds {
            if let endpoint = await credentials.retrieve(for: providerId, field: "endpoint"),
               !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                endpoints[providerId] = endpoint
            }
        }
        let assignmentsJSON = defaults
            .data(forKey: taskCategoryAssignmentsKey)
            .flatMap { String(data: $0, encoding: .utf8) }
        return AILegacyPreferences(
            selectedProviderId: defaults.string(forKey: selectedProviderKey),
            selectedModelId: defaults.string(forKey: selectedModelKey),
            autoStartOMLX: defaults.object(forKey: automaticallyStartOMLXKey) as? Bool,
            taskCategoryAssignmentsJSON: assignmentsJSON,
            endpoints: endpoints
        )
    }
}
