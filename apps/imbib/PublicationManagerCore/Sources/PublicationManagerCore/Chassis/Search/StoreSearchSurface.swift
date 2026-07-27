#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  StoreSearchSurface.swift
//  PublicationManagerCore
//
//  WP G4 (ADR-0022 D6): grouped store-wide search — the FIRST real consumer of
//  the mixed-kind list primitives (D4). `items_fts` indexes every kind, the
//  Rust `search_all` kernel returns kind-tagged hits, and this surface renders
//  them as `KindTaggedRow`s bucketed by kind through `AnyRecordListWrapper`.
//  It ships user value now and proves the wrapper + registry row switching
//  before impress exists (D9).
//
//  Deliberate deviation from the WP-X0 rule that custom-surface views live in
//  APP targets: this one is CHASSIS-builtin (see CustomSurface.swift) — it
//  renders only PMC types and every app must have it without opting in.
//
//  Open semantics are honest, not uniform: publications and manuscripts have
//  real open routes today (imbib handoff / imprint editor window), so Return
//  and double-click perform them. Figures, messages, tasks and runs do not, so
//  selecting one shows a compact metadata footer instead of pretending to open
//  something. See the G4-followup note on `openRoute(for:)`.
//

import AppKit
import SwiftUI
import ImpressKit
import ImpressLogging
import ImpressRustCore
import OSLog

// MARK: - Kind labelling

/// Display name for a kind, falling back to the raw identifier so a schema no
/// descriptor claims shows what it actually is instead of "Unknown".
///
/// Kind-INTRINSIC, so it resolves against `BuiltinRecordKinds.registry` rather
/// than a shell's `recordKinds`: imbib's preset does not register
/// `FigureRecordKind`, but a figure hit in imbib's grouped search is still a
/// figure (the same reasoning as `BuiltinRecordKinds.collectionCapable`).
func storeSearchDisplayName(for kind: RecordKindID) -> String {
    BuiltinRecordKinds.registry[kind]?.displayName ?? kind.rawValue
}

// MARK: - Reader

/// Store handle for grouped search.
///
/// Its own `SharedStore` on `SharedWorkspace.databasePath`, exactly like
/// `FigureStoreReader` / `CollectionStoreAdapter` (WAL permits concurrent
/// handles in-process and across processes). Unlike those it is NOT
/// `@MainActor`: FTS across every kind plus per-hit envelope lookups is
/// exactly the work that must not run on the main thread, so the handle is
/// lock-guarded and callers reach it from a detached task.
public final class StoreSearchReader: @unchecked Sendable {

    public static let shared = StoreSearchReader()

    private static let logger = Logger(subsystem: "com.imbib.app", category: "search")

    /// Per-kind cap. The kernel's own default is 20; naming it here keeps the
    /// number visible next to the surface that renders the rows.
    public static let defaultLimitPerKind: UInt32 = 25

    private let lock = NSLock()
    private var store: SharedStore?
    private var didAttemptOpen = false

    init() {}

    /// Lazily-opened handle. Opening on first SEARCH rather than at init keeps
    /// the store-open cost off app launch — no app pays for a surface the user
    /// never visits.
    private func handle() -> SharedStore? {
        if !didAttemptOpen {
            didAttemptOpen = true
            do {
                try SharedWorkspace.ensureDirectoryExists()
                store = try SharedStore.open(path: SharedWorkspace.databasePath)
            } catch {
                Self.logger.error("StoreSearchReader failed to open shared store: \(error)")
            }
        }
        return store
    }

    public var isReady: Bool {
        lock.withLock { handle() != nil }
    }

    // MARK: Mapping (pure — unit-tested)

    /// One search hit as a mixed-list row.
    ///
    /// `item` is the hit's envelope row when it could be fetched; it supplies
    /// the honest date and read/star state that `SharedSearchHit` does not
    /// carry. Without it the row still renders — the date just falls back to
    /// `.distantPast`, which the chrome shows as an old date rather than as
    /// "now", because inventing a timestamp is the one thing a search result
    /// must not do.
    ///
    /// Returns nil only for a hit whose id is not a UUID (a corrupt row).
    /// A hit whose schema no descriptor claims (`imbib/collection`,
    /// `mail-folder`, …) is KEPT, tagged with its normalized schema ref: the
    /// wrapper renders unregistered kinds with the shared mail-style chrome,
    /// so nothing the store matched silently vanishes.
    public static func kindTaggedRow(
        hit: SharedSearchHit, item: SharedItemRow? = nil
    ) -> KindTaggedRow? {
        guard let id = UUID(uuidString: hit.id) else { return nil }
        // The tolerant lookup is shared with the Related section (WP G5) —
        // Chassis/Shared/SchemaRefKindLookup.swift — so both surfaces give one
        // answer for a versioned ref instead of each growing its own check.
        let kind = BuiltinRecordKinds.registry.kind(forStoreSchemaRef: hit.schemaRef)
            ?? RecordKindID(RecordKindSchemaRef.baseName(hit.schemaRef))
        let title = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = item.map {
            Date(timeIntervalSince1970: Double($0.modifiedMs) / 1000)
        } ?? .distantPast
        return KindTaggedRow(
            id: id,
            kind: kind,
            headerText: storeSearchDisplayName(for: kind),
            titleText: title.isEmpty ? "Untitled" : title,
            // The snippet duplicates the title when the match had nothing else
            // quotable — showing it twice reads like a bug.
            previewText: (snippet.isEmpty || snippet == title) ? nil : snippet,
            date: date,
            isRead: item?.isRead ?? true,
            isStarred: item?.isStarred ?? false)
        // Flag colour and tags are deliberately not projected: they would need
        // a per-kind decode the search kernel does not return, and the mixed
        // list is a navigation surface, not a triage surface (G3 v1 scope).
    }

    // MARK: Search

    /// Grouped store-wide search. **Blocking** — call from a detached task.
    ///
    /// Hits arrive already ordered by schema then relevance, so the returned
    /// rows preserve that order and `AnyRecordListWrapper.groups(from:)`
    /// buckets them without re-sorting.
    public func search(
        query: String, limitPerKind: UInt32 = StoreSearchReader.defaultLimitPerKind
    ) -> [KindTaggedRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Three-point trace, point 1: query issued.
        logInfo("query issued q=\"\(trimmed)\" limitPerKind=\(limitPerKind)", category: "search")

        return lock.withLock {
            guard let store = handle() else {
                logWarning("query dropped — shared store unavailable", category: "search")
                return []
            }
            let hits: [SharedSearchHit]
            do {
                hits = try store.searchAll(query: trimmed, limitPerSchema: limitPerKind)
            } catch {
                logError("searchAll failed: \(error)", category: "search")
                return []
            }
            let rows = hits.compactMap { hit -> KindTaggedRow? in
                // Envelope lookup per hit: local point queries on an open WAL
                // handle, bounded by limitPerKind × number of kinds.
                let item = try? store.getItem(id: hit.id)
                return Self.kindTaggedRow(hit: hit, item: item ?? nil)
            }
            // Three-point trace, point 2: hits returned.
            let kinds = Set(rows.map(\.kind.rawValue)).sorted().joined(separator: ",")
            logInfo(
                "hits returned \(hits.count) → \(rows.count) rows across [\(kinds)]",
                category: "search")
            return rows
        }
    }
}

// MARK: - Surface

/// Full-pane store-wide grouped search. Registered chassis-wide as the
/// `store-search` custom surface — present in every app's sidebar.
public struct StoreSearchSurface: View {

    /// Surface id, sidebar node key, and the target of ⌘⇧F in shells that do
    /// not bind it to something app-specific.
    public static let surfaceID = "store-search"
    public static let surfaceTitle = "Search Everything"
    public static let surfaceSystemImage = "magnifyingglass"

    /// The chassis-builtin descriptor. `CustomSurfaceRegistry` always contains
    /// it, so no app opts in.
    public static let descriptor = CustomSurfaceDescriptor(
        id: surfaceID,
        title: surfaceTitle,
        systemImage: surfaceSystemImage,
        makeView: { AnyView(StoreSearchSurface()) })

    /// Debounce before a keystroke becomes an FTS query.
    private static let debounce = Duration.milliseconds(250)

    public init() {}

    @Environment(\.appShellConfiguration) private var shellConfiguration
    @Environment(\.openWindow) private var openWindow

    @State private var query = ""
    @State private var rows: [KindTaggedRow] = []
    @State private var selection = Set<UUID>()
    @State private var isSearching = false
    /// The query the current `rows` answer — nil until the first search
    /// completes, which is how "no results yet" is told apart from "no match".
    @State private var resolvedQuery: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var queryFocused: Bool

    // MARK: Body

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let row = selectedRow, !hasOpenRoute(for: row.kind) {
                Divider()
                metadataFooter(row)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue)
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
        .task {
            // Landing on the surface should put the caret in the field —
            // the whole point of ⌘⇧F.
            try? await Task.sleep(for: .milliseconds(120))
            queryFocused = true
        }
        .onNotifications([
            (.focusStoreSearch, { _ in queryFocused = true }),
        ])
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.surfaceSystemImage)
                .foregroundStyle(.secondary)

            TextField("Search everything…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($queryFocused)
                .accessibilityIdentifier("storeSearch.field")
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }

            if isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView {
                Label(Self.surfaceTitle, systemImage: Self.surfaceSystemImage)
            } description: {
                Text("Search papers, manuscripts, figures, messages, tasks and "
                     + "runs across the whole store. Results are grouped by kind.")
            }
        } else if rows.isEmpty && resolvedQuery != nil && !isSearching {
            ContentUnavailableView {
                Label("No Matches", systemImage: "magnifyingglass")
            } description: {
                Text("Nothing in the store matches \u{201C}\(resolvedQuery ?? query)\u{201D}.")
            }
        } else if rows.isEmpty {
            // First search for this query still running — an empty list here
            // would read as "no matches" a beat before it is true.
            Color.clear
        } else {
            AnyRecordListWrapper(
                rows: rows,
                selection: $selection,
                grouping: .byKind(header: { kind, _ in
                    RecordGroupHeader(
                        title: storeSearchDisplayName(for: kind),
                        systemImage: RecordKindIconography.symbolName(for: kind))
                }),
                onOpen: { open($0) })
        }
    }

    private var selectedRow: KindTaggedRow? {
        AnyRecordListWrapper.primaryRow(
            in: selection,
            of: AnyRecordListWrapper.displayOrderedRows(rows, grouped: true))
    }

    /// Metadata for kinds with no open route — an honest end of the road
    /// rather than a dead Return key.
    ///
    /// G4-followup: embedded per-kind DETAIL for figure/message/task/agent-run
    /// needs detail-pane factories on `RecordViewerRegistry`
    /// (`makeDetailPane`), which G3 deliberately left unregistered for the
    /// kinds whose panes are host-owned. Until those exist this footer is the
    /// whole story a mixed list can tell about them.
    private func metadataFooter(_ row: KindTaggedRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: RecordKindIconography.symbolName(for: row.kind))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.titleText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(storeSearchDisplayName(for: row.kind))
                    if row.date > .distantPast {
                        Text("·")
                        Text(row.date, format: .dateTime.year().month().day())
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
    }

    // MARK: Debounced search

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        // Capture BEFORE the Task (imbib CLAUDE.md: @State read inside a Task
        // body sees the value at EXECUTION time, not at creation time).
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            rows = []
            selection = []
            resolvedQuery = nil
            isSearching = false
            searchTask = nil
            return
        }
        isSearching = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                StoreSearchReader.shared.search(query: trimmed)
            }.value
            guard !Task.isCancelled else { return }
            rows = found
            selection = []
            resolvedQuery = trimmed
            isSearching = false
            // Three-point trace, point 3: rows displayed.
            let groups = AnyRecordListWrapper.groups(from: found)
            logInfo(
                "rows displayed \(found.count) in \(groups.count) group(s) "
                + "for q=\"\(trimmed)\"",
                category: "search")
        }
    }

    // MARK: Open

    /// Whether this kind has a REAL open route from a mixed list today.
    /// Publications hand off by cite key; manuscripts use the same path the
    /// manuscript list uses (imprint's editor window, or the imbib→imprint
    /// handoff). Everything else does not, and says so via the footer.
    private func hasOpenRoute(for kind: RecordKindID) -> Bool {
        kind == .publication || kind == .manuscript
    }

    private func open(_ row: KindTaggedRow) {
        switch row.kind {
        case .manuscript:
            if case .window(let windowID) = shellConfiguration.openBehavior(for: .manuscript) {
                // In-process editor window (imprint's `manuscript-editor`
                // WindowGroup) — exactly what ManuscriptSectionView.onOpen does.
                openWindow(id: windowID, value: row.id)
            } else {
                ManuscriptImprintHandoff.open(manuscriptID: row.id)
            }
            logInfo("open manuscript \(row.id.uuidString)", category: "search")

        case .publication:
            // imbib://open/paper/{citeKey}: the cite key is the addressable
            // handle, so resolve it before handing off.
            guard let detail = RustStoreAdapter.shared.getPublicationDetail(id: row.id),
                  !detail.citeKey.isEmpty,
                  let url = ImpressURL.openPaper(citeKey: detail.citeKey).url else {
                logWarning(
                    "open publication \(row.id.uuidString) — no cite key to hand off",
                    category: "search")
                return
            }
            NSWorkspace.shared.open(url)
            logInfo("open publication \(detail.citeKey)", category: "search")

        default:
            // No route yet — the footer already told the truth; don't fake one.
            break
        }
    }
}
#endif
