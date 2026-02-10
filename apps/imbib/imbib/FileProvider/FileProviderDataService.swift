//
//  FileProviderDataService.swift
//  imbib-FileProvider
//
//  Stub data service for the File Provider extension.
//  Provides the types and methods used by FileProviderEnumerator/Extension/Item.
//

import Foundation

/// Lightweight model representing a publication with a linked PDF for the File Provider.
struct FileProviderPublication {
    let id: UUID
    let citeKey: String
    let bibcode: String?
    let title: String?
    let fileSize: Int64
    let hasLocalFile: Bool
    let localFileURL: URL?
    let dateAdded: Date
    let dateModified: Date

    var itemIdentifier: String {
        id.uuidString
    }

    var displayFilename: String {
        if let bibcode, !bibcode.isEmpty {
            return "\(bibcode).pdf"
        }
        return "\(citeKey).pdf"
    }
}

/// Data service providing publications to the File Provider extension.
///
/// This is a stub — the File Provider extension cannot access the main app's
/// RustStoreAdapter directly. A real implementation would use an app group
/// shared container or XPC service.
@MainActor
final class FileProviderDataService {

    static let shared = FileProviderDataService()

    private init() {}

    func fetchPublicationsWithPDFs() async -> [FileProviderPublication] {
        // TODO: Read from shared app group container or XPC
        return []
    }

    func fetchItem(byLinkedFileID id: UUID) async -> FileProviderPublication? {
        // TODO: Read from shared app group container or XPC
        return nil
    }

    func fetchChanges(since anchorData: Data) async -> (changed: [FileProviderPublication], deleted: [UUID]) {
        // TODO: Implement change tracking via shared container
        return ([], [])
    }

    func currentSyncAnchor() -> Data {
        // Return current date as anchor
        let timestamp = Date().timeIntervalSince1970
        return withUnsafeBytes(of: timestamp) { Data($0) }
    }

    func resolveLocalURL(for publication: FileProviderPublication) async -> URL? {
        return publication.localFileURL
    }

    func materializeFile(for publication: FileProviderPublication) async -> URL? {
        // TODO: Download from CloudKit if needed
        return nil
    }
}
