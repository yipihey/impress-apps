#if os(macOS)
import AppKit
import ImbibRustCore

/// GUI-meld Phase 3 — dependency seam for the shared manuscript source editor.
///
/// The editor stack (`SourceEditorView`, `TypstTextView`, the citation palette /
/// hover controllers, the bracket ruler) moved out of the imprint app target
/// into PMC so imbib and imprint share one editor. A handful of the editor's
/// behaviours reach into large app-specific services that stay in the host app
/// (AI completion, AI author-tasks, the imbib library search backing citations,
/// LaTeX completion, real-time collaboration presence). Rather than thread a
/// dozen parameters through the AppKit view hierarchy, the host installs those
/// capabilities once at launch into this process-wide environment; the editor
/// reads them here.
///
/// All hooks have inert defaults, so an app that installs nothing (imbib today)
/// gets a fully functional plain editor with no AI, no citation search, and no
/// collaboration — exactly the graceful-degradation the old `#if os(macOS)` /
/// `.shared` singletons provided, minus the hard app coupling.
@MainActor
public final class ManuscriptEditorEnvironment {
    public static let shared = ManuscriptEditorEnvironment()

    private init() {}

    // MARK: - Inline AI completion (ghost text)

    /// Drives inline "ghost text" completions. Default: inert (never suggests).
    /// imprint installs its `InlineCompletionService.shared`.
    public var inlineCompletion: any InlineCompletionProviding = InertInlineCompletion()

    // MARK: - Citation search (imbib library, backing the palette + hover)

    /// Looks up / searches the imbib library for the inline citation palette and
    /// cite-key hover preview. Default: nil (no results → palette shows "no
    /// matches", hover shows nothing). imprint installs `ImprintPublicationService.shared`.
    public var citationSearch: (any ManuscriptCitationSearching)?

    /// Cite keys already used in the current manuscript, for ranking the palette.
    /// Default: empty. imprint installs `{ Set(BibliographyGenerator.shared.extractedCiteKeys) }`.
    public var citedKeys: @MainActor () -> Set<String> = { [] }

    // MARK: - AI author-tasks (the ⌃⌘ "AI Assist" catalog)

    /// Whether a curated author-task id is enabled. Default: all disabled (so no
    /// AI Assist section appears). imprint installs `AITaskPreferences.isEnabled`.
    public var isAITaskEnabled: @MainActor (_ id: String) -> Bool = { _ in false }

    /// Resolves a curated author-task id to display metadata (title + SF Symbol).
    /// Default: nil (unresolved → task hidden). imprint installs a lookup over
    /// `AIContextMenuService.shared.actions`.
    public var aiTaskMetadata: @MainActor (_ id: String) -> (title: String, icon: String)? = { _ in nil }

    /// Invoked when the user picks an AI author-task (from a bracket, the
    /// selection menu, or a ⌃⌘ shortcut), with the task id and target range.
    /// Default: no-op. imprint installs a `.runInlineAITask` notification post.
    public var onAITaskRequested: @MainActor (_ actionId: String, _ range: NSRange) -> Void = { _, _ in }

    // MARK: - LaTeX word completion

    /// Async LaTeX completion for the given prefix/source/offset, returning the
    /// completion strings. Default: none. imprint installs a call into
    /// `LaTeXCompletionProvider.shared`.
    public var latexCompletions: @MainActor (_ prefix: String, _ source: String, _ offset: Int) async -> [String] = { _, _, _ in [] }

    // MARK: - Collaboration presence

    /// Called on selection change so the host can update a collaboration presence
    /// cursor. Default: no-op. imprint installs `{ $0.updateCollaborationCursor() }`.
    public var presenceCursorHook: @MainActor (_ textView: NSTextView) -> Void = { _ in }
}

// MARK: - Inline completion capability

/// Inline AI ghost-text completion. Refines `Observable` so SwiftUI still tracks
/// `isLoading`/`ghostText` reactively when the editor reads them through the
/// existential (imprint's `InlineCompletionService` is `@Observable`).
@MainActor
public protocol InlineCompletionProviding: AnyObject, Observable {
    /// Current ghost-text suggestion ("" when none).
    var ghostText: String { get }
    /// Whether a completion request is in flight (drives the "AI" pill).
    var isLoading: Bool { get }
    /// Request a completion for the given text + caret position.
    func requestCompletion(text: String, cursorPosition: Int)
    /// Accept the current suggestion, returning the text to insert (or nil).
    func acceptCompletion() -> String?
    /// Clear any pending/visible suggestion.
    func clearCompletion()
}

/// Default inert completion provider — never suggests anything.
@MainActor
@Observable
public final class InertInlineCompletion: InlineCompletionProviding {
    public init() {}
    public var ghostText: String { "" }
    public var isLoading: Bool { false }
    public func requestCompletion(text: String, cursorPosition: Int) {}
    public func acceptCompletion() -> String? { nil }
    public func clearCompletion() {}
}

// MARK: - Citation search capability

/// Read-only lookup + search over the host's publication library, returning the
/// shared Rust `BibliographyRow` rows the editor's citation UI renders.
@MainActor
public protocol ManuscriptCitationSearching {
    /// The library row for an exact cite key, if present.
    func findByCiteKey(_ citeKey: String) -> BibliographyRow?
    /// Multi-term search over the library, capped at `limit` rows.
    func search(_ query: String, limit: Int) -> [BibliographyRow]
}
#endif // os(macOS)
