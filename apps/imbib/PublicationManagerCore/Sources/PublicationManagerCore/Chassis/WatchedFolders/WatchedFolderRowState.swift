// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). Data only: no SwiftUI,
// no AppKit, no store. The renderers consume it; nothing here consumes them.
//
//  WatchedFolderRowState.swift
//  PublicationManagerCore
//
//  ADR-0023 D2 — "a watched folder is a feed", as the sidebar sees it.
//
//  ── What D2 actually asks for ───────────────────────────────────────────────
//
//  "Watched folders are … surfaced in each app's sidebar through the existing
//   feed machinery — not a new sidebar concept. Refresh is the feed refresh
//   verb; per-folder counts are feed badges; a folder on an unindexed volume
//   shows a declared degraded state, never a silent empty."
//
//  A watched folder is therefore NOT a `SmartSearch` (imbib's feeds are saved
//  searches, and a folder is not a query) — it is a feed in the SHAPE it takes
//  in the sidebar: one row, a title, a badge, a refresh verb, a state.
//
//  ── Why this is additive to the chassis and edits nothing ───────────────────
//
//  `RecordSidebarScope.host(kind, key:)` exists precisely for rows whose
//  meaning only the host knows, and its own doc comment names FEEDS as one of
//  the four things it was added for. So a watched-folder row is a `.host` scope
//  with its own key prefix, emitted through `RecordSidebarSectionContent(nodes:)`
//  from the host's `RecordSidebarDataSource.sectionContent` closure — a seam
//  whose every member already defaults, and which imbib, impart and impress
//  already fill in.
//
//  Nothing in `RecordSidebarModel`, `RecordSidebarBuilder`, `RecordSidebarView`
//  or `ImbibSidebarViewModel` changes. What this file adds is the row VALUE and
//  the ONE typed route vocabulary the `.host` doc comment insists a host build
//  its keys through ("never by spelling literals at call sites").
//
//  ── The one thing a renderer must not do ────────────────────────────────────
//
//  Show `count` when `state.countIsTrustworthy` is false. `badgeCount` is the
//  property that enforces it, and it is the reason this type exposes a derived
//  badge rather than the raw number: the "unindexed volume renders as 0 files"
//  bug is one `count: folder.discoveredCount` away at every call site that gets
//  to make the decision itself.
//

import Foundation

// MARK: - Route vocabulary

/// The `.host` key space for watched folders.
///
/// ONE type, per the `RecordSidebarScope.host` contract, so the round trip
/// (row → selection → row, and notification → selection) is single-sourced.
/// A host that adds watched folders to its own route enum should delegate to
/// this rather than re-spelling `"watched-folder.…"`.
public enum WatchedFolderRoute: Hashable, Sendable {

    /// One folder's row.
    case folder(WatchedFolderID)

    /// The container row, when a host groups its folders under one parent
    /// ("Watched Folders"). Optional — a host may list folders flat.
    case allFolders

    /// The prefix every watched-folder host key starts with. Public because a
    /// host's `init?(key:)` needs to recognise keys it did not build.
    public static let keyPrefix = "watched-folder"

    public var key: String {
        switch self {
        case .allFolders: return "\(Self.keyPrefix).all"
        case .folder(let id): return "\(Self.keyPrefix).\(id.storageKey)"
        }
    }

    public init?(key: String) {
        guard key.hasPrefix(Self.keyPrefix + ".") else { return nil }
        let tail = String(key.dropFirst(Self.keyPrefix.count + 1))
        if tail == "all" {
            self = .allFolders
            return
        }
        guard let uuid = UUID(uuidString: tail) else { return nil }
        self = .folder(WatchedFolderID(uuid))
    }

    /// The chassis scope for this route, bound to the record kind whose files
    /// the folder discovers.
    ///
    /// `kind` is the HOST's answer (imbib → `.publication`, imprint →
    /// `.manuscript`), which is why it is a parameter and not baked in — the
    /// same folder machinery serves every app's kind, per the ingest map.
    public func scope(kind: RecordKindID?) -> RecordSidebarScope {
        .host(kind, key: key)
    }
}

// MARK: - Row state

/// One watched folder, as the sidebar needs it.
///
/// A snapshot value, rebuilt rather than mutated — the shape every other
/// sidebar row model in this chassis takes, and the reason a row can be
/// diffed by `Equatable` instead of observed.
public struct WatchedFolderRowState: Identifiable, Hashable, Sendable {

    public let id: WatchedFolderID

    /// Row title. The folder's name, not its path.
    public let displayName: String

    /// Full path, for the tooltip / detail line and for "Reveal in Finder".
    /// nil when the bookmark has never resolved.
    public let path: String?

    /// What the folder can currently do (D6). Rendered VERBATIM via
    /// `state.label` — never paraphrased, never replaced by an empty state.
    public let state: WatchedFolderState

    /// Files the last completed discovery found. This is the RAW number and a
    /// renderer should not read it directly; see `badgeCount`.
    public let discoveredCount: Int

    /// Files discovered since the host last marked the folder seen — the feed
    /// "unread" analogue, and what a badge shows when the host tracks it.
    public let newSinceLastVisit: Int

    /// When discovery last completed. nil = never.
    public let lastScanDate: Date?

    /// Whether an engine is mid-gather or mid-refresh (drives the spinner).
    public let isRefreshing: Bool

    /// Whether the user has this folder switched on. A disabled folder keeps
    /// its row.
    public let isEnabled: Bool

    /// Whether the last walk was truncated by its bounds. Distinct from the
    /// state: a `.fallback` folder whose walk completed has a trustworthy
    /// count; one that hit `maxFiles` does not.
    public let countIsPartial: Bool

    public init(
        id: WatchedFolderID,
        displayName: String,
        path: String? = nil,
        state: WatchedFolderState,
        discoveredCount: Int = 0,
        newSinceLastVisit: Int = 0,
        lastScanDate: Date? = nil,
        isRefreshing: Bool = false,
        isEnabled: Bool = true,
        countIsPartial: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.state = state
        self.discoveredCount = discoveredCount
        self.newSinceLastVisit = newSinceLastVisit
        self.lastScanDate = lastScanDate
        self.isRefreshing = isRefreshing
        self.isEnabled = isEnabled
        self.countIsPartial = countIsPartial
    }

    // MARK: Derived presentation — the honest half

    /// The badge, or nil for "show no badge".
    ///
    /// **The D6 invariant, enforced once.** A badge is a claim that the number
    /// is the whole number. A folder that cannot see its own contents makes no
    /// such claim, so it shows no badge — the STATE carries the meaning
    /// instead. A partial walk is likewise unbadgeable: "≥ 20,000" is not a
    /// badge, and "20000" would be a lie.
    ///
    /// A trustworthy zero is nil too, matching every other feed row in the
    /// suite (`count: unread > 0 ? unread : nil`): an empty inbox feed shows no
    /// "0" either, and consistency here is what makes the DEGRADED case's
    /// missing badge readable as "see the status text" rather than as noise.
    public var badgeCount: Int? {
        guard state.countIsTrustworthy, !countIsPartial else { return nil }
        let value = newSinceLastVisit > 0 ? newSinceLastVisit : discoveredCount
        return value > 0 ? value : nil
    }

    /// The row's glyph. Degraded states carry their own, so the row reads as
    /// degraded before any text is parsed.
    public var systemImage: String {
        guard isEnabled else { return "folder.badge.minus" }
        return state.systemImage
    }

    /// The secondary line: the state's own label, plus the truncation caveat
    /// when it applies.
    ///
    /// Always non-empty, including for `.live`. A row that shows nothing when
    /// healthy and something when broken trains the eye to ignore the field;
    /// worse, it makes "no status" indistinguishable from "status not computed
    /// yet".
    public var statusLine: String {
        var line = isEnabled ? state.label : "Paused"
        if countIsPartial, state.countIsTrustworthy {
            line += " — showing the first \(discoveredCount)"
        }
        return line
    }

    /// Whether a refresh verb should appear on this row at all.
    ///
    /// The chassis rule (`RecordTriageNewTagPrompt`'s, quoted in
    /// `SettingsSectionAvailability`): **omit the affordance rather than
    /// showing a dead one.** A folder we cannot open needs the user to choose
    /// it again, not to press Refresh.
    public var offersRefresh: Bool { isEnabled && state.isRefreshable && !isRefreshing }

    /// Whether the row should offer "Choose Again…" instead.
    public var offersReauthorization: Bool { state.needsReauthorization }

    /// Tooltip / detail text: what the state means, plus when we last looked.
    public var explanation: String {
        var text = state.explanation
        if let lastScanDate {
            text += " Last checked \(Self.relativeDescription(of: lastScanDate))."
        }
        return text
    }

    /// The formatter is built per call rather than cached in a `static let`:
    /// `RelativeDateTimeFormatter` is not `Sendable`, and a shared mutable
    /// global is an error in the Swift 6 language mode. This is a tooltip, not
    /// a hot path.
    private static func relativeDescription(of date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: The sidebar node

    /// This row as a chassis sidebar node.
    ///
    /// The whole integration, in one function. A host returns
    /// `RecordSidebarSectionContent(nodes: rows.map { $0.sidebarNode(kind: .publication) })`
    /// from its existing `sectionContent` closure and the folder appears
    /// wherever that section renders — no chassis edit, no new node kind, no
    /// new section type.
    ///
    /// The title carries the state for degraded rows because
    /// `RecordSidebarNode` has no subtitle field and D6's requirement is that
    /// the state be VISIBLE, not that it be visible in a particular slot. A
    /// host with a richer row (a `nodeAccessory` in `RecordSidebarHostChrome`,
    /// or macOS's outline row) should render `statusLine` properly and pass
    /// `includesStateInTitle: false`.
    public func sidebarNode(
        kind: RecordKindID?, includesStateInTitle: Bool = true
    ) -> RecordSidebarNode {
        let title = (includesStateInTitle && (state.isDegraded || !isEnabled))
            ? "\(displayName) — \(statusLine)"
            : displayName
        return RecordSidebarNode(
            scope: WatchedFolderRoute.folder(id).scope(kind: kind),
            title: title,
            systemImage: systemImage,
            count: badgeCount)
    }
}

// MARK: - Collections

public extension Array where Element == WatchedFolderRowState {

    /// The rows as sidebar nodes, in the order given.
    func sidebarNodes(
        kind: RecordKindID?, includesStateInTitle: Bool = true
    ) -> [RecordSidebarNode] {
        map { $0.sidebarNode(kind: kind, includesStateInTitle: includesStateInTitle) }
    }

    /// A parent row with the folders as children — the shape a host uses when
    /// it wants one collapsible "Watched Folders" entry rather than N siblings.
    ///
    /// The parent's badge is the sum of the children's, and it is nil the
    /// moment ANY child's count is untrustworthy: a total that silently omits
    /// an unindexed folder is the same lie one level up.
    func sidebarParentNode(
        kind: RecordKindID?,
        title: String = "Watched Folders",
        systemImage: String = "folder.badge.gearshape"
    ) -> RecordSidebarNode {
        let children = sidebarNodes(kind: kind)
        let anyUntrustworthy = contains { !$0.state.countIsTrustworthy || $0.countIsPartial }
        let total = compactMap(\.badgeCount).reduce(0, +)
        return RecordSidebarNode(
            scope: WatchedFolderRoute.allFolders.scope(kind: kind),
            title: title,
            systemImage: systemImage,
            count: (anyUntrustworthy || total == 0) ? nil : total,
            children: children)
    }

    /// Folders whose state the user should be told about.
    var degraded: [WatchedFolderRowState] { filter { $0.state.isDegraded } }
}
