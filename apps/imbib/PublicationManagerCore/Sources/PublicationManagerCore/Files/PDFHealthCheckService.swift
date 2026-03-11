//
//  PDFHealthCheckService.swift
//  PublicationManagerCore
//
//  Detects and repairs linked files that are in the wrong library directory
//  (e.g., after a publication was moved between libraries without moving the file).
//

import Foundation
import OSLog

/// Result of a health check run.
public struct PDFHealthCheckResult: Sendable {
    public let filesChecked: Int
    public let filesMisplaced: Int
    public let filesRepaired: Int
    public let filesMissing: Int
}

/// Scans all libraries for linked files whose physical location doesn't match
/// the library they belong to, and moves them to the correct directory.
///
/// Optimized for large libraries (100k+ publications):
/// - Only checks publications with `hasDownloadedPDF` (typically <10% of total)
/// - Uses directory listings instead of per-file stat calls
/// - Batches MainActor work to avoid UI jank
public actor PDFHealthCheckService {

    public static let shared = PDFHealthCheckService()

    private var hasRun = false

    /// Run the health check. Safe to call multiple times — subsequent calls
    /// return immediately if the check has already run this session.
    @discardableResult
    public func runCheck() async -> PDFHealthCheckResult {
        guard !hasRun else {
            return PDFHealthCheckResult(filesChecked: 0, filesMisplaced: 0, filesRepaired: 0, filesMissing: 0)
        }
        hasRun = true

        let result = await performCheck()

        if result.filesMisplaced > 0 || result.filesMissing > 0 {
            Logger.files.infoCapture(
                "Health check: checked=\(result.filesChecked) misplaced=\(result.filesMisplaced) repaired=\(result.filesRepaired) missing=\(result.filesMissing)",
                category: "healthcheck"
            )
        } else if result.filesChecked > 0 {
            Logger.files.infoCapture("Health check: \(result.filesChecked) files OK", category: "healthcheck")
        }

        await MainActor.run {
            NotificationCenter.default.post(name: .databaseHealthCheckCompleted, object: nil)
        }

        return result
    }

    /// Force a re-run even if the check has already completed this session.
    @discardableResult
    public func forceRecheck() async -> PDFHealthCheckResult {
        hasRun = false
        return await runCheck()
    }

    // MARK: - Internal Types

    /// Pre-gathered per-library data, all collected in one MainActor batch.
    private struct LibraryCheckData: Sendable {
        let libraryID: UUID
        let containerURL: URL
        /// Publication IDs that have `hasDownloadedPDF == true`.
        let pubIDsWithPDFs: [UUID]
    }

    /// A linked file + its owning library, ready for off-thread checking.
    private struct FileToCheck: Sendable {
        let file: LinkedFileModel
        let expectedLibraryID: UUID
    }

    // MARK: - Check Implementation

    private func performCheck() async -> PDFHealthCheckResult {
        // Phase 1: Gather data from MainActor in batched hops (not per-file)
        let libraryData: [LibraryCheckData] = await MainActor.run {
            let store = RustStoreAdapter.shared
            let attachmentMgr = AttachmentManager.shared
            let libraries = store.listLibraries()

            return libraries.map { lib in
                // queryPublications returns PublicationRowData which has hasDownloadedPDF
                let allPubs = store.queryPublications(parentId: lib.id)
                let pubsWithPDFs = allPubs.filter(\.hasDownloadedPDF).map(\.id)

                return LibraryCheckData(
                    libraryID: lib.id,
                    containerURL: attachmentMgr.containerURL(for: lib.id),
                    pubIDsWithPDFs: pubsWithPDFs
                )
            }
        }

        // Quick exit: no libraries or no PDFs at all
        let totalPubsWithPDFs = libraryData.reduce(0) { $0 + $1.pubIDsWithPDFs.count }
        if totalPubsWithPDFs == 0 {
            return PDFHealthCheckResult(filesChecked: 0, filesMisplaced: 0, filesRepaired: 0, filesMissing: 0)
        }

        // Phase 2: Build filesystem index — one directory listing per library (off MainActor)
        // Maps library UUID → set of filenames that exist in Papers/
        let fileManager = FileManager.default
        var fileIndex: [UUID: Set<String>] = [:]
        for data in libraryData {
            let papersURL = data.containerURL.appendingPathComponent("Papers", isDirectory: true)
            if let contents = try? fileManager.contentsOfDirectory(atPath: papersURL.path) {
                fileIndex[data.libraryID] = Set(contents.map { $0.precomposedStringWithCanonicalMapping })
            } else {
                fileIndex[data.libraryID] = []
            }
        }

        // Phase 3: Query linked files only for publications with PDFs
        // Batch into chunks to avoid blocking MainActor for too long
        let chunkSize = 500
        var filesToCheck: [FileToCheck] = []

        for data in libraryData {
            let pubIDs = data.pubIDsWithPDFs
            for chunkStart in stride(from: 0, to: pubIDs.count, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, pubIDs.count)
                let chunk = Array(pubIDs[chunkStart..<chunkEnd])

                let chunkFiles: [FileToCheck] = await MainActor.run {
                    let store = RustStoreAdapter.shared
                    var result: [FileToCheck] = []
                    for pubID in chunk {
                        let files = store.listLinkedFiles(publicationId: pubID)
                        for file in files {
                            result.append(FileToCheck(file: file, expectedLibraryID: data.libraryID))
                        }
                    }
                    return result
                }
                filesToCheck.append(contentsOf: chunkFiles)

                // Yield between chunks to let UI breathe
                if chunkEnd < pubIDs.count {
                    try? await Task.sleep(for: .milliseconds(10))
                    guard !Task.isCancelled else {
                        return PDFHealthCheckResult(filesChecked: 0, filesMisplaced: 0, filesRepaired: 0, filesMissing: 0)
                    }
                }
            }
        }

        // Phase 4: Check each file against the filesystem index (all off MainActor)
        var filesChecked = 0
        var filesMisplaced = 0
        var filesRepaired = 0
        var filesMissing = 0

        // Pre-build a map of containerURL per library for repairs
        let containerURLs: [UUID: URL] = Dictionary(
            uniqueKeysWithValues: libraryData.map { ($0.libraryID, $0.containerURL) }
        )

        for entry in filesToCheck {
            filesChecked += 1

            guard let relativePath = entry.file.relativePath else { continue }
            let normalized = relativePath.precomposedStringWithCanonicalMapping

            // Fast check: does the file exist in the expected library's Papers/?
            // relativePath is typically "Papers/filename.pdf" — extract the filename
            let filename = (normalized as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
            let expectedFiles = fileIndex[entry.expectedLibraryID] ?? []

            if expectedFiles.contains(filename) {
                continue // File is where it should be
            }

            // Also check full path in case relative path doesn't start with Papers/
            let expectedURL = containerURLs[entry.expectedLibraryID]!.appendingPathComponent(normalized)
            if fileManager.fileExists(atPath: expectedURL.path) {
                continue
            }

            // File missing at expected location — check other libraries
            var foundInLibrary: UUID?
            for (libID, files) in fileIndex where libID != entry.expectedLibraryID {
                if files.contains(filename) {
                    // Verify the full path exists (filename alone could be ambiguous)
                    let candidateURL = containerURLs[libID]!.appendingPathComponent(normalized)
                    if fileManager.fileExists(atPath: candidateURL.path) {
                        foundInLibrary = libID
                        break
                    }
                }
            }

            if let sourceLibID = foundInLibrary {
                filesMisplaced += 1
                do {
                    try await MainActor.run {
                        try AttachmentManager.shared.moveLinkedFile(entry.file, from: sourceLibID, to: entry.expectedLibraryID)
                    }
                    filesRepaired += 1
                    // Update the index so subsequent checks see the moved file
                    fileIndex[entry.expectedLibraryID, default: []].insert(filename)
                    fileIndex[sourceLibID]?.remove(filename)
                } catch {
                    Logger.files.error("Health check repair failed for \(entry.file.filename): \(error)")
                }
            } else {
                filesMissing += 1
            }
        }

        return PDFHealthCheckResult(
            filesChecked: filesChecked,
            filesMisplaced: filesMisplaced,
            filesRepaired: filesRepaired,
            filesMissing: filesMissing
        )
    }
}
