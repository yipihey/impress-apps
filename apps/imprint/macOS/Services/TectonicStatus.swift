#if IMPRINT_TECTONIC
import Foundation
import Observation

/// Observable status for the embedded Tectonic engine's slow one-time work
/// (first-run TeX bundle fetch + engine warm-up). The editor can surface a
/// "Fetching TeX packages…" indicator by observing `TectonicStatus.shared`.
@MainActor
@Observable
final class TectonicStatus {
    static let shared = TectonicStatus()
    private init() {}

    enum Phase: String {
        case idle
        case warming        // launch warm-up
        case fetchingBundle // first real compile fetching the package bundle
    }

    /// Current phase; `.idle` when nothing slow is happening.
    private(set) var phase: Phase = .idle
    var isBusy: Bool { phase != .idle }

    /// Human-readable status line for the UI (empty when idle).
    var message: String {
        switch phase {
        case .idle: return ""
        case .warming: return "Warming Tectonic engine…"
        case .fetchingBundle: return "Fetching TeX packages (first run)…"
        }
    }

    nonisolated func begin(_ phase: Phase) {
        Task { @MainActor in self.phase = phase }
    }
    nonisolated func finish() {
        Task { @MainActor in self.phase = .idle }
    }

    /// True when the Tectonic package bundle appears to already be cached (so a
    /// compile won't pay the slow first-run fetch). Heuristic: the cache dir
    /// exists and is non-empty.
    nonisolated static func bundleCacheExists(in cacheDir: URL?) -> Bool {
        guard let cacheDir else { return false }
        let contents = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        return (contents?.isEmpty == false)
    }
}
#endif
