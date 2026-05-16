import Foundation
import ImpressLogging
import OSLog

/// File-system watcher that fires a debounced callback when a `.vsz` file is
/// modified on disk. Mirrors the pattern in `LaTeXProjectService.startWatching`
/// (DispatchSource on a `O_EVTONLY` file descriptor) but is per-plot rather
/// than per-project so callers can attach/detach individual plots cheaply.
///
/// The debounce matters because Veusz writes atomically: a save lands as a
/// `.rename` (temp file moved into place) shortly followed by a `.write`. The
/// 500 ms window swallows the rename-settle without feeling laggy.
///
/// Cancellation rules (see MEMORY.md "Startup Render Loop Bug"): the debounce
/// uses a single `Task.sleep` — never `try? await Task.sleep` inside a `for`
/// loop, which would silently swallow `CancellationError` and keep the loop
/// alive past document close.
final class VeuszPlotWatcher: @unchecked Sendable {

    private struct Entry {
        let plotID: UUID
        let url: URL
        let source: DispatchSourceFileSystemObject
        let fileDescriptor: Int32
        var pendingDebounce: Task<Void, Never>?
    }

    private let queue = DispatchQueue(label: "com.imprint.veusz-watcher", qos: .utility)
    private var entries: [UUID: Entry] = [:]
    private let onChange: @Sendable (UUID) -> Void
    private let debounce: Duration

    init(debounce: Duration = .milliseconds(500), onChange: @escaping @Sendable (UUID) -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        stopAll()
    }

    /// Begin watching a `.vsz` file. Replaces any existing watch for the same plot ID.
    func watch(plotID: UUID, url: URL) {
        queue.sync { stopLocked(plotID: plotID) }

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            Logger.veusz.warningCapture("Failed to open \(url.lastPathComponent) for watching (errno \(errno))", category: "veusz")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        let entry = Entry(
            plotID: plotID,
            url: url,
            source: source,
            fileDescriptor: fd,
            pendingDebounce: nil
        )

        let capturedID = plotID
        let capturedDebounce = debounce
        let capturedOnChange = onChange
        let watcher = self
        source.setEventHandler { [weak watcher] in
            // Debounce: cancel any in-flight task, schedule a fresh one.
            watcher?.scheduleFire(plotID: capturedID, debounce: capturedDebounce, fire: capturedOnChange)
        }
        source.setCancelHandler {
            close(fd)
        }

        queue.sync {
            entries[plotID] = entry
            source.resume()
        }
    }

    /// Stop watching a single plot.
    func stop(plotID: UUID) {
        queue.sync { stopLocked(plotID: plotID) }
    }

    /// Stop watching everything.
    func stopAll() {
        queue.sync {
            for id in Array(entries.keys) {
                stopLocked(plotID: id)
            }
        }
    }

    // MARK: - Private

    private func stopLocked(plotID: UUID) {
        guard let entry = entries.removeValue(forKey: plotID) else { return }
        entry.pendingDebounce?.cancel()
        entry.source.cancel()
    }

    private func scheduleFire(
        plotID: UUID,
        debounce: Duration,
        fire: @Sendable @escaping (UUID) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.entries[plotID]?.pendingDebounce?.cancel()
            let task = Task.detached(priority: .utility) {
                // Single sleep, not a loop — try? Task.sleep inside a for-loop swallows
                // CancellationError and keeps the task alive after the watcher is torn down.
                try? await Task.sleep(for: debounce)
                if Task.isCancelled { return }
                fire(plotID)
            }
            self.entries[plotID]?.pendingDebounce = task
        }
    }
}
