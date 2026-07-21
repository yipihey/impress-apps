import Foundation

/// GUI-meld Phase 3 PREP — platform capability for LaTeX compilation.
///
/// LaTeX compilation spawns a local TeX distribution (or the embedded Tectonic
/// engine) via `Process`, which is desktop-only. Rather than branching on
/// `#if os(macOS)` inside the compile controller's decision logic, the platform
/// injects a `LaTeXCompiling` object at composition time:
///
/// - **macOS** injects `SystemLaTeXCompiler` (real system/embedded TeX + runtime
///   distribution detection, SyncTeX load, project dependency scan).
/// - **iOS**, and any future desktop host without a TeX toolchain (e.g.
///   imbib-macOS-without-TeX), injects `UnsupportedLaTeXCompiler`.
///
/// This keeps `ManuscriptCompileController` free of platform conditionals and
/// makes the compile core a self-contained, capability-injected unit that can
/// later move into the shared GUI package with a small diff.

/// Snapshot of everything a LaTeX compile needs, as a value type — the
/// implementation reads no live SwiftUI state (see CLAUDE.md: "Capture @State
/// Before Async Work").
struct LaTeXCompileRequest: Sendable {
    let source: String
    let documentID: UUID
    /// Raw engine identifier from settings (`LaTeXEngine.rawValue`). Resolved to
    /// a concrete engine inside the macOS implementation; the cross-platform
    /// controller never needs the (macOS-only) `LaTeXEngine` type.
    let engineRaw: String
    let shellEscape: Bool
    let showBoxWarnings: Bool
}

/// How a LaTeX compile ended — mirrors the three distinct state-publish paths
/// the controller had inline, so success/engine-failure/preflight-failure each
/// update exactly the same view-model fields they did before extraction.
enum LaTeXCompileOutcome: Sendable {
    /// The engine ran and produced a PDF.
    case succeeded
    /// The engine ran but produced no PDF (compile errors, non-zero exit).
    case engineFailed
    /// The engine never ran: temp-file write failed, the call threw, or the
    /// platform doesn't support LaTeX. Only `errorMessage` is published; the
    /// prior diagnostics/warnings/timing are left untouched (as before).
    case preflightFailed
}

/// Result of one LaTeX compile, shaped to exactly the state the compile
/// controller publishes. Never carries a thrown error — failures are reported
/// through `outcome` + `errorMessage` so the publish path is uniform.
struct LaTeXCompileResult: Sendable {
    var outcome: LaTeXCompileOutcome
    var pdfData: Data?
    /// Combined errors + warnings (the controller's `latexDiagnostics`).
    var diagnostics: [LaTeXDiagnostic]
    /// Filtered + formatted `"file:line: message"` list (the controller's
    /// `compilationWarnings`).
    var formattedWarnings: [String]
    var compilationTimeMs: Int
    /// User-facing error, set only for `.engineFailed` / `.preflightFailed`.
    var errorMessage: String?
    /// SyncTeX sidecar produced by a successful compile (for post-compile load).
    var synctexURL: URL?
    /// The on-disk `.tex` that was compiled (for the dependency scan).
    var sourceURL: URL?

    /// The result an `UnsupportedLaTeXCompiler` returns.
    static let unsupported = LaTeXCompileResult(
        outcome: .preflightFailed,
        pdfData: nil,
        diagnostics: [],
        formattedWarnings: [],
        compilationTimeMs: 0,
        errorMessage: "LaTeX compilation is only available on macOS. Use Typst format on this device.",
        synctexURL: nil,
        sourceURL: nil
    )
}

/// Post-compile follow-up (SyncTeX load + project dependency scan) results.
struct LaTeXPostCompileResult: Sendable {
    var projectFiles: [URL]
    var mainFileURL: URL?

    static let empty = LaTeXPostCompileResult(projectFiles: [], mainFileURL: nil)
}

/// Platform capability for compiling LaTeX. Injected into the compile
/// controller so the controller carries no `#if os(macOS)` in its decision
/// logic.
protocol LaTeXCompiling: Sendable {
    /// Whether this platform/environment can compile LaTeX at all.
    var isSupported: Bool { get }

    /// Compile the request to a PDF (+ diagnostics). Never throws — outcomes are
    /// reported via `LaTeXCompileResult`.
    func compile(_ request: LaTeXCompileRequest) async -> LaTeXCompileResult

    /// Load SyncTeX + scan project dependencies after a successful compile.
    /// Run off the critical path by the controller so it stays cancellable.
    func loadPostCompile(synctexURL: URL?, sourceURL: URL?) async -> LaTeXPostCompileResult
}

/// LaTeX compilation is unavailable (iOS, or a desktop host without a TeX
/// toolchain). Compiling returns a friendly "unsupported" result; there is no
/// post-compile work.
struct UnsupportedLaTeXCompiler: LaTeXCompiling {
    var isSupported: Bool { false }

    func compile(_ request: LaTeXCompileRequest) async -> LaTeXCompileResult {
        .unsupported
    }

    func loadPostCompile(synctexURL: URL?, sourceURL: URL?) async -> LaTeXPostCompileResult {
        .empty
    }
}
