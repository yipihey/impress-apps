//
//  LibraryFilesMigration.swift
//  PublicationManagerCore
//
//  Copies imbib's library files from its private container to the suite's
//  shared one (`LibraryFilesLocation`), so every suite app can open them.
//
//  This touches the user's files, so every rule here is about not losing one:
//
//  - The layout is preserved byte for byte: `<legacy>/Libraries/<id>/Papers/x`
//    becomes `<shared>/Libraries/<id>/Papers/x`. A file stays under the library
//    it was under — including one an older build misfiled, which the resolver
//    still finds by size — so no linked-file row changes and no store write
//    happens.
//  - A copy lands under a temporary name, is verified (same size, same
//    SHA-256, and for a PDF: PDFKit opens it, per `PDFDataValidator`), and only
//    then is renamed into place. A failed verification removes the temporary
//    copy — the only file this code ever created — and leaves the original.
//  - An existing destination is never overwritten. Same size: already there.
//    Different size: a conflict, logged, both left alone.
//  - Originals are KEPT by default (`OriginalsPolicy.keep`). On APFS the copy
//    is a clone, so keeping them costs almost no disk, older imbib builds keep
//    working, and undoing the migration is deleting the shared tree.
//    `.removeAfterVerification` exists for a later, deliberate cleanup; it
//    removes an original only after its copy verified in this same run.
//  - `dryRun` reports what would be copied and writes nothing.
//  - It is idempotent: a second run finds every file already present (by
//    size, without re-hashing) and copies nothing.
//
//  Every file gets a log line; the summary counts files and bytes.
//

import CryptoKit
import Foundation
import OSLog

public struct LibraryFilesMigration: Sendable {

    public enum OriginalsPolicy: Sendable {
        case keep
        case removeAfterVerification
    }

    /// What happened to one file.
    public enum FileOutcome: Equatable, Sendable {
        case copied(bytes: Int64)
        case wouldCopy(bytes: Int64)
        case alreadyPresent
        case conflict(String)
        case failed(String)
    }

    public struct Summary: Equatable, Sendable {
        public var copied = 0
        public var wouldCopy = 0
        public var alreadyPresent = 0
        public var conflicts = 0
        public var failed = 0
        public var bytesCopied: Int64 = 0
        public var originalsRemoved = 0
        public var files: [String: FileOutcome] = [:]

        public var line: String {
            "copied \(copied) (\(bytesCopied) bytes), would copy \(wouldCopy), already present \(alreadyPresent), conflicts \(conflicts), failed \(failed), originals removed \(originalsRemoved)"
        }
    }

    /// The subtrees of a root that hold library files: per-library containers,
    /// the no-library default, and pre-v1.3.0 downloads.
    public static let subtrees = ["Libraries", "DefaultLibrary", "Papers"]

    public let source: URL
    public let destination: URL
    public let dryRun: Bool
    public let originals: OriginalsPolicy

    public init(
        source: URL = LibraryFilesLocation.legacyRoot,
        destination: URL = LibraryFilesLocation.sharedRoot,
        dryRun: Bool = false,
        originals: OriginalsPolicy = .keep
    ) {
        self.source = source.standardizedFileURL
        self.destination = destination.standardizedFileURL
        self.dryRun = dryRun
        self.originals = originals
    }

    private static let category = "files-migration"
    private var log: Logger { Logger.files }

    /// Run it. Synchronous file work — call off the main thread.
    @discardableResult
    public func run() -> Summary {
        var summary = Summary()
        guard source.path != destination.path else { return summary }
        let fm = FileManager.default

        for subtree in Self.subtrees {
            let root = source.appendingPathComponent(subtree, isDirectory: true)
            guard fm.fileExists(atPath: root.path),
                  let walker = fm.enumerator(atPath: root.path)
            else { continue }

            // Paths relative to the subtree, so `/var` vs `/private/var` never
            // matters. Regular files only (no links, no directories), and no
            // dot-files — Finder's `.DS_Store`, or a staging copy of our own.
            while let path = walker.nextObject() as? String {
                guard walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular,
                      !path.split(separator: "/").contains(where: { $0.hasPrefix(".") })
                else { continue }
                let relative = subtree + "/" + path
                let url = root.appendingPathComponent(path)
                let outcome = migrate(url, relative: relative)
                record(outcome, for: relative, into: &summary)
                if case .copied = outcome, originals == .removeAfterVerification {
                    do {
                        try fm.removeItem(at: url)
                        summary.originalsRemoved += 1
                        log.infoCapture("removed original after verified copy: \(relative)", category: Self.category)
                    } catch {
                        log.warningCapture("could not remove original \(relative): \(error.localizedDescription)", category: Self.category)
                    }
                }
            }
        }

        let mode = dryRun ? "dry run" : "run"
        if summary.copied + summary.wouldCopy + summary.conflicts + summary.failed > 0 {
            log.infoCapture("library files migration \(mode) \(source.path) → \(destination.path): \(summary.line)", category: Self.category)
        } else {
            log.debugCapture("library files migration \(mode): nothing to do (\(summary.alreadyPresent) already present)", category: Self.category)
        }
        return summary
    }

    // MARK: - One file

    private func migrate(_ original: URL, relative: String) -> FileOutcome {
        let fm = FileManager.default
        let target = destination.appendingPathComponent(relative)
        guard let size = Self.size(of: original) else {
            return .failed("cannot read the original's size")
        }

        if fm.fileExists(atPath: target.path) {
            guard let existing = Self.size(of: target) else { return .conflict("destination unreadable") }
            return existing == size
                ? .alreadyPresent
                : .conflict("destination exists with \(existing) bytes, original has \(size)")
        }
        if dryRun { return .wouldCopy(bytes: size) }

        let directory = target.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(".\(target.lastPathComponent).migrating-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.copyItem(at: original, to: staging)   // clonefile on APFS
        } catch {
            try? fm.removeItem(at: staging)
            return .failed("copy failed: \(error.localizedDescription)")
        }

        if let problem = verify(copy: staging, of: original, size: size, relative: relative) {
            try? fm.removeItem(at: staging)
            return .failed(problem)
        }
        do {
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            return .failed("rename into place failed: \(error.localizedDescription)")
        }
        return .copied(bytes: size)
    }

    /// Nil when the copy is the original. A PDF must also open in PDFKit —
    /// unless the original itself does not, in which case a byte-identical
    /// copy is the faithful one and the damage is logged, not "fixed".
    private func verify(copy: URL, of original: URL, size: Int64, relative: String) -> String? {
        guard Self.size(of: copy) == size else {
            return "copy has \(Self.size(of: copy) ?? -1) bytes, original \(size)"
        }
        guard let a = Self.sha256(of: original), let b = Self.sha256(of: copy) else {
            return "cannot hash original or copy"
        }
        guard a == b else { return "copy's SHA-256 differs from the original's" }
        if original.pathExtension.lowercased() == "pdf" {
            if let problem = PDFDataValidator.check(fileAt: copy).problem {
                if PDFDataValidator.check(fileAt: original).isComplete {
                    return "copy does not open in PDFKit: \(problem)"
                }
                log.warningCapture("\(relative): the original PDF is already unreadable (\(problem)); copied byte for byte", category: Self.category)
            }
        }
        return nil
    }

    private func record(_ outcome: FileOutcome, for relative: String, into summary: inout Summary) {
        summary.files[relative] = outcome
        switch outcome {
        case .copied(let bytes):
            summary.copied += 1
            summary.bytesCopied += bytes
            log.infoCapture("copied + verified \(relative) (\(bytes) bytes)", category: Self.category)
        case .wouldCopy(let bytes):
            summary.wouldCopy += 1
            log.infoCapture("dry run: would copy \(relative) (\(bytes) bytes)", category: Self.category)
        case .alreadyPresent:
            summary.alreadyPresent += 1
            log.debugCapture("already present: \(relative)", category: Self.category)
        case .conflict(let why):
            summary.conflicts += 1
            log.warningCapture("left alone, \(relative): \(why)", category: Self.category)
        case .failed(let why):
            summary.failed += 1
            log.errorCapture("NOT migrated, original untouched, \(relative): \(why)", category: Self.category)
        }
    }

    // MARK: - Helpers

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // `read(upToCount:)` answers nil (or empty) at end of file; only a
            // thrown error is a failure.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
