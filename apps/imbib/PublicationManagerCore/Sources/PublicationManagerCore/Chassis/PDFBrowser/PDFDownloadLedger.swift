//
//  PDFDownloadLedger.swift
//  PublicationManagerCore
//
//  The PDF browser's bookkeeping for downloads in flight, one entry PER
//  download.
//
//  It was one slot. A publisher page routinely starts the same PDF twice (the
//  navigation response becomes a download, and the proactive check starts
//  another), and the second download's destination overwrote the first's. The
//  first to finish then read the OTHER download's half-written temp file,
//  handed that over as "the PDF" and deleted it; the second finished with
//  0 bytes. The import that followed stored a truncated PDF (2026-09-11,
//  PhysRevD.105.023512: 770 KB of 2.2 MB).
//
//  WebKit calls the async destination callback off the main thread and the
//  finish callback on it, so entries are guarded by a lock.
//

import Foundation

public final class PDFDownloadLedger: @unchecked Sendable {

    public struct Entry: Equatable, Sendable {
        public let filename: String
        /// The server's Content-Length, or ≤ 0 when it sent none.
        public let expectedLength: Int64
        /// Where this download — and only this one — writes.
        public let tempURL: URL
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private let directory: URL

    public init(directory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
    }

    /// Register a download and give it a destination of its own.
    public func begin(_ key: ObjectIdentifier, filename: String, expectedLength: Int64) -> URL {
        let entry = Entry(
            filename: filename,
            expectedLength: expectedLength,
            tempURL: directory.appendingPathComponent(UUID().uuidString + ".download"))
        lock.lock()
        entries[key] = entry
        lock.unlock()
        return entry.tempURL
    }

    /// The download finished: its entry and the bytes IT wrote, with its temp
    /// file removed. Nil for a download this ledger never registered.
    public func finish(_ key: ObjectIdentifier) -> (entry: Entry, data: Data?)? {
        guard let entry = take(key) else { return nil }
        let data = try? Data(contentsOf: entry.tempURL)
        try? FileManager.default.removeItem(at: entry.tempURL)
        return (entry, data)
    }

    /// The download failed: forget it and remove its temp file.
    @discardableResult
    public func fail(_ key: ObjectIdentifier) -> Entry? {
        guard let entry = take(key) else { return nil }
        try? FileManager.default.removeItem(at: entry.tempURL)
        return entry
    }

    /// Downloads still running.
    public var inFlightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private func take(_ key: ObjectIdentifier) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries.removeValue(forKey: key)
    }
}
