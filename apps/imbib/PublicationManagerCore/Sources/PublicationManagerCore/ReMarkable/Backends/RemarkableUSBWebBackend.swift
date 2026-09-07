//
//  RemarkableUSBWebBackend.swift
//  PublicationManagerCore
//
//  Sync with a reMarkable over its own USB web interface — no credential.
//

import Foundation
import ImbibRustCore
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "remarkableUSB")

/// Talks to the tablet's own web interface over the USB cable.
///
/// This is the transport that asks the researcher for nothing: no cloud
/// token, no device password, no developer mode. On current firmware that is
/// decisive — SSH sits behind Developer mode (which erases a Paper Pro when
/// enabled) and reMarkable has closed the cloud's document endpoints to
/// third-party clients, so this is the supported way in.
///
/// It needs the cable connected and Settings → Storage → "USB web interface"
/// switched on. Downloads arrive as a PDF with the handwritten annotations
/// already rendered into the page, which is what imbib files against a paper.
public actor RemarkableUSBWebBackend: RemarkableSyncBackend {

    public let backendID = "usb-web"
    public let displayName = "reMarkable (USB)"

    private let baseURL: String

    public init(baseURL: String? = nil) {
        self.baseURL = baseURL ?? remarkableUsbDefaultUrl()
    }

    /// Run a blocking transport call off the main thread.
    private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }

    // MARK: - Availability

    public func isAvailable() async -> Bool {
        let url = baseURL
        do {
            _ = try await offMain { try remarkableUsbProbe(baseUrl: url) }
            return true
        } catch {
            logger.debug("reMarkable USB interface not reachable: \(error.localizedDescription)")
            return false
        }
    }

    /// Nothing to authenticate; reaching the tablet is the whole check.
    public func authenticate() async throws {
        let url = baseURL
        let count = try await offMain { try remarkableUsbProbe(baseUrl: url) }
        logger.info("reMarkable USB interface reachable, \(count) entries")
    }

    public func disconnect() async {}

    // MARK: - Documents

    private func entries() async throws -> [RmDocument] {
        let url = baseURL
        return try await offMain { try remarkableUsbListDocuments(baseUrl: url) }
    }

    public func listDocuments() async throws -> [RemarkableDocumentInfo] {
        try await entries()
            .filter { $0.kind == "document" }
            .map { document in
                RemarkableDocumentInfo(
                    id: document.id,
                    name: document.visibleName,
                    parentFolderID: document.parent.isEmpty ? nil : document.parent,
                    lastModified: Date(timeIntervalSince1970: TimeInterval(document.lastModifiedMs) / 1000),
                    version: 0,
                    pageCount: Int(document.pageCount),
                    hasAnnotations: document.hasAnnotations
                )
            }
    }

    public func listFolders() async throws -> [RemarkableFolderInfo] {
        let all = try await entries()
        return all.filter { $0.kind == "folder" }.map { folder in
            RemarkableFolderInfo(
                id: folder.id,
                name: folder.visibleName,
                parentFolderID: folder.parent.isEmpty ? nil : folder.parent,
                documentCount: all.filter { $0.parent == folder.id }.count
            )
        }
    }

    public func downloadDocument(documentID: String) async throws -> RemarkableDocumentBundle {
        let url = baseURL
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("remarkable-usb", isDirectory: true).path
        let path = try await offMain {
            try remarkableUsbDownloadDocument(baseUrl: url, id: documentID, destination: destination)
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw RemarkableError.downloadFailed("The tablet returned no data for \(documentID)")
        }
        let info = try await listDocuments().first { $0.id == documentID }
            ?? RemarkableDocumentInfo(
                id: documentID, name: documentID, parentFolderID: nil,
                lastModified: Date(), version: 0, pageCount: 0, hasAnnotations: false)
        return RemarkableDocumentBundle(
            documentInfo: info,
            pdfData: data,
            // The strokes are drawn into the PDF by the tablet, so there is no
            // separate stroke file to parse on this transport.
            annotations: [],
            metadata: ["source": "usb-web", "path": path, "annotationsRendered": "true"]
        )
    }

    /// The tablet renders annotations into the PDF rather than exposing them
    /// as strokes, so there is nothing separate to hand back.
    public func downloadAnnotations(documentID: String) async throws -> [RemarkableRawAnnotation] {
        throw RemarkableError.annotationSyncNotSupported(backend: displayName)
    }

    public func uploadDocument(_ data: Data, filename: String, parentFolder: String?) async throws -> String {
        let url = baseURL
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename.isEmpty ? "document.pdf" : filename)
        try data.write(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        let path = staged.path
        try await offMain { try remarkableUsbUploadDocument(baseUrl: url, file: path) }
        logger.info("Sent \(filename, privacy: .public) to the tablet")
        // The interface reports no id for the new document; the next listing
        // is where it appears.
        return ""
    }

    public func createFolder(name: String, parent: String?) async throws -> String {
        throw RemarkableError.uploadFailed(
            "The tablet's USB interface cannot create folders; make it on the device.")
    }

    public func deleteDocument(documentID: String) async throws {
        throw RemarkableError.uploadFailed(
            "The tablet's USB interface cannot delete; remove it on the device.")
    }

    public func getDeviceInfo() async throws -> RemarkableDeviceInfo {
        let url = baseURL
        let count = try await offMain { try remarkableUsbProbe(baseUrl: url) }
        return RemarkableDeviceInfo(
            deviceID: "usb-web",
            deviceName: "reMarkable (USB, \(count) items)",
            storageUsed: nil,
            storageTotal: nil
        )
    }
}
