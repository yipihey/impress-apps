import Foundation

/// GUI-meld Phase 3 — platform capability for LaTeX compilation.
///
/// LaTeX compilation spawns a local TeX distribution (or the embedded Tectonic
/// engine) via `Process`, which is desktop-only. Rather than branching on
/// `#if os(macOS)` inside the compile controller's decision logic, the platform
/// injects a `LaTeXCompiling` object at composition time:
///
/// - **macOS (imprint / imbib-with-TeX)** injects `SystemLaTeXCompiler` (real
///   system/embedded TeX + runtime distribution detection, SyncTeX load,
///   project dependency scan). That implementation stays in the imprint app
///   target because it pulls a large macOS-only service closure
///   (`LaTeXCompilationService`, `SyncTeXService`, `LaTeXProjectService`,
///   `TeXDistributionManager`, Veusz figure mirroring); it conforms to this
///   protocol and is injected in.
/// - **iOS**, and any desktop host without a TeX toolchain (e.g.
///   imbib-macOS-without-TeX), injects `UnsupportedLaTeXCompiler` (the default,
///   shipped here in PMC).
///
/// This keeps `ManuscriptCompileController` free of platform conditionals and of
/// the macOS-only services, so the compile core is a self-contained,
/// capability-injected unit shared by both GUIs.

/// Snapshot of everything a LaTeX compile needs, as a value type — the
/// implementation reads no live SwiftUI state (see CLAUDE.md: "Capture @State
/// Before Async Work").
public struct LaTeXCompileRequest: Sendable {
    public let source: String
    public let documentID: UUID
    /// Raw engine identifier from settings (`LaTeXEngine.rawValue`). Resolved to
    /// a concrete engine inside the macOS implementation; the cross-platform
    /// controller never needs the (macOS-only) `LaTeXEngine` type.
    public let engineRaw: String
    public let shellEscape: Bool
    public let showBoxWarnings: Bool

    public init(
        source: String,
        documentID: UUID,
        engineRaw: String,
        shellEscape: Bool,
        showBoxWarnings: Bool
    ) {
        self.source = source
        self.documentID = documentID
        self.engineRaw = engineRaw
        self.shellEscape = shellEscape
        self.showBoxWarnings = showBoxWarnings
    }
}

/// How a LaTeX compile ended — mirrors the three distinct state-publish paths
/// the controller had inline, so success/engine-failure/preflight-failure each
/// update exactly the same view-model fields they did before extraction.
public enum LaTeXCompileOutcome: Sendable {
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
public struct LaTeXCompileResult: Sendable {
    public var outcome: LaTeXCompileOutcome
    public var pdfData: Data?
    /// Combined errors + warnings (the controller's `latexDiagnostics`).
    public var diagnostics: [LaTeXDiagnostic]
    /// Filtered + formatted `"file:line: message"` list (the controller's
    /// `compilationWarnings`).
    public var formattedWarnings: [String]
    public var compilationTimeMs: Int
    /// User-facing error, set only for `.engineFailed` / `.preflightFailed`.
    public var errorMessage: String?
    /// SyncTeX sidecar produced by a successful compile (for post-compile load).
    public var synctexURL: URL?
    /// The on-disk `.tex` that was compiled (for the dependency scan).
    public var sourceURL: URL?

    public init(
        outcome: LaTeXCompileOutcome,
        pdfData: Data?,
        diagnostics: [LaTeXDiagnostic],
        formattedWarnings: [String],
        compilationTimeMs: Int,
        errorMessage: String?,
        synctexURL: URL?,
        sourceURL: URL?
    ) {
        self.outcome = outcome
        self.pdfData = pdfData
        self.diagnostics = diagnostics
        self.formattedWarnings = formattedWarnings
        self.compilationTimeMs = compilationTimeMs
        self.errorMessage = errorMessage
        self.synctexURL = synctexURL
        self.sourceURL = sourceURL
    }

    /// The result an `UnsupportedLaTeXCompiler` returns.
    public static let unsupported = LaTeXCompileResult(
        outcome: .preflightFailed,
        pdfData: nil,
        diagnostics: [],
        formattedWarnings: [],
        compilationTimeMs: 0,
        errorMessage: "LaTeX compilation is only available on macOS with a TeX toolchain. Use Typst format on this device.",
        synctexURL: nil,
        sourceURL: nil
    )
}

/// Post-compile follow-up (SyncTeX load + project dependency scan) results.
public struct LaTeXPostCompileResult: Sendable {
    public var projectFiles: [URL]
    public var mainFileURL: URL?

    public init(projectFiles: [URL], mainFileURL: URL?) {
        self.projectFiles = projectFiles
        self.mainFileURL = mainFileURL
    }

    public static let empty = LaTeXPostCompileResult(projectFiles: [], mainFileURL: nil)
}

/// Platform capability for compiling LaTeX. Injected into the compile
/// controller so the controller carries no `#if os(macOS)` in its decision
/// logic.
public protocol LaTeXCompiling: Sendable {
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
public struct UnsupportedLaTeXCompiler: LaTeXCompiling {
    public init() {}

    public var isSupported: Bool { false }

    public func compile(_ request: LaTeXCompileRequest) async -> LaTeXCompileResult {
        .unsupported
    }

    public func loadPostCompile(synctexURL: URL?, sourceURL: URL?) async -> LaTeXPostCompileResult {
        .empty
    }
}
