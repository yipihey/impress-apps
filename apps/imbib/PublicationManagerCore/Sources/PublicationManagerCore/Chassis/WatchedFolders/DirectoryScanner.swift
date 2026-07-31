// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). Foundation only: no
// AppKit, no Spotlight, no FSEvents. This is the engine half that works
// everywhere, which is why the fallback is built on it.
//
//  DirectoryScanner.swift
//  PublicationManagerCore
//
//  ADR-0023 D6/D7 — the bounded manual walk.
//
//  Two jobs, and they are deliberately the same code:
//
//  1. The FALLBACK engine's enumeration, when Spotlight cannot see a volume.
//  2. The PROBE that proves Spotlight cannot see it (`FolderWalkBounds.probe`
//     — depth 2, 64 files, stop at the first hit). See
//     `SpotlightAvailabilityProbe`: "the query returned nothing" is not a
//     signal, "the query returned nothing AND the directory demonstrably
//     contains matches" is.
//
//  `FileManager.enumerator(at:)` is deliberately not used. It offers
//  `.skipsSubdirectoryDescendants` (depth 0) or unbounded recursion, with
//  nothing in between, and a watched folder can be a home directory — the
//  unbounded walk is the ingest burst ADR-0023's risk register warns about. So
//  the descent is explicit, level by level, and stops when it is told to.
//

import Foundation

/// The outcome of one walk. `hitLimit` is the honest half: a truncated
/// enumeration must be visible, because a count derived from it is a floor and
/// not a total.
public struct DirectoryScanResult: Sendable, Equatable {

    /// Matches, in `DiscoveryBatcher.ordered` order.
    public let files: [DiscoveredFile]

    /// True when `maxFiles` or `maxDepth` cut the walk short — i.e. there may
    /// be more matches than `files` contains.
    public let hitLimit: Bool

    /// Directories opened. Useful in a log line and in a test that wants to
    /// assert the depth bound actually bit.
    public let directoriesVisited: Int

    /// Directories the walk could not open (permissions, a disconnected
    /// mount). Non-empty means the count is incomplete for a reason that is
    /// not the bounds.
    public let unreadableDirectories: [URL]

    public init(
        files: [DiscoveredFile], hitLimit: Bool, directoriesVisited: Int,
        unreadableDirectories: [URL] = []
    ) {
        self.files = files
        self.hitLimit = hitLimit
        self.directoriesVisited = directoriesVisited
        self.unreadableDirectories = unreadableDirectories
    }

    public static let empty = DirectoryScanResult(
        files: [], hitLimit: false, directoriesVisited: 0)

    /// Whether this result can back a badge. A truncated or partly unreadable
    /// walk cannot — same rule as `WatchedFolderState.countIsTrustworthy`, one
    /// level down.
    public var isComplete: Bool { !hitLimit && unreadableDirectories.isEmpty }
}

/// The bounded recursive walk.
///
/// Deliberately `nonisolated` free functions over `Sendable` inputs: a walk of
/// a large tree must be runnable off the main actor (`Task.detached`), and a
/// type with state would invite someone to cache it there.
public enum DirectoryScanner {

    /// Every file under `directory` that some filter claims, within `bounds`.
    ///
    /// Ordering is `DiscoveryBatcher.ordered`'s, so two runs over an unchanged
    /// tree produce byte-identical output and the diff between runs is real
    /// change rather than enumeration order.
    public static func scan(
        directory: URL,
        filters: [FileDiscoveryFilter],
        bounds: FolderWalkBounds = .default,
        fileManager: FileManager = .default
    ) -> DirectoryScanResult {
        guard filters.canMatchAnything, bounds.maxFiles > 0 else { return .empty }

        var found: [DiscoveredFile] = []
        var unreadable: [URL] = []
        var visited = 0
        var hitLimit = false

        // Explicit level-by-level descent (see the file header on why
        // `FileManager.enumerator` is not used). `frontier` holds this level;
        // `next` accumulates the level below.
        var frontier: [URL] = [directory.standardizedFileURL]
        var depth = 0

        while !frontier.isEmpty {
            var next: [URL] = []

            for parent in frontier {
                visited += 1

                let entries: [URL]
                do {
                    entries = try fileManager.contentsOfDirectory(
                        at: parent,
                        includingPropertiesForKeys: [
                            .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey,
                            .fileSizeKey, .isHiddenKey,
                        ],
                        options: bounds.includesHiddenDirectories ? [] : [.skipsHiddenFiles])
                } catch {
                    unreadable.append(parent)
                    continue
                }

                for entry in entries {
                    let values = try? entry.resourceValues(forKeys: [
                        .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey,
                        .fileSizeKey,
                    ])

                    if values?.isDirectory == true {
                        // Symlinked directories are not followed:
                        // `contentsOfDirectory` returns the link itself and
                        // `isDirectory` on a link to a directory is true, so a
                        // self-referential link would otherwise loop until the
                        // depth bound saved us. Cheaper and clearer to refuse.
                        if depth < bounds.maxDepth,
                           (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                               .isSymbolicLink != true {
                            next.append(entry)
                        } else if depth >= bounds.maxDepth {
                            hitLimit = true
                        }
                        continue
                    }

                    guard let filter = filters.firstMatching(entry) else { continue }

                    guard found.count < bounds.maxFiles else {
                        hitLimit = true
                        return DirectoryScanResult(
                            files: DiscoveryBatcher.ordered(found),
                            hitLimit: true,
                            directoriesVisited: visited,
                            unreadableDirectories: unreadable)
                    }

                    found.append(DiscoveredFile(
                        url: entry,
                        filterID: filter.id,
                        modificationDate: values?.contentModificationDate,
                        byteSize: values?.fileSize.map(Int64.init)))
                }
            }

            frontier = next
            depth += 1
        }

        return DirectoryScanResult(
            files: DiscoveryBatcher.ordered(found),
            hitLimit: hitLimit,
            directoriesVisited: visited,
            unreadableDirectories: unreadable)
    }

    /// "Does this directory demonstrably contain something a filter claims?"
    ///
    /// The counterexample half of D6's degraded-state detection. Bounded hard
    /// (`FolderWalkBounds.probe`) and short-circuiting at `stopAfter` matches,
    /// because it runs while a Spotlight query is already in flight and its job
    /// is to answer yes/no, not to enumerate.
    ///
    /// Returns the number of matches actually seen (≤ `stopAfter`). Zero means
    /// "we could not prove there is anything here", which is NOT the same as
    /// "there is nothing here" — and the resolver treats it that way.
    public static func probeForMatches(
        directory: URL,
        filters: [FileDiscoveryFilter],
        bounds: FolderWalkBounds = .probe,
        stopAfter: Int = 1,
        fileManager: FileManager = .default
    ) -> Int {
        guard filters.canMatchAnything, stopAfter > 0 else { return 0 }

        var seen = 0
        var frontier: [URL] = [directory.standardizedFileURL]
        var depth = 0

        while !frontier.isEmpty, depth <= bounds.maxDepth {
            var next: [URL] = []
            for parent in frontier {
                guard let entries = try? fileManager.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: bounds.includesHiddenDirectories ? [] : [.skipsHiddenFiles])
                else { continue }

                for entry in entries {
                    if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                        .isDirectory == true {
                        if depth < bounds.maxDepth { next.append(entry) }
                        continue
                    }
                    if filters.firstMatching(entry) != nil {
                        seen += 1
                        if seen >= stopAfter { return seen }
                    }
                }
            }
            frontier = next
            depth += 1
        }
        return seen
    }

    /// Whether `url` is a readable directory. The pre-flight every engine runs
    /// so `notADirectory` is reported as itself rather than as "0 files".
    public static func isReadableDirectory(
        _ url: URL, fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return fileManager.isReadableFile(atPath: url.path)
    }
}

// MARK: - Diffing

/// The change between two discovered sets — what the fallback engine publishes
/// after a re-walk, and what a Spotlight `.NSMetadataQueryDidUpdate` is
/// reduced to so both engines speak one vocabulary.
public struct DiscoveryDiff: Sendable, Equatable {
    public let added: [DiscoveredFile]
    public let removed: [URL]

    /// Files present before AND after whose on-disk metadata moved.
    ///
    /// **Added in W2, and the reason is a hole W1 could not see from where it
    /// stood.** The diff was a pure URL set difference, with a comment
    /// explaining that a touched file is not an *add* — which is right, and is
    /// why these are a third bucket rather than more `added`. But a URL-only
    /// diff means EDITING a watched `.bib` produces no event at all: the file
    /// was there before and is there now, so nothing is published, so
    /// `import_discovered` never sees it, so the entry the user just added to
    /// their bibliography never arrives. The live-update half of the feature
    /// was unreachable.
    ///
    /// Publishing these is safe precisely because of the layer W1's comment
    /// pointed at: `import_discovered` is hash-keyed, so a file whose bytes did
    /// NOT actually move answers `unchanged` and writes nothing. Metadata is
    /// therefore allowed to be a coarse over-approximation — mtime granularity,
    /// a same-size edit, a touch — and the cost of a false positive is one
    /// hash, not a duplicate import.
    public let changed: [DiscoveredFile]

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

    public init(added: [DiscoveredFile], removed: [URL], changed: [DiscoveredFile] = []) {
        self.added = added
        self.removed = removed
        self.changed = changed
    }

    /// Set difference by URL for membership, metadata comparison for content.
    ///
    /// A file whose mtime or size moved is `changed`, never `added` — a
    /// consumer that counts adds (the feed badge) must not count an edit as a
    /// new file, and a consumer that ingests (`import_discovered`) must see it
    /// either way.
    public static func between(
        old: [DiscoveredFile], new: [DiscoveredFile]
    ) -> DiscoveryDiff {
        let oldByURL = Dictionary(old.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let newURLs = Set(new.map(\.url))
        let added = DiscoveryBatcher.ordered(new.filter { oldByURL[$0.url] == nil })
        let removed = old
            .filter { !newURLs.contains($0.url) }
            .map(\.url)
            .sorted { $0.path.caseInsensitiveCompare($1.path) == .orderedAscending }
        let changed = DiscoveryBatcher.ordered(
            new.filter { candidate in
                guard let previous = oldByURL[candidate.url] else { return false }
                return previous.modificationDate != candidate.modificationDate
                    || previous.byteSize != candidate.byteSize
            })
        return DiscoveryDiff(added: added, removed: removed, changed: changed)
    }
}
