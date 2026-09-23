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

    init() {
        knownVerbs = Set(listTools().map(\.name))
    }

    func hasVerb(name: String) -> Bool {
        knownVerbs.contains(name)
    }

    func callVerb(name: String, argsJson: String) throws -> String {
        logInfo("verb host call: \(name)", category: "surface")
        do {
            return try callTool(name: name, argsJson: argsJson)
        } catch {
            // `SharedStoreError` has no case of its own for "a verb host
            // refused this" — `.Storage` is the generic failure every other
            // non-classified store error in this crate already uses
            // (`impress-store-ffi/src/lib.rs`'s `watched_err`).
            throw SharedStoreError.Storage(message: "\(name): \(error)")
        }
    }

    /// Point `impel-tools` at the sibling apps' HTTP ports and install this
    /// host on `store` — call once, from impress's own launch path, beside
    /// `ImpressHTTPServer.shared.start()`.
    ///
    /// **Known limit**: `configure` probes each sibling once per process
    /// (`impel-tools`' own doc comment on `configure`). An app started AFTER
    /// this call stays `.unavailable` until impress itself restarts — worth
    /// recording for whoever verifies this on the Mac, since it means "start
    /// imbib, then try a surface" needs impress relaunched in between.
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
