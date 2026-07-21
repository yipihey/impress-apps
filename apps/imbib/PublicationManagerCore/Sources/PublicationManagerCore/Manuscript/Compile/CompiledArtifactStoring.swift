import Foundation

/// Side-effect cache for compile artifacts (PDF bytes, LaTeX diagnostics),
/// keyed by document id.
///
/// GUI-meld Phase 3: the compile controller used to write directly into
/// imprint's `DocumentRegistry.shared` (a singleton generic over imprint app
/// types that cannot move into PMC). That coupling is now inverted behind this
/// protocol so the controller stays free of any app-target type:
///
/// - imprint injects a `DocumentRegistry`-backed store (so its HTTP API keeps
///   serving compiled PDFs + diagnostics), and
/// - imbib / any host that doesn't need the cache injects the default
///   `NoopCompiledArtifactStore`.
@MainActor
public protocol CompiledArtifactStoring {
    /// Store the compiled PDF for `documentID`.
    func cachePDF(_ data: Data, for documentID: UUID)

    /// Store the LaTeX diagnostics produced for `documentID`.
    func cacheDiagnostics(_ diagnostics: [LaTeXDiagnostic], for documentID: UUID)
}

/// Default no-op store — nothing is cached. Used by hosts that don't expose an
/// HTTP artifact API (imbib today) and as the controller's default.
public struct NoopCompiledArtifactStore: CompiledArtifactStoring {
    public init() {}
    public func cachePDF(_ data: Data, for documentID: UUID) {}
    public func cacheDiagnostics(_ diagnostics: [LaTeXDiagnostic], for documentID: UUID) {}
}
