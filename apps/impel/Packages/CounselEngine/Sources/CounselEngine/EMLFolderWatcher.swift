//
//  EMLFolderWatcher.swift
//  CounselEngine
//
//  Watches a directory for .eml files and feeds them into the MessageStore.
//  Provides a fallback capture method when SMTP isn't available.
//

import Foundation
import ImpelMail
import OSLog

/// Watches a directory for .eml files and feeds them into the mail processing pipeline.
///
/// Files are processed and moved to a `.processed/` subdirectory on success,
/// or `.errors/` on failure. Uses DispatchSource for filesystem events with
/// a 30-second polling fallback.
public actor EMLFolderWatcher {

    private let logger = Logger(subsystem: "com.impress.impel", category: "emlWatcher")

    private let watchPath: URL
    private let store: MessageStore
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var pollingTask: Task<Void, Never>?
    private var isRunning = false

    /// Default folder path for the capture inbox.
    public static var defaultPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("com.impress.impel/capture-inbox")
    }

    public init(path: URL? = nil, store: MessageStore) {
        self.watchPath = path ?? Self.defaultPath
        self.store = store
    }

    /// Start watching the folder for .eml files.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // Ensure directories exist
        let fm = FileManager.default
        try? fm.createDirectory(at: watchPath, withIntermediateDirectories: true)
        try? fm.createDirectory(at: processedDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: errorsDirectory, withIntermediateDirectories: true)

        // Process any existing files
        Task { await scanAndProcess() }

        // Set up DispatchSource for filesystem events
        startDispatchSource()

        // Polling fallback — DispatchSource may miss events in some scenarios
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await self.scanAndProcess()
            }
        }

        logger.info("EML folder watcher started: \(self.watchPath.path)")
    }

    /// Stop watching.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        dispatchSource?.cancel()
        dispatchSource = nil
        pollingTask?.cancel()
        pollingTask = nil
        logger.info("EML folder watcher stopped")
    }

    /// The watched folder path.
    public var folderPath: URL { watchPath }

    // MARK: - Scanning

    /// Scan the watch directory for .eml files and process each one.
    private func scanAndProcess() async {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: watchPath,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return // Directory may not exist yet
        }

        let emlFiles = contents.filter { $0.pathExtension.lowercased() == "eml" }
        for file in emlFiles {
            await processEMLFile(file)
        }
    }

    /// Process a single .eml file.
    private func processEMLFile(_ fileURL: URL) async {
        logger.info("Processing EML file: \(fileURL.lastPathComponent)")

        do {
            let rawData = try String(contentsOf: fileURL, encoding: .utf8)

            // Parse the .eml file using EmailParser.
            // .eml files typically have the full From/To in headers, so we pass
            // empty envelope values — the parser will extract from headers.
            let message = EmailParser.parse(
                rawData: rawData,
                from: "",
                to: [],
                envelopeRecipients: ["capture@impress.local"]
            )

            // Feed into the store — this triggers the same routing as SMTP
            await store.receiveIncoming(message)

            // Move to processed directory
            let dest = processedDirectory.appendingPathComponent(fileURL.lastPathComponent)
            try FileManager.default.moveItem(at: fileURL, to: dest)

            logger.info("Processed EML file: \(fileURL.lastPathComponent)")
        } catch {
            logger.error("Failed to process EML file \(fileURL.lastPathComponent): \(error.localizedDescription)")
            // Move to errors directory
            let dest = errorsDirectory.appendingPathComponent(fileURL.lastPathComponent)
            try? FileManager.default.moveItem(at: fileURL, to: dest)
        }
    }

    // MARK: - DispatchSource

    /// Start a DispatchSource watching the folder for write events.
    private nonisolated func startDispatchSource() {
        let path = watchPath.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.scanAndProcess() }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()

        Task { await self.setDispatchSource(source) }
    }

    /// Store the dispatch source (actor-isolated setter).
    private func setDispatchSource(_ source: DispatchSourceFileSystemObject) {
        self.dispatchSource = source
    }

    // MARK: - Directories

    private var processedDirectory: URL {
        watchPath.appendingPathComponent(".processed")
    }

    private var errorsDirectory: URL {
        watchPath.appendingPathComponent(".errors")
    }
}
