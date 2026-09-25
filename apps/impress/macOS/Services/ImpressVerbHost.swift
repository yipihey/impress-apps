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
//  `impel-tools`' own `list_tools`/`call_tool`, which already refuses a verb
//  whose owning app is not running rather than falling through to the store.
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

    /// Built once at install time from `listTools()` — the full inventory,
    /// not `listAvailableTools()`: `has_verb` answers "does this NAME exist
    /// anywhere", and whether the owning app is reachable right now is
    /// `callTool`'s question to refuse, so `surface_validate` reports a
    /// spec's verb reference as known even while imbib happens to be closed.
    private let knownVerbs: Set<String>

    /// The sibling apps whose last call was refused as unavailable. Purely a
    /// log-keeping aid: the refusal and the re-probe both happen in
    /// `impel-tools`, and this host never decides anything from it. It exists
    /// so the moment an app comes back is a line in the log rather than a
    /// silent change in behaviour — "my surface started working again and I
    /// do not know when" was the actual complaint on 2026-09-23.
    private let reachabilityLock = NSLock()
    private var appsLastSeenUnavailable: Set<String> = []

    init() {
        knownVerbs = Set(listTools().map(\.name))
    }

    func hasVerb(name: String) -> Bool {
        knownVerbs.contains(name)
    }

    func callVerb(name: String, argsJson: String) throws -> String {
        logInfo("verb host call: \(name)", category: "surface")
        do {
            let result = try callTool(name: name, argsJson: argsJson)
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
    /// `ImpressHTTPServer.shared.start()`.
    ///
    /// The first probe runs here; an app that is closed at that moment is
    /// re-probed by `impel-tools` on the next call that needs it (at most once
    /// a minute), so "start imbib, then use a surface" works without
    /// relaunching impress — it did not on 2026-09-23, when `configure` was a
    /// once-per-process cell.
    static func install(on store: SharedStore) {
        let backends = configure(
            imbibUrl: "http://localhost:\(SiblingApp.imbib.httpPort)",
            imprintUrl: "http://localhost:\(SiblingApp.imprint.httpPort)")
        logInfo(
            "impel-tools verb host: imbib=\(backends.imbib), imprint=\(backends.imprint)",
            category: "surface")
        store.setVerbHost(host: ImpelToolsVerbHost())
        logInfo("impel-tools verb host installed on the shared store", category: "surface")
    }
}
#endif // os(macOS)
