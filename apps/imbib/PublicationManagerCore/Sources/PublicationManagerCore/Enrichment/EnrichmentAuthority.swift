import Foundation
import ImpressKit
import ImpressLogging

/// Who owns **autonomous** enrichment on this device.
///
/// Two enrichers exist and they were both running: imbib's in-app
/// `EnrichmentCoordinator` (ADS via Swift source clients, plus Apple
/// Intelligence auto-tagging) and impel's task kernel (`metadata-resolve` →
/// `keyword-tag`, via `impress-sources` in Rust). Both watch the same
/// population — papers with no enrichment date — so every newly ingested paper
/// was fetched twice from the same APIs and classified twice against two
/// different vocabularies, with the winner decided by which one happened to
/// write last.
///
/// The rule is the suite's shape, not a preference: **impel owns agent
/// orchestration whenever it is installed.** A machine with only imbib has no
/// orchestrator, so imbib does its own enrichment; a machine with impel has
/// one, and imbib defers to it.
///
/// This governs only work nobody asked for. A human pressing a button still
/// gets the answer they pressed for — see `EnrichmentCoordinator`.
public enum EnrichmentAuthority: String, Sendable, CaseIterable {
    /// imbib's in-app coordinator: background scheduler, immediate feed
    /// enrichment, `classifyAndTagAfterEnrichment`.
    case imbib

    /// impel's task kernel, driven by `impel-taskd`'s `EnrichmentSpawnRule`.
    case impel

    /// One line for a log or a status surface.
    public var explanation: String {
        switch self {
        case .imbib:
            return "imbib enriches its own library (impel is not installed on this Mac)"
        case .impel:
            return "impel owns enrichment (metadata-resolve → keyword-tag); imbib's coordinator stands down"
        }
    }
}

/// Resolves the [`EnrichmentAuthority`] for this device.
///
/// Deliberately a free function over a stored setting: "is impel installed?"
/// is a fact about the machine that can change between launches (the user
/// installs impel, or throws it away), and a value cached at first launch
/// would keep imbib enriching for the life of the process after impel
/// arrived — the exact latch-versus-lock mistake the service backends made.
public enum EnrichmentAuthorityPolicy {
    /// Suite-wide override key. Absent (the normal case) means "decide from
    /// what is installed"; `"imbib"` or `"impel"` forces the answer.
    ///
    /// The escape hatch exists because the automatic rule can be wrong in one
    /// direction that matters: impel installed but its daemon never set up, so
    /// deferring to it means nothing enriches at all. Setting this to `imbib`
    /// takes the library back.
    public static let overrideKey = "enrichment.authority"

    /// Test seam. `nil` in every shipping path.
    nonisolated(unsafe) static var installedProbe: (@Sendable () -> Bool)?

    /// The authority in force right now.
    public static func current() -> EnrichmentAuthority {
        if let raw = SharedDefaults.suite.string(forKey: overrideKey),
           let forced = EnrichmentAuthority(rawValue: raw) {
            return forced
        }
        let impelInstalled = installedProbe?() ?? SiblingDiscovery.shared.isInstalled(.impel)
        return impelInstalled ? .impel : .imbib
    }

    /// Whether imbib should run enrichment nobody explicitly asked for.
    public static func imbibMayEnrichAutonomously() -> Bool {
        current() == .imbib
    }
}
