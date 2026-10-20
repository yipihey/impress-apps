import Foundation
import ImbibVerbsFFI
import ImpressAutomation
import ImpressLogging
import OSLog

private final class NativeImbibHost: ImbibNativeCallbacks, @unchecked Sendable {
    let router: HTTPAutomationRouter

    init(router: HTTPAutomationRouter) {
        self.router = router
    }

    func invoke(method: String, argsJson: String) async -> NativeCallResult {
        await router.invokeNativeVerb(method: method, argsJSON: argsJson)
    }
}

/// Installs the domain inventory only after the exact GUI store is available.
public enum ImbibNativeVerbs {
    @MainActor public static func install(router: HTTPAutomationRouter) throws {
        let adapter = RustStoreAdapter.shared
        guard adapter.startupFailure == nil, let path = adapter.databaseLocation else {
            throw NSError(domain: "ImbibNativeVerbs", code: 503,
                          userInfo: [NSLocalizedDescriptionKey: "The persistent imbib store is unavailable"])
        }
        try ImbibVerbsFFI.initializeVerbStore(path: path)
        try registerNativeBackend(callback: NativeImbibHost(router: router))
        VerbAutomationRoutes.registerDomainDispatcher(services: [
            "imbib-app-service", "imbib-library-service", "imbib-tags-service",
            "imbib-search-service", "imbib-undo-service", "imbib-annotations-service",
            "imbib-artifacts-service", "imbib-scix-service", "imbib-manuscripts-service",
            "imbib-backup-service", "imbib-eink-service", "imbib-text-service",
            "imbib-sources-service",
        ]) { name, argsJSON, callerJSON in
            let result = await dispatchVerbAsync(name: name, argsJson: argsJSON, callerJson: callerJSON)
            if (200..<300).contains(result.status), verbWritesStore(name: name) {
                let targets = mutationTargets(argsJSON)
                await MainActor.run {
                    // These callbacks already use the undo-aware adapter and
                    // its one consolidated notification for a batch.
                    if name != "imbib-library-service_delete-library-undoable",
                       name != "imbib-library-service_delete-libraries" {
                        RustStoreAdapter.shared.notifyMutationFromBackground()
                    }
                    Logger.library.infoCapture("Native store verb saved: \(name) ids=\(targets.ids) count=\(targets.count)",
                                               category: "automation")
                    Logger.library.infoCapture("Native store display refreshed: \(name) dataVersion=\(RustStoreAdapter.shared.dataVersion)",
                                               category: "automation")
                }
            }
            return VerbDispatchResponse(status: Int(result.status), bodyJSON: result.bodyJson)
        }
    }
}

/// The source adapters' secrets (koine `source-service`, source convention
/// S6) are imbib's keychain items, pushed into Rust memory the way AI
/// provider keys are (ADR-0029): at launch and whenever a credential changes.
/// Never written to a file; a daemon reads the same items through `security`.
public enum SourceSecrets {
    /// koine secret name → imbib source id whose API key holds it.
    static let items: [(koine: String, source: String)] = [
        ("ads-token", "ads"),
        ("scix-token", "scix"),
        ("wos-api-key", "wos"),
        ("ncbi-api-key", "pubmed"),
        ("crossref-plus-token", "crossref"),
    ]

    /// Push every known key and the polite-pool contact (the email stored
    /// for OpenAlex or Crossref). An absent key clears the slot.
    public static func push(credentials: CredentialManager = .shared) async {
        var present: [String] = []
        for item in items {
            let value = await credentials.apiKey(for: item.source) ?? ""
            setSourceSecret(name: item.koine, value: value)
            if !value.isEmpty { present.append(item.source) }
        }
        var contact: String? = nil
        for source in ["openalex", "crossref"] {
            if let email = await credentials.email(for: source), !email.isEmpty {
                contact = email
                break
            }
        }
        if let contact { setSourceContact(contact: contact) }
        Logger.library.infoCapture(
            "Source secrets handed to Rust: keys for [\(present.joined(separator: ", "))], contact \(contact == nil ? "unset" : "set")",
            category: "sources"
        )
    }
}

/// Log only UUID-shaped targets. Never include prose arguments such as notes,
/// queries, or manuscript bodies in mutation traces.
private func mutationTargets(_ argsJSON: String) -> (ids: String, count: Int) {
    guard let data = argsJSON.data(using: .utf8),
          let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return ("[]", 0)
    }
    let keys = ["id", "ids", "publication_id", "publication_ids", "library_id", "collection_id",
                "artifact_id", "annotation_id", "comment_id", "manuscript_id"]
    let values = keys.flatMap { key -> [String] in
        if let value = args[key] as? String { return [value] }
        return args[key] as? [String] ?? []
    }.filter { UUID(uuidString: $0) != nil }
    return ("[" + values.prefix(8).joined(separator: ",") + (values.count > 8 ? ",…]" : "]"), values.count)
}
