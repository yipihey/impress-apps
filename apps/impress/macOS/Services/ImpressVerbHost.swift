#if os(macOS)
//
//  ImpressVerbHost.swift
//  impress
//
//  Wave 5 V1 (ADR-0033 D4, amended 2026-09-23): a surface rendered in this
//  process can only call the four kit crates' verbs the FFI links — imbib's
//  and imprint's own verbs cannot join them (a second domain core, or the
//  package cycle `impress-store-ffi`'s Cargo.toml documents). The suite
//  already links every verb, HTTP backends included, into `impel-tools`
//  (`ImpelToolsFFI`, CounselEngine's product) — this file is the one
//  registration that hands the running `SharedStore` a way to reach it. No
//  logic of its own: `hasVerb`/`callVerb` are a straight pass-through to
//  `impel-tools`' own `list_tools`/`call_tool`, with a separate trusted
//  pipeline context for nested calls, which refuses a verb whose owning app
//  is not running rather than falling through to the store.
//

import Foundation
import ImpelToolsFFI
import ImpressKit
import ImpressLogging
import ImpressRustCore

/// Adapts `impel-tools`' tool surface to the `SharedVerbHost` callback the
/// Rust executor consults for any verb `impress-capabilities-kit` did not
/// link (see `crates/impress-surface-service/src/runtime.rs`'s `VerbHost`).
final class ImpelToolsVerbHost: SharedVerbHost, @unchecked Sendable {

    func inventoryRevision() -> UInt64 {
        providerInventoryRevision()
    }

    /// The sibling apps whose last call was refused as unavailable. Purely a
    /// log-keeping aid: the refusal and the re-probe both happen in
    /// `impel-tools`, and this host never decides anything from it. It exists
    /// so the moment an app comes back is a line in the log rather than a
    /// silent change in behaviour — "my surface started working again and I
    /// do not know when" was the actual complaint on 2026-09-23.
    private let reachabilityLock = NSLock()
    private var appsLastSeenUnavailable: Set<String> = []

    func hasVerb(name: String) -> Bool {
        // Query the full inventory each time: a provider can register or
        // disappear after this callback was installed. Availability remains
        // `callTool`'s decision, so an unavailable name is still known.
        listTools().contains { $0.name == name }
    }

    func callVerb(name: String, argsJson: String, contextJson: String) throws -> String {
        logInfo("verb host call: \(name)", category: "surface")
        do {
            let result: String
            if contextJson.isEmpty {
                result = try callTool(name: name, argsJson: argsJson)
            } else {
                result = try callToolWithContext(
                    name: name,
                    argsJson: argsJson,
                    contextJson: contextJson)
            }
            // Which app owns a verb is impel-tools' rule, asked, not copied
            // (review RS-S19).
            noteReachable(app: toolApp(name: name))
            return result
        } catch {
            logWarning("verb host call failed: \(name): \(error)", category: "surface")
            // Structured, so Rust words the refusal and codes it: an app that
            // is not running is `host-unavailable` ("imbib is not running, so
            // … — open imbib to use it"), anything else `verb-failed`. Before,
            // both arrived as a generic storage error (RS-S19).
            if case let ToolError.AppUnavailable(app, _) = error {
                noteUnavailable(app: app)
                throw SharedVerbHostError.Unavailable(app: app, verb: name)
            }
            throw SharedVerbHostError.Failed(message: "\(error)")
        }
    }

    private func noteUnavailable(app: String) {
        reachabilityLock.lock()
        defer { reachabilityLock.unlock() }
        appsLastSeenUnavailable.insert(app)
    }

    /// A call that SUCCEEDED against an app we last saw refused is the
    /// transition `impel-tools`' re-probe exists to catch: the app was
    /// started after impress and is now answering, with no relaunch. Log it
    /// once, on the edge.
    private func noteReachable(app: String?) {
        guard let app else { return }
        reachabilityLock.lock()
        let wasUnavailable = appsLastSeenUnavailable.remove(app) != nil
        reachabilityLock.unlock()
        guard wasUnavailable else { return }
        logInfo(
            "impel-tools verb host: \(app) is reachable again — a re-probe found it up, "
                + "no relaunch needed",
            category: "surface")
    }

    /// Point `impel-tools` at the sibling apps' HTTP ports and install this
    /// host on `store` — call once, from impress's own launch path, beside
    /// `ImpressHTTPServer.shared.start()`. An isolated UI test installs the
    /// host without configuring or probing sibling apps.
    ///
    /// On a normal launch the first probe runs here; an app closed then is
    /// re-probed by `impel-tools` on the next call that needs it (at most once
    /// a minute), so "start imbib, then use a surface" works without
    /// relaunching impress — it did not on 2026-09-23, when `configure` was a
    /// once-per-process cell.
    static func install(on store: SharedStore) {
        if ImpressRuntime.isUITestingProcess {
            logInfo(
                "impel-tools verb host: isolated UI test; sibling backends left unconfigured",
                category: "surface")
        } else {
            let backends = configure(
                imbibUrl: "http://localhost:\(SiblingApp.imbib.httpPort)",
                imprintUrl: "http://localhost:\(SiblingApp.imprint.httpPort)")
            logInfo(
                "impel-tools verb host: imbib=\(backends.imbib), imprint=\(backends.imprint)",
                category: "surface")
        }
        store.setVerbHost(host: ImpelToolsVerbHost())
        logInfo("impel-tools verb host installed on the shared store", category: "surface")
    }
}

/// The GUI store image owns provider registration and policy. This callback
/// forwards only schema checks and authenticated raw HTTP I/O to the separate
/// non-kit ImpelToolsFFI image; it never dispatches another verb pipeline.
final class ImpressProviderHost: SharedProviderHost, @unchecked Sendable {
    private func forward(_ reply: ProviderPrimitiveReply) -> SharedProviderReply {
        SharedProviderReply(
            ok: reply.ok,
            code: reply.code,
            message: reply.message,
            bodyJson: reply.bodyJson)
    }

    func validateEndpoint(endpoint: String) -> SharedProviderReply {
        forward(providerValidateEndpoint(endpoint: endpoint))
    }

    func validateSchema(schemaJson: String) -> SharedProviderReply {
        forward(providerValidateSchema(schemaJson: schemaJson))
    }

    func validateInstance(schemaJson: String, argsJson: String) -> SharedProviderReply {
        forward(providerValidateInstance(schemaJson: schemaJson, argsJson: argsJson))
    }

    func health(endpoint: String, token: String) -> SharedProviderReply {
        forward(providerHealth(endpoint: endpoint, token: token))
    }

    func invoke(
        endpoint: String,
        token: String,
        name: String,
        argsJson: String,
        traceId: String?,
        parentCallId: String?
    ) -> SharedProviderReply {
        forward(providerCall(
            endpoint: endpoint,
            token: token,
            name: name,
            argsJson: argsJson,
            traceId: traceId,
            parentCallId: parentCallId))
    }

    static func install(on store: SharedStore) throws {
        try store.setProviderHost(host: ImpressProviderHost())
        let selectedPath = try store.providerStorePath()
        let reader = configureProviderStore(path: selectedPath)
        guard reader.ok else {
            throw ProviderHostSetupError.unavailable(reader.message ?? "provider inventory unavailable")
        }
        logInfo("provider host installed on the shared store", category: "surface")
    }
}

private enum ProviderHostSetupError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}
#endif // os(macOS)
