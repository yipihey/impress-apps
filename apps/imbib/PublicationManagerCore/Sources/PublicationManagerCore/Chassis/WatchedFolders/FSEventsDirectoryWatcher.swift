#if os(macOS)
// Chassis file — macOS-only: the FSEvents adapter, and only the adapter. The
// PROTOCOL it implements (`DirectoryChangeNotifying`), the engine that consumes
// it (`WalkFolderDiscoveryEngine`) and everything they publish are
// cross-platform. This is the `RecordViewerRegistry+Builtin.swift` shape —
// data and logic shared, the one platform API split out.
//
//  FSEventsDirectoryWatcher.swift
//  PublicationManagerCore
//
//  ADR-0023 D6 — the "FSEvents" half of "FSEvents + bounded manual walk".
//
//  ── Why FSEvents and not DispatchSource ─────────────────────────────────────
//
//  The repo already has three `DispatchSource.makeFileSystemObjectSource`
//  watchers (imprint's `VeuszPlotWatcher` and `LaTeXProjectService`, impel's
//  `EMLFolderWatcher`), and none of them is a precedent for this one:
//  `makeFileSystemObjectSource` on a directory fires for changes to its DIRECT
//  children only. A `.bib` file dropped three levels deep — the exact scenario
//  ADR-0023's opening paragraph is about — produces no event at all. impel's
//  watcher papers over the gap with a 30-second poll; a watched research
//  directory should not be polled.
//
//  FSEvents is recursive by construction, which is why the ADR names it.
//
//  ── What this deliberately does NOT do ──────────────────────────────────────
//
//  Interpret the event payload. `kFSEventStreamCreateFlagFileEvents` would give
//  per-file adds and removes, and using them would mean maintaining a second,
//  subtly different notion of "what is in this folder" alongside the walk's.
//  The engine already diffs two enumerations; all it needs from the OS is
//  "look again". So this raises a bare signal, the engine debounces it, and
//  there is exactly one place where set membership is decided.
//
//  Cleanup is in a `@unchecked Sendable` box rather than on the actor-isolated
//  class, because `deinit` cannot hop to `@MainActor` and an FSEventStream that
//  outlives its owner keeps a dispatch queue alive forever.
//

import CoreServices
import Foundation
import OSLog

/// Recursive directory-change notification, via FSEvents.
@MainActor
public final class FSEventsDirectoryWatcher: DirectoryChangeNotifying {

    public nonisolated let notifierName = "fsevents"

    /// Coalescing window handed to FSEvents itself. Small: the engine applies
    /// the real debounce (500 ms), and a large latency here would only add to
    /// it. `kFSEventStreamCreateFlagNoDefer` makes the FIRST event of a burst
    /// arrive immediately, with the latency applying to the ones behind it.
    private let latency: CFTimeInterval

    private let box = StreamBox()

    public init(latency: CFTimeInterval = 0.2) {
        self.latency = latency
    }

    deinit {
        // Not `stopWatching()`: `deinit` is nonisolated and cannot await the
        // main actor. The box owns the stream precisely so this is possible.
        box.invalidate()
    }

    @discardableResult
    public func startWatching(
        _ directory: URL, onChange: @escaping @MainActor () -> Void
    ) -> Bool {
        stopWatching()

        box.setHandler {
            // The FSEvents callback runs on `queue`; hop to the main actor
            // where the engine lives.
            Task { @MainActor in onChange() }
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<StreamBox>.fromOpaque(info).takeUnretainedValue().fire()
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagNoDefer
                // Keeps watching if the watched directory itself is renamed or
                // moved — a folder the user reorganises should not silently
                // stop being watched.
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.standardizedFileURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags)
        else {
            Logger.files.warningCapture(
                "FSEventStreamCreate failed for \(directory.path)",
                category: "watched-folders")
            box.setHandler(nil)
            return false
        }

        guard box.adopt(stream) else {
            Logger.files.warningCapture(
                "FSEventStreamStart failed for \(directory.path)",
                category: "watched-folders")
            box.setHandler(nil)
            return false
        }

        Logger.files.infoCapture(
            "FSEvents watching \(directory.path)", category: "watched-folders")
        return true
    }

    public func stopWatching() {
        box.invalidate()
    }
}

// MARK: - Stream ownership

/// Owns the `FSEventStreamRef` and the callback, off the main actor.
///
/// Two reasons this is not just stored properties on the watcher:
///
///   1. `deinit` cannot enter `@MainActor`, and a leaked FSEventStream retains
///      its dispatch queue and goes on delivering into freed memory.
///   2. The C callback receives an opaque `info` pointer and runs on the
///      stream's queue, so whatever it points at must be safe to touch from
///      there. A lock-guarded box is the smallest thing that is.
private final class StreamBox: @unchecked Sendable {

    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var handler: (@Sendable () -> Void)?

    /// Serial and utility-QoS: file-system change notification is background
    /// work, and serialising it means the callback can never re-enter.
    private let queue = DispatchQueue(
        label: "com.impress.folderwatch.fsevents", qos: .utility)

    func setHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    /// Attach a created stream to the queue and start it. Returns false (and
    /// releases the stream) if it will not start.
    func adopt(_ stream: FSEventStreamRef) -> Bool {
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        lock.lock()
        self.stream = stream
        lock.unlock()
        return true
    }

    func fire() {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?()
    }

    func invalidate() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        self.handler = nil
        lock.unlock()

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
#endif
