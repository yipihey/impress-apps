// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): the four per-kind list
// scopes and their `RecordScopeKey` conformances.
//
//  RecordScopeKey+ListScopes.swift
//  PublicationManagerCore
//
//  History: the conformances were split out of RecordScopeKey.swift in the iOS
//  foundation pass as `RecordScopeKey+MacScopes.swift`, gated because each
//  scope ENUM was declared inside its macOS-gated list wrapper. Stage 2a moved
//  the four enums here instead — they are Foundation value types (UUID,
//  FlagColor, JournalManuscriptStatus, a state string); only the WRAPPERS are
//  AppKit-adjacent. iOS can now name the scope a surface is showing, which is
//  what `RecordSidebarScope` bridging needs.
//
//  Verbatim moves — no behaviour change; only the file the code sits in moved.
//

import Foundation
import ImpressFTUI

// MARK: - Scopes

/// What subset of manuscripts the list shows.
public enum ManuscriptListScope: Hashable, Sendable {
    case all
    case status(JournalManuscriptStatus)
    case folder(UUID)
    case flagged(FlagColor?)
    /// Every manuscript carrying one tag path (ADR-0023 W3).
    ///
    /// The scope a watched manuscript folder's sidebar row resolves to. W2
    /// settled this for imbib — a folder's records ARE its provenance tag,
    /// `watched/<folder name>` — and W3 reuses the answer rather than minting a
    /// second membership truth: no per-folder collection, no new store concept,
    /// and a list the user can already inspect, remove from and re-apply.
    case tag(String)

    var statusString: String? {
        if case .status(let s) = self { return s.rawValue }
        return nil
    }

    /// The tag this scope filters on, if any.
    var tagPath: String? {
        if case .tag(let path) = self { return path }
        return nil
    }
    var folderID: UUID? {
        if case .folder(let id) = self { return id }
        return nil
    }
    /// PUBLIC since ADR-0022 D9: a shell outside PMC labels its list column
    /// with it. impress-iOS is the first host to route more than one kind, so
    /// "the sidebar node knows the name, pass it down" (impart's single-kind
    /// answer) stops scaling — a scope that can name itself should say so.
    public var title: String {
        switch self {
        case .all: return "All Manuscripts"
        case .status(let s): return s.displayName
        case .folder: return "Folder"
        case .flagged(let color):
            return color.map { "\($0.displayName) Flag" } ?? "Flagged"
        // The leaf, not the whole path: the column header sits under a sidebar
        // row that already says which folder this is.
        case .tag(let path): return path.split(separator: "/").last.map(String.init) ?? path
        }
    }
}

/// What subset of figures the list shows.
public enum FigureListScope: Hashable, Sendable {
    case all
    case unfiled
    case folder(UUID)
    case flagged(FlagColor?)
    /// Every figure carrying one tag path. See `RecordSidebarScope.tag`.
    case tag(String)

    var folderID: UUID? {
        if case .folder(let id) = self { return id }
        return nil
    }
    /// The tag this scope filters on, if any.
    var tagPath: String? {
        if case .tag(let path) = self { return path }
        return nil
    }
    /// PUBLIC since ADR-0022 D9: a shell outside PMC labels its list column
    /// with it. impress-iOS is the first host to route more than one kind, so
    /// "the sidebar node knows the name, pass it down" (impart's single-kind
    /// answer) stops scaling — a scope that can name itself should say so.
    public var title: String {
        switch self {
        case .all: return "All Figures"
        case .unfiled: return "Unfiled"
        case .folder: return "Folder"
        case .flagged(let color):
            return color.map { "\($0.displayName) Flag" } ?? "Flagged"
        // The leaf, not the whole path — the sidebar row above already says
        // which branch of the tag tree this is (same rule as manuscripts).
        case .tag(let path): return path.split(separator: "/").last.map(String.init) ?? path
        }
    }
}

/// What subset of mail the list shows.
public enum MessageListScope: Hashable, Sendable {
    /// Union of every account's inbox-role folder.
    case allInboxes
    /// One account — v1 keeps it simple: the account's inbox folder.
    case account(UUID)
    /// One mail folder (envelope parentId filter).
    case folder(UUID)
    case flagged(FlagColor?)
    /// Every message carrying one tag path. See `RecordSidebarScope.tag`.
    ///
    /// Tags are the one organising verb mail HAS: IMAP owns mailboxes, so
    /// `.folder` is read-only and `MessageListWrapper` offers no move. A tag is
    /// stored on OUR side of the boundary, which makes this the first way a
    /// user can group mail across accounts without touching the server.
    case tag(String)

    /// The tag this scope filters on, if any.
    var tagPath: String? {
        if case .tag(let path) = self { return path }
        return nil
    }

    /// PUBLIC since ADR-0022 D9: a shell outside PMC labels its list column
    /// with it. impress-iOS is the first host to route more than one kind, so
    /// "the sidebar node knows the name, pass it down" (impart's single-kind
    /// answer) stops scaling — a scope that can name itself should say so.
    public var title: String {
        switch self {
        case .allInboxes: return "All Inboxes"
        case .account: return "Account"
        case .folder: return "Folder"
        case .flagged(let color):
            return color.map { "\($0.displayName) Flag" } ?? "Flagged"
        case .tag(let path): return path.split(separator: "/").last.map(String.init) ?? path
        }
    }
}

/// What subset of agent records the list shows.
public enum AgentListScope: Hashable, Sendable {
    /// All `task@1.0.0` rows, newest-modified first.
    case tasks
    /// All `agent-run@1.0.0` rows, newest first.
    case runs
    /// Tasks in one kernel lifecycle state (raw payload `state` value).
    case tasksByState(String)
    /// Flagged tasks; nil colour = any flag.
    ///
    /// A flag is the user's OWN mark, which is why this is not the kernel
    /// overreach it looks like. The kernel owns a task's `state` — that moves
    /// only through `TaskStoreApi.transition` — but the envelope's
    /// `flag_color` is nobody's but the researcher's, and `TriageMenu` has
    /// offered Star/Flag/Tags on task rows since Stage 2-C. Until now there
    /// was no scope to browse the result back.
    case flagged(FlagColor?)
    /// Tasks carrying one tag path. See `RecordSidebarScope.tag`.
    case tag(String)

    /// The tag this scope filters on, if any.
    var tagPath: String? {
        if case .tag(let path) = self { return path }
        return nil
    }

    /// PUBLIC since ADR-0022 D9: a shell outside PMC labels its list column
    /// with it. impress-iOS is the first host to route more than one kind, so
    /// "the sidebar node knows the name, pass it down" (impart's single-kind
    /// answer) stops scaling — a scope that can name itself should say so.
    public var title: String {
        switch self {
        case .tasks: return "Tasks"
        case .runs: return "Runs"
        case .tasksByState(let state):
            return AgentStoreReader.stateDisplayName(state)
        case .flagged(let color):
            return color.map { "\($0.displayName) Flag" } ?? "Flagged"
        case .tag(let path): return path.split(separator: "/").last.map(String.init) ?? path
        }
    }

    /// Whether this scope lists agent-run rows (else task rows).
    var isRunScope: Bool {
        if case .runs = self { return true }
        return false
    }

    /// The descriptor whose triage capabilities gate this scope's grammar.
    var descriptor: RecordKindDescriptor {
        isRunScope ? AgentRunRecordKind.descriptor : TaskRecordKind.descriptor
    }
}

// MARK: - RecordScopeKey conformances

extension ManuscriptListScope: RecordScopeKey {
    public var scopeKey: String {
        switch self {
        case .all: return "manuscripts-all"
        case .status(let s): return "manuscripts-status-\(s.rawValue)"
        case .folder(let id): return "manuscripts-folder-\(id.uuidString)"
        case .flagged(let color): return "manuscripts-flagged-\(color?.rawValue ?? "any")"
        case .tag(let path): return "manuscripts-tag-\(path)"
        }
    }

    public var stableViewID: UUID {
        UUID.deterministic(from: scopeKey)
    }
}

extension FigureListScope: RecordScopeKey {
    public var scopeKey: String {
        switch self {
        case .all: return "figures-all"
        case .unfiled: return "figures-unfiled"
        case .folder(let id): return "figures-folder-\(id.uuidString)"
        case .flagged(let color): return "figures-flagged-\(color?.rawValue ?? "any")"
        case .tag(let path): return "figures-tag-\(path)"
        }
    }

    public var stableViewID: UUID {
        UUID.deterministic(from: scopeKey)
    }
}

extension MessageListScope: RecordScopeKey {
    public var scopeKey: String {
        switch self {
        case .allInboxes: return "messages-all-inboxes"
        case .account(let id): return "messages-account-\(id.uuidString)"
        case .folder(let id): return "messages-folder-\(id.uuidString)"
        case .flagged(let color): return "messages-flagged-\(color?.rawValue ?? "any")"
        case .tag(let path): return "messages-tag-\(path)"
        }
    }

    public var stableViewID: UUID {
        UUID.deterministic(from: scopeKey)
    }
}

extension AgentListScope: RecordScopeKey {
    public var scopeKey: String {
        switch self {
        case .tasks: return "agents-tasks"
        case .runs: return "agents-runs"
        case .tasksByState(let state): return "agents-tasks-state-\(state)"
        case .flagged(let color): return "agents-flagged-\(color?.rawValue ?? "any")"
        case .tag(let path): return "agents-tag-\(path)"
        }
    }

    public var stableViewID: UUID {
        UUID.deterministic(from: scopeKey)
    }
}

// MARK: - RecordRouteScope conformances (Stage 3)
//
// The hinge between the ONE generic `RecordRoute` and the four PARALLEL list
// scopes ADR-0021 D2 deliberately keeps per kind. Each conformance is the
// kind's own code, sitting next to the kind's own scope: a new record kind
// writes one of these with its scope and the chassis sink
// (`SectionContentView.recordSection`) learns nothing.
//
// Each rejects a scope that names a DIFFERENT kind, which is what keeps
// `RecordSectionContext.scope(as:)` honest — a factory handed someone else's
// scope still gets nil, exactly as it did when the scope crossed the boundary
// type-erased.

extension ManuscriptListScope: RecordRouteScope {
    public init?(routeScope: RecordSidebarScope) {
        switch routeScope {
        case .all(.manuscript):
            self = .all
        case .status(.manuscript, let raw):
            // The sidebar only ever builds these from declared StatusSpecs, so
            // an unparseable value means a hand-edited store row or a newer
            // build — honest nil (empty state) rather than a silent `.all`.
            guard let status = JournalManuscriptStatus(rawValue: raw) else { return nil }
            self = .status(status)
        case .folder(.manuscript, let id):
            self = .folder(id)
        case .flagged(.manuscript, let raw):
            // `flatMap` matches the legacy conversion in SectionContentView:
            // an unknown colour degrades to "any flag", never to no rows.
            self = .flagged(raw.flatMap { FlagColor(rawValue: $0) })
        case .tag(.manuscript, let path):
            // The GENERIC tag row. W3's watched-folder rows keep arriving as
            // `.host` below and resolve to the same `.tag` scope — one list
            // scope, two routes, because a watched folder's tag is discovered
            // from its coordinator while a tag-tree row already knows its path.
            self = .tag(path)
        case .host(.manuscript, let key):
            // ADR-0023 W3 — a watched manuscript folder's row. The route
            // carries the folder's ID; the tag's leaf is its DISPLAY NAME, and
            // the coordinator is the only thing that knows the mapping (the
            // name is an identity, uniquified at add time — see
            // `WatchedFolderIngestCoordinator.uniqueDisplayName`). A folder
            // whose coordinator is not running yields nil, which renders the
            // "viewer unavailable" state rather than an empty list that reads
            // as "this folder found nothing".
            //
            // W4 note: this initializer is NONISOLATED (the `RecordRouteScope`
            // requirement is), and the coordinator is `@MainActor`, so the
            // mapping is read from the coordinator's published snapshot rather
            // than off `rows` — see `provenanceTagPath(ofFolder:kindScope:)`
            // for why publishing beats hopping, blocking or assuming isolation
            // here.
            guard case .folder(let folderID)? = WatchedFolderRoute(key: key),
                let tagPath = WatchedFolderIngestCoordinator.provenanceTagPath(
                    ofFolder: folderID, kindScope: RecordKindID.manuscript.rawValue)
            else { return nil }
            self = .tag(tagPath)
        default:
            return nil
        }
    }
}

public extension FigureListScope {
    /// Chassis spelling of the "Unfiled" row. `RecordSidebarScope` has no
    /// `unfiled` case — "records in no folder" is not one of the subsets EVERY
    /// kind can be sliced by — so it rides the declared host escape hatch,
    /// with the key single-sourced here.
    static let unfiledRouteScope = RecordSidebarScope.host(.figure, key: "figures.unfiled")
}

extension FigureListScope: RecordRouteScope {
    public init?(routeScope: RecordSidebarScope) {
        switch routeScope {
        case .all(.figure):
            self = .all
        case Self.unfiledRouteScope:
            self = .unfiled
        case .folder(.figure, let id):
            self = .folder(id)
        case .flagged(.figure, let raw):
            self = .flagged(raw.flatMap { FlagColor(rawValue: $0) })
        case .tag(.figure, let path):
            self = .tag(path)
        default:
            return nil
        }
    }
}

public extension MessageListScope {
    /// Chassis spelling of a mail ACCOUNT row. Accounts own folders rather
    /// than records, so `.folder` would be the wrong word (and selecting one
    /// resolves to the account's inbox-role folder, not to its own members) —
    /// host escape hatch, key single-sourced here in both directions.
    static func accountRouteScope(_ accountID: UUID) -> RecordSidebarScope {
        .host(.message, key: "mail.account.\(accountID.uuidString.lowercased())")
    }

    private static let accountKeyPrefix = "mail.account."

    static func accountID(fromRouteScope scope: RecordSidebarScope) -> UUID? {
        guard case .host(.some(.message), let key) = scope,
              key.hasPrefix(accountKeyPrefix) else { return nil }
        return UUID(uuidString: String(key.dropFirst(accountKeyPrefix.count)))
    }
}

extension MessageListScope: RecordRouteScope {
    public init?(routeScope: RecordSidebarScope) {
        if let accountID = Self.accountID(fromRouteScope: routeScope) {
            self = .account(accountID)
            return
        }
        switch routeScope {
        case .all(.message):
            self = .allInboxes
        case .folder(.message, let id):
            self = .folder(id)
        case .flagged(.message, let raw):
            self = .flagged(raw.flatMap { FlagColor(rawValue: $0) })
        case .tag(.message, let path):
            self = .tag(path)
        default:
            return nil
        }
    }
}

extension AgentListScope: RecordRouteScope {
    /// Tasks and runs are two KINDS sharing one section view, so the kind —
    /// not a scope case — decides which schema the list reads. This is why
    /// `RecordRoute` carries the kind explicitly.
    public init?(routeScope: RecordSidebarScope) {
        switch routeScope {
        case .all(.agentRun):
            self = .runs
        case .all(.task):
            self = .tasks
        case .status(.task, let state):
            self = .tasksByState(state)
        // Flag and tag rows bind `.task`, never `.agentRun`: a run is immutable
        // provenance (matrix row `agentRunsAll`), so there is no user mark on it
        // to browse back. `isRunScope` stays false for both, which is what keeps
        // `descriptor` resolving to the TASK descriptor for their grammar.
        case .flagged(.task, let raw):
            self = .flagged(raw.flatMap { FlagColor(rawValue: $0) })
        case .tag(.task, let path):
            self = .tag(path)
        default:
            return nil
        }
    }
}

// MARK: - Publication route scope (I2)
//
// The FIFTH conformance, and the one that was missing when ADR-0022 D9 wrote
// that impress-iOS could not present `.publication`. The pane was the loud
// half of that gap; this is the quiet half — with no
// `PublicationSource.init?(routeScope:)`, a host handed a publication-bound
// sidebar selection had nothing to turn it into, so every publication section
// would have selected into a scope no list could name.
//
// The four host-key spellings below are imbib-iOS's, verbatim
// (`ImbibSidebarRoute.key`). They are published HERE for the same reason
// `MessageListScope.accountRouteScope` and `FigureListScope.unfiledRouteScope`
// are published beside their scopes: the key space belongs to the host, but
// once a SECOND host needs the same rows, a key spelled twice is a key that
// can differ. imbib keeps its own enum — it carries routes the chassis has no
// scope for (search forms, `contentOnly`) — and the two agree by these
// constructors being the definition.

public extension PublicationSource {

    /// Chassis spelling of a LIBRARY row. Libraries sit above the collection
    /// tree (each owns its own), so `.folder` would be the wrong word and the
    /// organise verbs must not attach to them — host escape hatch.
    static func libraryRouteScope(_ id: UUID) -> RecordSidebarScope {
        .host(.publication, key: "library.\(id.uuidString.lowercased())")
    }

    /// Chassis spelling of a SMART SEARCH / feed row: a stored query rather
    /// than a stored membership.
    static func feedRouteScope(_ id: UUID) -> RecordSidebarScope {
        .host(.publication, key: "feed.\(id.uuidString.lowercased())")
    }

    /// Chassis spelling of a SciX (remote) shelf row.
    static func scixRouteScope(_ id: UUID) -> RecordSidebarScope {
        .host(.publication, key: "scix.\(id.uuidString.lowercased())")
    }

    /// Chassis spelling of the "Recent" row — papers the user viewed or added
    /// by hand, which is an activity stamp rather than a subset of any kind.
    static let recentRouteScope = RecordSidebarScope.host(.publication, key: "recent")

    private static func hostID(_ scope: RecordSidebarScope, prefix: String) -> UUID? {
        guard case .host(.some(.publication), let key) = scope,
              key.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(key.dropFirst(prefix.count)))
    }
}

extension PublicationSource: RecordRouteScope {
    public init?(routeScope: RecordSidebarScope) {
        if let id = Self.hostID(routeScope, prefix: "library.") { self = .library(id); return }
        if let id = Self.hostID(routeScope, prefix: "feed.") { self = .smartSearch(id); return }
        if let id = Self.hostID(routeScope, prefix: "scix.") { self = .scixLibrary(id); return }
        if routeScope == Self.recentRouteScope { self = .recent; return }

        switch routeScope {
        // Every collection — inbox, library or exploration — is ONE route, the
        // mapping imbib's `section(for:)` already makes.
        case .folder(.publication, let id):
            self = .collection(id)
        case .flagged(.publication, let raw):
            // `flatMap` matches every other conformance: an unknown colour
            // degrades to "any flag", never to no rows.
            self = .flagged(raw.flatMap { FlagColor(rawValue: $0)?.rawValue })
        case .tag(.publication, let path):
            // `PublicationSource.tag` has existed and been Rust-backed since
            // ADR-0023 W2 — the watched-folder rows are its only constructor
            // today. This is the generic route onto the same scope, so imbib's
            // tag tree and a watched folder land on one list path.
            self = .tag(path)
        case .section(.citedInManuscripts, _):
            self = .citedInManuscripts
        case .section(.dismissed, _):
            self = .dismissed
        // `.section(.inbox, _)` is deliberately NOT here. `.inbox` carries the
        // inbox LIBRARY's id, which is a store read (`getInboxLibrary()`) and
        // therefore `@MainActor`; this initialiser is not, and making it so
        // would put a database call inside a scope conversion that runs in
        // every sidebar rebuild. Hosts that show an Inbox resolve it once,
        // beside the read they already do for its badge count.
        //
        // The publication descriptor declares NO status lifecycle
        // (`statuses: []`, `dismissal: .libraryMove`), so the builder never
        // emits `.status(.publication, _)` and `.all(.publication)` has no
        // library to be "all" of — imbib's Libraries section is a tree of
        // LIBRARIES, not one "All Publications" row. Both are honest nils.
        default:
            return nil
        }
    }
}
