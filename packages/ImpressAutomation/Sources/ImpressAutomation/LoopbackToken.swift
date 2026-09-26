//
//  LoopbackToken.swift
//  ImpressAutomation
//
//  The per-launch loopback token (P0, SEC-2), as Swift reaches it. Rust
//  decides, Swift maps: the directory, file name, contents and mode are
//  `impress_core::loopback_token`'s, exported over UniFFI by
//  `impress-store-ffi` (`loopbackTokenInstall` / `loopbackTokenRemove` /
//  `loopbackTokenPath`). This file supplies the one thing only the app knows —
//  which app-group container it can see — and keeps the token in memory for
//  `HTTPAuthPolicy` to compare against. It never writes a file itself.
//
//  Rust's headless default is `~/Library/Group Containers/
//  QG3MEYVHMS.com.impress.suite`; `SharedContainer.rootDirectory` is the same
//  directory as a sandboxed app resolves it (and a per-process temp root
//  under unit tests, where the production container must never be touched).
//

import Foundation
import ImpressKit
import ImpressRustCore

public enum LoopbackToken {

    /// The container the token files live under: the suite app group.
    public static var containerRoot: URL { SharedContainer.rootDirectory }

    /// Mint and place this launch's token for the server bound to `port`.
    /// Returns the token and the path it was written to.
    public static func install(port: UInt16) throws -> LoopbackTokenInstall {
        try loopbackTokenInstall(containerRoot: containerRoot.path, port: port)
    }

    /// Remove the token file for `port` (the server is stopping). A file
    /// that is already gone is not an error.
    public static func remove(port: UInt16) throws {
        try loopbackTokenRemove(containerRoot: containerRoot.path, port: port)
    }

    /// Where the token file for `port` lives — for a log line or a status
    /// route, so a caller can be told where to read.
    public static func path(port: UInt16) -> String {
        loopbackTokenPath(containerRoot: containerRoot.path, port: port)
    }
}
