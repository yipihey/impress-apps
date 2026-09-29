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
