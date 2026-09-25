//
//  RustLogBridge.swift
//  ImpressLayout
//
//  The Rust half of the layer, in the Console.
//
//  `impress-layout-service`, `impress-surface-service` and the store FFI log
//  through Rust's `log` facade under the targets `layout` and `surface` —
//  the same categories this package logs under. The FFI forwards those
//  records to whatever `SharedLogSink` the host installs; this is that sink,
//  and it appends each line to ImpressLogging's store, so
//  `/api/logs?category=layout` and `?category=surface` carry Rust's refused
//  verbs, cold starts, external writes, failed sources and failed effects next
//  to Swift's own lines (reviews RL-L6, RS-S11, AC-F18).
//
//  Installed once per process, by the first `LayoutTreeHost` that opens a
//  store (and by any host that calls `installOnce()` itself). Level `info`;
//  set `IMPRESS_RUST_LOG=debug` in the environment for Rust's debug lines
//  (feed deliveries, each successful effect).
//

import Foundation
import ImpressLogging
import ImpressRustCore

public final class RustLogBridge: SharedLogSink, @unchecked Sendable {

    /// Rust calls this on whatever thread logged. `logInfo` and friends are
    /// nonisolated and hop to the store themselves, so nothing here blocks
    /// or calls back into Rust.
    public func log(level: String, category: String, message: String) {
        switch level {
        case "error": logError(message, category: category)
        case "warning": logWarning(message, category: category)
        case "debug": logDebug(message, category: category)
        default: logInfo(message, category: category)
        }
    }

    private static let installed: Bool = {
        let level = ProcessInfo.processInfo.environment["IMPRESS_RUST_LOG"] ?? "info"
        let ok = installLogSink(sink: RustLogBridge(), level: level)
        if ok {
            logInfo("Rust layout/surface logging bridged at level \(level)", category: "layout")
        } else {
            logWarning(
                "Rust logging not bridged: this process already has another `log` logger",
                category: "layout")
        }
        return ok
    }()

    /// Install the bridge once for the process. Idempotent and cheap after
    /// the first call. Returns whether Rust's lines are reaching the Console.
    @discardableResult
    public static func installOnce() -> Bool { installed }
}
