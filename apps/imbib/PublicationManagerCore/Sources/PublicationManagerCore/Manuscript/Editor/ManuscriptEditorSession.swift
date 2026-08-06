// CONTRACT file — CROSS-PLATFORM (macOS + iOS): the editor lifecycle
// seam. Buffer, cursor, debounced compare-and-set save, conflict resolution
// and the session LRU are Foundation + the (cross-platform) compile
// controller; the AppKit lives in the EDITOR VIEWS that consume a session,
// never here. iOS's IOSManuscriptEditorHost re-implements this state machine
// today — adopting this type is now possible (Stage 2b).
//
//  ManuscriptEditorSession.swift
//  PublicationManagerCore
//
//  The editor lifecycle seam (GUI-meld plan §4 "the critical design"). A
//  ManuscriptEditorSession owns one manuscript's editor buffer, cursor, compile
//  controller, and debounced-save machinery. Sessions live in a registry
//  OUTSIDE the SwiftUI view tree so the detail pane can present the Source tab
//  WITHOUT `.id(manuscriptID)` — switching manuscripts or tabs never tears down
//  the NSTextView, its undo stack, or an in-flight compile.

import SwiftUI
import Combine
import ImbibRustCore
import ImpressKit
import OSLog

private let sessionLogger = Logger(subsystem: "com.imbib.app", category: "editor-session")

/// The outcome of a compare-and-set body save.
public enum ManuscriptSaveResult: Sendable {
    case applied
    /// The store held a different `body_content_hash` than we last loaded —
    /// another writer (imprint, or another imbib view) changed the body.
    case conflict(storedHash: String?)
    case failed
}

/// One live editor session for a manuscript. `@Observable` so the Source tab
/// binds directly to `source`/`cursorPosition`/compile state.
@MainActor
@Observable
public final class ManuscriptEditorSession {

    public let manuscriptID: UUID

    /// The editor buffer — the local source of truth between debounced saves.
    public var source: String {
        didSet { if source != oldValue && !isApplyingExternal { noteEdit() } }
    }

    /// True while we set `source` programmatically (fast-forward / take-theirs /
    /// keep-mine) so the `didSet` doesn't schedule a redundant save.
    private var isApplyingExternal = false
    public var cursorPosition: Int = 0

    /// The editor's current selection (UTF-16 NSRange offsets), tracked from
    /// the editor's onSelectionChange — used to anchor a new comment.
    public var selectedRange: NSRange = NSRange(location: 0, length: 0)

    /// Pending programmatic select-and-reveal (diagnostics click). The editor
    /// consumes it generation-gated; a zero-length range is a caret jump.
    /// (`EditorHighlightRequest` is declared at the bottom of this CONTRACT
    /// file: the macOS editor view consumes it, but the request itself is
    /// plain Foundation and iOS hosts may adopt it.)
    public private(set) var highlightRequest: EditorHighlightRequest?

    /// Ask the editor to select `range` (UTF-16 offsets) and scroll it into
    /// view — the "click an error, land on the offending token" verb.
    public func highlight(range: NSRange) {
        let generation = (highlightRequest?.generation ?? 0) + 1
        highlightRequest = EditorHighlightRequest(range: range, generation: generation)
    }

    /// The `body_content_hash` the store held at load / last successful save —
    /// the compare-and-set token guarding against cross-process clobber.
    public private(set) var savedHash: String?

    /// Non-nil when an external writer changed the body under us and we could
    /// not fast-forward; drives a non-modal conflict banner.
    public var conflict: ExternalEditConflict?

    public let format: DocumentFormat
    public let vm: ManuscriptCompileController

    /// True while a save is in flight (suppresses the store-event echo).
    private var isSaving = false
    private var saveTask: Task<Void, Never>?
    private let saveDebounceMs: Int
    private let title: String

    /// The buffer content as of the last successful load or save. Used to tell
    /// whether the user has local unsaved edits when an external change lands.
    private var lastPersistedSource: String

    /// Whether the injected LaTeX compiler can actually produce a PDF on this
    /// host — imbib ships `UnsupportedLaTeXCompiler` (false); imprint installs a
    /// real engine (true). Gates the on-load initial compile so a LaTeX
    /// manuscript opened in imbib doesn't flash an "unsupported" banner before
    /// any edit. (Typst always renders in-process, so it ignores this.)
    private let latexSupported: Bool

    init(
        manuscriptID: UUID,
        source: String,
        format: DocumentFormat,
        title: String,
        savedHash: String?,
        compiler: LaTeXCompiling,
        saveDebounceMs: Int = 200
    ) {
        self.manuscriptID = manuscriptID
        self.source = source
        self.lastPersistedSource = source
        self.format = format
        self.title = title
        self.savedHash = savedHash
        self.saveDebounceMs = saveDebounceMs
        self.latexSupported = compiler.isSupported
        self.vm = ManuscriptCompileController(latexCompiler: compiler)
    }

    /// Kick off a one-shot compile for a freshly loaded manuscript that already
    /// has source. `init` assigns `source` directly, which does NOT fire the
    /// `didSet` that normally schedules a compile — so without this a loaded,
    /// un-edited manuscript shows "Nothing compiled yet" in the Preview until
    /// the first keystroke. Idempotent: no-ops once a PDF exists, while a
    /// compile is running, or for an empty buffer; skips LaTeX where the host
    /// has no compiler (imbib) to avoid a spurious "unsupported" banner.
    public func startInitialCompileIfNeeded() {
        guard vm.pdfData == nil, !vm.isCompiling, !source.isEmpty else { return }
        scheduleCompile()
    }

    /// True when this manuscript is LaTeX but the host installed no LaTeX
    /// engine (imbib ships `UnsupportedLaTeXCompiler`). The Source/Preview tabs
    /// use this to show an "open in imprint to compile" affordance instead of a
    /// failed-compile banner — imbib never attempts a LaTeX compile at all.
    public var latexPreviewUnavailable: Bool { format == .latex && !latexSupported }

    // MARK: - Editing

    /// Called on every buffer change: debounce a guarded save (200ms) and a
    /// format-specific compile.
    private func noteEdit() {
        saveTask?.cancel()
        let debounce = saveDebounceMs
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(debounce))
            guard !Task.isCancelled else { return }
            await self?.saveCAS()
        }
        scheduleCompile()
    }

    private func scheduleCompile() {
        // Markdown renders live from the buffer; plain text has no preview.
        // Neither has a compile pipeline to schedule.
        guard format.previewKind == .compiledPDF else { return }
        // imbib has no LaTeX engine (UnsupportedLaTeXCompiler), so never attempt
        // a LaTeX compile there — it would only set a failed-compile banner. The
        // Source tab surfaces an "open in imprint" affordance instead. Typst
        // always renders in-process, so it is unaffected.
        if latexPreviewUnavailable { return }
        // Format-specific quiet window: LaTeX is heavier, so it waits longer.
        let delay = format == .latex ? 1500 : 400
        vm.scheduleCompile(after: delay) { [weak self] in
            guard let self else { return }
            await self.vm.compile(self.makeCompileInputs())
        }
    }

    public func makeCompileInputs() -> CompileInputs {
        CompileInputs(
            source: source,
            format: format,
            previewFormat: format == .typst ? "svg" : "pdf",
            documentID: manuscriptID,
            documentTitle: title,
            latexEngine: "pdflatex",
            latexShellEscape: false,
            latexShowBoxWarnings: false,
            figuresRoot: ManuscriptFiguresDirectory.manuscriptRoot(for: manuscriptID).path
        )
    }

    // MARK: - Saving (compare-and-set)

    /// Persist the buffer with a `body_content_hash` guard. On conflict, try to
    /// fast-forward (if the store's change matches what we'd have loaded), else
    /// raise `conflict` for the banner.
    @discardableResult
    public func saveCAS() async -> ManuscriptSaveResult {
        isSaving = true
        defer { isSaving = false }
        guard let outcome = RustStoreAdapter.shared.setManuscriptBody(
            id: manuscriptID, body: source, expectedHash: savedHash
        ) else {
            return .failed
        }
        if outcome.applied {
            savedHash = outcome.newHash
            lastPersistedSource = source
            conflict = nil
            // Wake any other window/app editing this manuscript (read-side
            // refresh; the CAS guard above is the clobber-safety invariant).
            ManuscriptSessionRegistry.shared.postManuscriptChanged(id: manuscriptID)
            return .applied
        }
        // Guard rejected: another writer moved the body.
        conflict = ExternalEditConflict(
            manuscriptID: manuscriptID, storedHash: outcome.storedHash)
        sessionLogger.warning(
            "Save conflict for \(self.manuscriptID): stored=\(outcome.storedHash ?? "nil")")
        return .conflict(storedHash: outcome.storedHash)
    }

    /// Synchronous flush for eviction / window close / app resign-active.
    public func flush() {
        saveTask?.cancel()
        // Best-effort synchronous-ish save: fire and let it complete.
        Task { @MainActor [weak self] in await self?.saveCAS() }
    }

    /// Cancel any pending debounced save WITHOUT persisting. Used when the
    /// manuscript is being deleted — a flush (or the debounce firing after the
    /// delete) would write the body back and resurrect the deleted item.
    public func abandonPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    /// React to a store mutation from ANOTHER writer: fast-forward the buffer
    /// when the user hasn't diverged, else raise a conflict.
    public func absorbExternalChange() {
        // Ignore our own echo.
        guard !isSaving else { return }
        guard let detail = RustStoreAdapter.shared.getManuscriptDetail(id: manuscriptID)
        else { return }
        // Already in sync with the store — re-pin the hash and clear.
        if detail.bodyContentHash == savedHash || source == detail.bodyContent {
            savedHash = detail.bodyContentHash
            lastPersistedSource = source
            conflict = nil
            return
        }
        if source == lastPersistedSource {
            // No local unsaved edits — safe to fast-forward to the store body.
            isApplyingExternal = true
            source = detail.bodyContent
            isApplyingExternal = false
            lastPersistedSource = detail.bodyContent
            savedHash = detail.bodyContentHash
            conflict = nil
        } else {
            // Local unsaved edits AND the store diverged — surface a conflict.
            conflict = ExternalEditConflict(
                manuscriptID: manuscriptID, storedHash: detail.bodyContentHash)
        }
    }

    /// Take the store's current body, discarding local edits (conflict banner
    /// "Take theirs").
    public func takeExternal() {
        guard let detail = RustStoreAdapter.shared.getManuscriptDetail(id: manuscriptID)
        else { return }
        isApplyingExternal = true
        source = detail.bodyContent
        isApplyingExternal = false
        lastPersistedSource = detail.bodyContent
        savedHash = detail.bodyContentHash
        conflict = nil
    }

    /// Replace the whole buffer with `body` (a version restore). Applied as an
    /// ordinary edit so it flows through the normal debounced CAS save and a
    /// preview recompile — the editor shows the restored text immediately and
    /// it persists like any other change. Returns the pre-restore source so the
    /// caller can register an undo that swaps back.
    @discardableResult
    public func applyRestoredBody(_ body: String) -> String {
        let previous = source
        source = body   // didSet → noteEdit → debounced save + compile
        return previous
    }

    /// Force our buffer over the store's version (conflict banner "Keep mine").
    public func keepMine() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Unguarded save wins deterministically.
            _ = RustStoreAdapter.shared.setManuscriptBody(
                id: self.manuscriptID, body: self.source, expectedHash: nil)
            if let d = RustStoreAdapter.shared.getManuscriptDetail(id: self.manuscriptID) {
                self.savedHash = d.bodyContentHash
            }
            self.conflict = nil
        }
    }
}

/// A detected external edit awaiting user resolution.
public struct ExternalEditConflict: Sendable, Equatable {
    public let manuscriptID: UUID
    public let storedHash: String?
}

// MARK: - Registry

/// LRU cache of live editor sessions, keyed by manuscript UUID, living OUTSIDE
/// the SwiftUI view tree. The detail pane resolves a session per selection;
/// tab and selection switches never destroy it. Capacity is small (a handful
/// of recently-edited manuscripts on macOS); a session with an unresolved
/// conflict is never evicted.
@MainActor
public final class ManuscriptSessionRegistry {

    public static let shared = ManuscriptSessionRegistry(capacity: 3)

    private var sessions: [UUID: ManuscriptEditorSession] = [:]
    private var lru: [UUID] = []          // most-recent last
    private let capacity: Int

    /// The LaTeX compiler capability injected into new sessions. Defaults to
    /// unsupported (imbib-without-TeX / iOS); imprint installs the real one.
    public var latexCompilerFactory: @MainActor () -> LaTeXCompiling = {
        UnsupportedLaTeXCompiler()
    }

    /// Which app this process is — set by imprint's installer (default .imbib).
    /// Drives which SiblingApp the cross-process "manuscript-changed" Darwin
    /// notification is posted from.
    public var currentApp: SiblingApp = .imbib

    /// Darwin observers for cross-process manuscript changes (kept alive here).
    private var crossProcessObservers: [DarwinObservation] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// The manuscript-change Darwin event name, shared across apps.
    public static let manuscriptChangedEvent = "manuscript-changed"

    /// Install cross-process observers once: when ANY sibling app that edits
    /// manuscripts posts "manuscript-changed", refresh all live sessions so a
    /// second window/app editing the same manuscript updates live (the CAS
    /// guard already prevents clobber at save time; this is the read-side
    /// refresh). Idempotent — self-posted echoes are absorbed harmlessly.
    private func installCrossProcessObserversIfNeeded() {
        guard crossProcessObservers.isEmpty else { return }
        for app in [SiblingApp.imbib, .imprint] {
            let obs = ImpressNotification.observe(
                Self.manuscriptChangedEvent, from: app
            ) { [weak self] in
                Task { @MainActor in self?.refreshAllLiveSessions() }
            }
            crossProcessObservers.append(obs)
        }
    }

    /// Post the cross-process manuscript-changed notification (call after a
    /// manuscript body/metadata write commits).
    public func postManuscriptChanged(id: UUID) {
        ImpressNotification.post(
            Self.manuscriptChangedEvent,
            from: currentApp,
            resourceIDs: [id.uuidString]
        )
    }

    /// Re-check every live session against the store (cross-process refresh).
    public func refreshAllLiveSessions() {
        for session in sessions.values { session.absorbExternalChange() }
    }

    /// Return the cached session for `id`, or load one from the store.
    public func session(for id: UUID) -> ManuscriptEditorSession? {
        installCrossProcessObserversIfNeeded()
        if let existing = sessions[id] {
            touch(id)
            return existing
        }
        guard let detail = RustStoreAdapter.shared.getManuscriptDetail(id: id) else {
            Logger.library.warningCapture(
                "manuscript session: getManuscriptDetail(\(id)) returned nil — no editor",
                category: "manuscripts")
            return nil
        }
        // Diagnostic: reveals why a Source editor is blank (empty body vs blob
        // ref vs source-in-revision). Query via /api/logs?category=manuscripts.
        Logger.library.infoCapture(
            "manuscript session \(id): format=\(detail.format) bodyLen=\(detail.bodyContent.count) "
                + "blobRef=\(detail.bodyIsBlobRef) rev=\(detail.currentRevisionRef ?? "nil") "
                + "title=\(detail.title)",
            category: "manuscripts")
        let body = detail.bodyIsBlobRef ? "" : detail.bodyContent
        let format: DocumentFormat
        if let stored = DocumentFormat(rawValue: detail.format) {
            format = stored
        } else {
            // Manuscripts ingested without a format (agent/bridge-created
            // records write title+status only). Infer rather than assuming
            // Typst — a Markdown body sent to the Typst compiler fails with
            // "expected expression" on its first `# Heading`. Repair the row
            // so the badge, compile decisions, and the HTTP DTO all agree.
            format = DocumentFormat.detect(from: body, title: detail.title)
            Logger.library.warningCapture(
                "manuscript \(id): format '\(detail.format)' unrecognized — inferred "
                    + "\(format.rawValue) from content/title; repairing stored value",
                category: "manuscripts")
            RustStoreAdapter.shared.updateField(
                id: id, field: "format", value: format.rawValue)
        }
        let session = ManuscriptEditorSession(
            manuscriptID: id,
            source: body,
            format: format,
            title: detail.title,
            savedHash: detail.bodyContentHash,
            compiler: latexCompilerFactory()
        )
        sessions[id] = session
        lru.append(id)
        evictIfNeeded()
        // Freshly loaded: `init` set the buffer without firing the edit path, so
        // nothing has compiled yet. Trigger a one-shot compile so the Preview is
        // populated without requiring a keystroke.
        session.startInitialCompileIfNeeded()
        return session
    }

    /// Restore a manuscript's body to `body` (a source pulled from a saved
    /// version). Three steps, in order:
    ///   1. Persist any live buffer edits, then auto-save the CURRENT state as a
    ///      safety version (`reason: auto-before-restore`) so a restore never
    ///      silently discards work.
    ///   2. Apply the restored body to the live editor session (which repaints
    ///      the editor and persists via the normal CAS path).
    ///   3. Register a store-level undo — Cmd+Z returns to the pre-restore body,
    ///      Cmd+Shift+Z re-applies the restore.
    ///
    /// The safety version and the undo are complementary: undo is the quick
    /// in-session reversal; the version is a durable record if the session is
    /// later evicted.
    public func restoreBody(manuscriptID: UUID, to body: String) {
        guard let session = session(for: manuscriptID) else {
            // No resolvable session (e.g. the manuscript vanished) — best-effort
            // unguarded write so the restore isn't silently dropped.
            _ = RustStoreAdapter.shared.setManuscriptBody(
                id: manuscriptID, body: body, expectedHash: nil)
            return
        }
        let previous = session.source
        Task { @MainActor in
            // Flush the live buffer so the safety snapshot captures the true
            // pre-restore state, not a stale store copy.
            await session.saveCAS()
            RustStoreAdapter.shared.createManuscriptRevision(
                manuscriptID: manuscriptID,
                tag: "Before restore",
                reason: "auto-before-restore")
            session.applyRestoredBody(body)
            UndoCoordinator.shared.registerUndoClosure(
                actionName: "Restore Version",
                undo: { [weak session] in session?.applyRestoredBody(previous) },
                redo: { [weak session] in session?.applyRestoredBody(body) }
            )
        }
    }

    /// Notify all live sessions of a store mutation (cross-process wake-up).
    public func broadcastExternalChange(to ids: Set<UUID>) {
        for id in ids {
            sessions[id]?.absorbExternalChange()
        }
    }

    /// Flush every live session (app termination hook).
    public func flushAll() {
        for session in sessions.values { session.flush() }
    }

    private func touch(_ id: UUID) {
        lru.removeAll { $0 == id }
        lru.append(id)
    }

    /// Drop the session for a manuscript that is about to be DELETED: cancel
    /// its debounced save and remove it WITHOUT flushing. Flushing here (or
    /// letting the debounce fire post-delete) would re-save the body and
    /// resurrect the deleted item through the CAS path.
    public func discard(id: UUID) {
        guard let session = sessions[id] else { return }
        session.abandonPendingSave()
        sessions[id] = nil
        lru.removeAll { $0 == id }
        Logger.library.infoCapture(
            "discarded editor session for deleted manuscript \(id)",
            category: "manuscripts")
    }

    private func evictIfNeeded() {
        while sessions.count > capacity {
            // Evict the oldest session that has no unresolved conflict.
            guard let victim = lru.first(where: { sessions[$0]?.conflict == nil }) else {
                return  // all remaining sessions are conflicted — keep them
            }
            sessions[victim]?.flush()
            sessions[victim] = nil
            lru.removeAll { $0 == victim }
        }
    }
}

/// A programmatic select-and-reveal request for the source editor
/// (diagnostics click → offending token). Generation-gated so each request
/// fires exactly once however many times the consuming view updates. Plain
/// Foundation (NSRange in UTF-16 offsets) so both platforms' editors can
/// consume it; today the macOS `TypstEditorRepresentable` does.
public struct EditorHighlightRequest: Equatable, Sendable {
    public let range: NSRange
    public let generation: Int

    public init(range: NSRange, generation: Int) {
        self.range = range
        self.generation = generation
    }
}
