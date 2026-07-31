// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). The `.withSecurityScope`
// option set is the only thing that differs by platform, and it differs as an
// `#if` ISLAND inside one function (the `ManuscriptImporter` precedent), not as
// a gate on the file: iOS hosts persist folder bookmarks too, they just resolve
// them without security scope.
//
//  WatchedFolderBookmarkStore.swift
//  PublicationManagerCore
//
//  ADR-0023 D6 — "Security-scoped bookmarks persist directory access across
//  launches."
//
//  ── Shape ───────────────────────────────────────────────────────────────────
//
//  `public actor` + injected `UserDefaults` + in-memory cache + `keyPrefix`,
//  which is `ReadingPositionStore`/`ListViewStateStore`'s shape and the one
//  every testable store in PMC uses. `.forCurrentEnvironment` (never
//  `.standard`) is the house default: it hands each xctest worker process its
//  own suite, so parallel tests do not clobber each other through CFPreferences.
//
//  ── Why the URL work is behind a broker ─────────────────────────────────────
//
//  Minting a security-scoped bookmark requires a URL the user granted through a
//  panel. `swift test` has no panel and no sandbox, so a store that called
//  `url.bookmarkData(options: .withSecurityScope)` inline would have exactly one
//  testable half — encode/decode — and the branch that actually matters (resolve
//  → stale → renew → re-persist) would be provable only by launching an app.
//  That branch is the one D6 is about.
//
//  So the three URL operations are a struct of closures
//  (`SecurityScopedBookmarkBroker`), `\.live` is the real `URL` API verbatim,
//  and `.scratch()` is a deterministic stand-in that can be told to report a
//  bookmark stale on the next resolve. This is `SidebarPersistenceScope`'s trick
//  applied one layer down, and it is why `testStaleBookmarkIsRenewedAndRePersisted`
//  exists at all.
//
//  NOTE — nothing in this file ever touches a real user directory. The
//  production broker is handed URLs by the host; the tests use temp dirs.
//

import Foundation
import OSLog

// MARK: - Persisted record

/// What survives a launch for one watched folder.
///
/// `filterIDs` and not `[FileDiscoveryFilter]`: the filters are DERIVED from
/// record-kind declarations (ADR-0023 D1), and persisting a derived value is
/// how a stale copy of a declaration outlives the declaration. On relaunch the
/// host re-derives the filters and matches them to a folder by id — so a kind
/// that gains an extension gains it on every already-watched folder, with no
/// migration. That is the W2 seam; see `FileDiscoveryFilter`'s header.
public struct WatchedFolderBookmark: Codable, Equatable, Sendable, Identifiable {

    public let id: WatchedFolderID

    /// The security-scoped bookmark blob.
    public var bookmark: Data

    /// The path as of the last successful resolve.
    ///
    /// Redundant with the bookmark and kept anyway, which is established house
    /// practice (`remarkable.localFolderPath` sits next to
    /// `remarkable.localFolderBookmark`; `ManuscriptMigrationRunner` falls back
    /// to `fileURLString`). A bookmark that will not resolve is opaque; a path
    /// lets the row say *which* folder is missing, which is the difference
    /// between an actionable message and "something went wrong".
    public var path: String

    public var displayName: String

    /// `FileDiscoveryFilter.id` values this folder was watched for.
    public var filterIDs: [String]

    public var isEnabled: Bool

    public var createdAt: Date

    /// Last time the bookmark resolved to a real directory. nil = never since
    /// it was stored.
    public var lastResolvedAt: Date?

    /// Whether the last resolve reported the bookmark stale. Persisted so a row
    /// can render `inaccessible(bookmarkStale: true)` on launch before anything
    /// has been re-resolved.
    public var wasStaleOnLastResolve: Bool

    public init(
        id: WatchedFolderID,
        bookmark: Data,
        path: String,
        displayName: String,
        filterIDs: [String],
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        lastResolvedAt: Date? = nil,
        wasStaleOnLastResolve: Bool = false
    ) {
        self.id = id
        self.bookmark = bookmark
        self.path = path
        self.displayName = displayName
        self.filterIDs = filterIDs
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastResolvedAt = lastResolvedAt
        self.wasStaleOnLastResolve = wasStaleOnLastResolve
    }
}

// MARK: - The URL half, behind a seam

/// A resolved bookmark: where it points, and whether the blob needs rewriting.
public struct ResolvedBookmark: Sendable, Equatable {
    public let url: URL
    public let isStale: Bool

    public init(url: URL, isStale: Bool) {
        self.url = url.standardizedFileURL
        self.isStale = isStale
    }
}

/// The three `URL` operations a bookmark needs, as closures.
///
/// See the file header for why this is a seam and not four inline calls.
public struct SecurityScopedBookmarkBroker: Sendable {

    public var makeBookmark: @Sendable (URL) throws -> Data
    public var resolve: @Sendable (Data) throws -> ResolvedBookmark
    public var beginAccess: @Sendable (URL) -> Bool
    public var endAccess: @Sendable (URL) -> Void

    public init(
        makeBookmark: @escaping @Sendable (URL) throws -> Data,
        resolve: @escaping @Sendable (Data) throws -> ResolvedBookmark,
        beginAccess: @escaping @Sendable (URL) -> Bool,
        endAccess: @escaping @Sendable (URL) -> Void
    ) {
        self.makeBookmark = makeBookmark
        self.resolve = resolve
        self.beginAccess = beginAccess
        self.endAccess = endAccess
    }

    /// The real `URL` API, verbatim.
    ///
    /// `.withSecurityScope` is macOS-only — passing it on iOS throws — so the
    /// option set is chosen by an `#if` island, exactly as
    /// `ManuscriptImporter.bookmarkBase64(for:)` and
    /// `ManuscriptMigrationRunner` already do.
    public static let live = SecurityScopedBookmarkBroker(
        makeBookmark: { url in
            #if os(macOS)
            try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
            #else
            try url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            #endif
        },
        resolve: { data in
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale)
            return ResolvedBookmark(url: url, isStale: isStale)
        },
        beginAccess: { url in
            #if os(macOS)
            url.startAccessingSecurityScopedResource()
            #else
            url.startAccessingSecurityScopedResource()
            #endif
        },
        endAccess: { url in
            url.stopAccessingSecurityScopedResource()
        })

    /// A deterministic stand-in.
    ///
    /// The bookmark blob is the URL's own path, UTF-8. `staleURLs` names the
    /// paths whose FIRST resolve reports `isStale == true`; a re-mint that
    /// happens after that resolve clears it. That sequence — resolve reports
    /// stale, caller re-mints, next resolve is clean — is precisely the
    /// renewal contract `resolveURL` implements, so a test can drive it end to
    /// end with no sandbox and no panel.
    public static func scratch(
        staleURLs: Set<URL> = [],
        accessGranted: Bool = true
    ) -> SecurityScopedBookmarkBroker {
        let stalePaths = Set(staleURLs.map(\.standardizedFileURL.path))
        /// `resolved`: paths a resolve has been attempted for.
        /// `renewed`: paths re-minted AFTER such a resolve.
        /// Both are needed — the mint that `register` performs before anything
        /// has resolved must not count as a renewal, or the stale branch would
        /// never be reachable.
        let state = MutableBox<(resolved: Set<String>, renewed: Set<String>)>(([], []))
        return SecurityScopedBookmarkBroker(
            makeBookmark: { url in
                let path = url.standardizedFileURL.path
                state.withValue { value in
                    if value.resolved.contains(path) { value.renewed.insert(path) }
                }
                return Data(path.utf8)
            },
            resolve: { data in
                guard let path = String(data: data, encoding: .utf8), !path.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let stale = state.withValue { value -> Bool in
                    let isStale = stalePaths.contains(path) && !value.renewed.contains(path)
                    value.resolved.insert(path)
                    return isStale
                }
                return ResolvedBookmark(url: URL(fileURLWithPath: path), isStale: stale)
            },
            beginAccess: { _ in accessGranted },
            endAccess: { _ in })
    }
}

/// Minimal `Sendable` mutable cell for the scratch broker's closures. Not a
/// general utility — deliberately `internal` and deliberately tiny.
final class MutableBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Store

/// Persists one `WatchedFolderBookmark` per watched folder.
public actor WatchedFolderBookmarkStore {

    public static let shared = WatchedFolderBookmarkStore(
        userDefaults: .forCurrentEnvironment)

    private let userDefaults: UserDefaults
    private let broker: SecurityScopedBookmarkBroker
    private let keyPrefix = "watched_folder_bookmark_"
    private var cache: [WatchedFolderID: WatchedFolderBookmark] = [:]

    public init(
        userDefaults: UserDefaults = .forCurrentEnvironment,
        broker: SecurityScopedBookmarkBroker = .live
    ) {
        self.userDefaults = userDefaults
        self.broker = broker
    }

    private func key(_ id: WatchedFolderID) -> String { keyPrefix + id.storageKey }

    // MARK: Reading

    public func bookmark(for id: WatchedFolderID) -> WatchedFolderBookmark? {
        if let cached = cache[id] { return cached }
        guard let data = userDefaults.data(forKey: key(id)),
              let decoded = try? JSONDecoder().decode(WatchedFolderBookmark.self, from: data)
        else { return nil }
        cache[id] = decoded
        return decoded
    }

    /// Every persisted folder, ordered by `createdAt` then name so the sidebar
    /// order is stable across launches (a `UserDefaults` key sweep is not).
    public func all() -> [WatchedFolderBookmark] {
        let keys = userDefaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(keyPrefix) }
        var out: [WatchedFolderBookmark] = []
        for key in keys {
            guard let data = userDefaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode(WatchedFolderBookmark.self, from: data)
            else { continue }
            cache[decoded.id] = decoded
            out.append(decoded)
        }
        return out.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }

    // MARK: Writing

    public func save(_ record: WatchedFolderBookmark) {
        cache[record.id] = record
        guard let data = try? JSONEncoder().encode(record) else {
            Logger.files.warningCapture(
                "watched folder \(record.id.storageKey): bookmark record failed to encode",
                category: "watched-folders")
            return
        }
        userDefaults.set(data, forKey: key(record.id))
        // Three-point trace, point 2 (save). Point 1 is `register`, point 3 is
        // `resolveURL`'s "resolved" line.
        Logger.files.infoCapture(
            "watched folder \(record.id.storageKey): saved bookmark "
                + "(\(record.bookmark.count) bytes, path=\(record.path))",
            category: "watched-folders")
    }

    public func remove(_ id: WatchedFolderID) {
        cache.removeValue(forKey: id)
        userDefaults.removeObject(forKey: key(id))
        Logger.files.infoCapture(
            "watched folder \(id.storageKey): removed", category: "watched-folders")
    }

    /// Test/reset hatch — sweeps only this store's prefix.
    public func removeAll() {
        cache.removeAll()
        for key in userDefaults.dictionaryRepresentation().keys
        where key.hasPrefix(keyPrefix) {
            userDefaults.removeObject(forKey: key)
        }
    }

    /// Drop the in-memory cache so the next read comes from `UserDefaults`.
    public func clearCache() { cache.removeAll() }

    // MARK: The lifecycle D6 is about

    /// Mint a bookmark for a URL the user just granted, and persist it.
    ///
    /// Three-point trace, point 1 (mutation).
    @discardableResult
    public func register(
        id: WatchedFolderID = WatchedFolderID(),
        url: URL,
        displayName: String? = nil,
        filterIDs: [String],
        isEnabled: Bool = true
    ) throws -> WatchedFolderBookmark {
        let standardized = url.standardizedFileURL
        Logger.files.infoCapture(
            "watched folder \(id.storageKey): registering \(standardized.path) "
                + "for filters [\(filterIDs.joined(separator: ", "))]",
            category: "watched-folders")
        let data = try broker.makeBookmark(standardized)
        let record = WatchedFolderBookmark(
            id: id,
            bookmark: data,
            path: standardized.path,
            displayName: displayName ?? standardized.lastPathComponent,
            filterIDs: filterIDs,
            isEnabled: isEnabled)
        save(record)
        return record
    }

    /// Resolve a persisted folder to a usable URL, renewing a stale bookmark in
    /// place.
    ///
    /// The order is the one `TeXDistributionManager` established and it is not
    /// arbitrary: resolve → **if stale, re-mint and re-persist** → only then
    /// begin access. Renewing after starting access leaves the next launch with
    /// the same stale blob; starting access before renewing can fail on the
    /// very URL renewal would have fixed.
    ///
    /// Three-point trace, point 3 (display/read-back).
    public func resolveURL(for id: WatchedFolderID) -> Result<URL, FolderWatchFailure> {
        guard var record = bookmark(for: id) else {
            return .failure(.bookmarkUnresolvable(isStale: false))
        }

        let resolved: ResolvedBookmark
        do {
            resolved = try broker.resolve(record.bookmark)
        } catch {
            record.wasStaleOnLastResolve = false
            save(record)
            Logger.files.warningCapture(
                "watched folder \(id.storageKey): bookmark did not resolve "
                    + "(last path \(record.path)): \(error.localizedDescription)",
                category: "watched-folders")
            return .failure(.bookmarkUnresolvable(isStale: false))
        }

        if resolved.isStale {
            // Renew BEFORE access. A stale bookmark still resolves; what it
            // does not do is survive another launch.
            if let renewedData = try? broker.makeBookmark(resolved.url) {
                record.bookmark = renewedData
                record.wasStaleOnLastResolve = false
                Logger.files.infoCapture(
                    "watched folder \(id.storageKey): bookmark was stale, renewed "
                        + "(\(renewedData.count) bytes)",
                    category: "watched-folders")
            } else {
                record.wasStaleOnLastResolve = true
                record.path = resolved.url.path
                save(record)
                return .failure(.bookmarkUnresolvable(isStale: true))
            }
        }

        guard broker.beginAccess(resolved.url) else {
            record.path = resolved.url.path
            save(record)
            return .failure(.accessDenied(path: resolved.url.path))
        }

        record.path = resolved.url.path
        record.lastResolvedAt = Date()
        save(record)

        Logger.files.infoCapture(
            "watched folder \(id.storageKey): resolved to \(resolved.url.path) "
                + "(stale=\(resolved.isStale))",
            category: "watched-folders")
        return .success(resolved.url)
    }

    /// Release the long-lived security scope for a URL this store began access
    /// on. Callers must pair this with a successful `resolveURL`.
    public nonisolated func endAccess(_ url: URL) {
        broker.endAccess(url)
    }
}
