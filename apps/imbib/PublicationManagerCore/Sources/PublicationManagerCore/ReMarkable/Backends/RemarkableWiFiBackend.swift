//
//  RemarkableWiFiBackend.swift
//  PublicationManagerCore
//
//  Sync with a reMarkable over the local network, with no cloud in the path.
//

import Foundation
import ImbibRustCore
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "remarkableWiFi")

/// Talks to the tablet on your own network over its SSH server.
///
/// reMarkable retired the cloud API this app's `RemarkableCloudBackend` speaks
/// (`document-storage/json/2` answers 404), and a cloud round trip was never
/// necessary anyway: the tablet runs Linux, and every document is a plain file
/// under one directory. This backend reaches those files directly, so papers
/// and annotations stay on the local network and no vendor API can retire
/// underneath them.
///
/// The transport itself is Rust (`crates/impress-remarkable`, SFTP over the
/// tablet's SSH server); this type is the projection onto imbib's backend
/// protocol. Calls block on the transport's runtime, so each hops off the
/// main thread.
///
/// The tablet must be awake — it drops Wi-Fi in standby — and its address and
/// root password are printed on the device under Settings → Help → Copyrights
/// and licenses.
public actor RemarkableWiFiBackend: RemarkableSyncBackend {

    public let backendID = "wifi"
    public let displayName = "reMarkable (Local Network)"

    private let settings = RemarkableSettingsStore.shared

    public init() {}

    // MARK: - Credentials

    /// Reads the address and password the researcher entered. Throws rather
    /// than guessing, so "not configured" never looks like "unreachable".
    private func credentials() async throws -> RmCredentials {
        let (host, port, fingerprint) = await MainActor.run {
            (settings.wifiHost, settings.wifiPort, settings.wifiFingerprint)
        }
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RemarkableError.notConfigured("No tablet address. Add it in Settings › reMarkable.")
        }
        let password = try await MainActor.run { try settings.retrieveWiFiPassword() }
        guard let password, !password.isEmpty else {
            throw RemarkableError.notConfigured("No tablet password stored. Add it in Settings › reMarkable.")
        }
        return RmCredentials(
            host: host,
            port: UInt16(clamping: port),
            username: "root",
            password: password,
            fingerprint: fingerprint
        )
    }

    /// Run a blocking transport call off the main thread.
    private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }

    // MARK: - Availability

    public func isAvailable() async -> Bool {
        guard let credentials = try? await credentials() else { return false }
        do {
            _ = try await offMain { try remarkableProbe(credentials: credentials) }
            return true
        } catch {
            logger.warning("reMarkable not reachable: \(error.localizedDescription)")
            return false
        }
    }

    /// Reach the tablet and pin its host key on first success.
    public func authenticate() async throws {
        let credentials = try await credentials()
        let info = try await offMain { try remarkableProbe(credentials: credentials) }
        await MainActor.run {
            // Trust on first use: remember the key so a different tablet (or
            // something else answering that address) is refused next time.
            if settings.wifiFingerprint == nil {
                settings.wifiFingerprint = info.fingerprint
            }
            settings.isAuthenticated = true
            settings.deviceName = info.firmware.map { "reMarkable \($0)" } ?? "reMarkable"
        }
        logger.info("Connected to reMarkable at \(info.host, privacy: .public), \(info.documentCount) documents")
    }

    public func disconnect() async {
        await MainActor.run { settings.clearWiFiCredentials() }
    }

    // MARK: - Documents

    public func listDocuments() async throws -> [RemarkableDocumentInfo] {
        let credentials = try await credentials()
        let documents = try await offMain { try remarkableListDocuments(credentials: credentials) }
        return documents
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
        let credentials = try await credentials()
        let documents = try await offMain { try remarkableListDocuments(credentials: credentials) }
        let folders = documents.filter { $0.kind == "folder" }
        return folders.map { folder in
            RemarkableFolderInfo(
                id: folder.id,
                name: folder.visibleName,
                parentFolderID: folder.parent.isEmpty ? nil : folder.parent,
                documentCount: documents.filter { $0.parent == folder.id }.count
            )
        }
    }

    public func downloadDocument(documentID: String) async throws -> RemarkableDocumentBundle {
        let credentials = try await credentials()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remarkable-\(documentID)", isDirectory: true)
        let destination = directory.path
        let download = try await offMain {
            try remarkableDownloadDocument(
                credentials: credentials, id: documentID, destination: destination)
        }
        guard let sourcePath = download.sourcePath,
              let data = FileManager.default.contents(atPath: sourcePath)
        else {
            // A notebook the tablet created has no source document, which is
            // a different thing from a failed transfer.
            throw RemarkableError.noPDFAvailable
        }
        let info = try await listDocuments().first { $0.id == documentID }
            ?? RemarkableDocumentInfo(
                id: documentID, name: documentID, parentFolderID: nil,
                lastModified: Date(), version: 0, pageCount: 0, hasAnnotations: false)
        return RemarkableDocumentBundle(
            documentInfo: info,
            pdfData: data,
            annotations: try await parseAnnotations(download.annotationPaths),
            metadata: ["source": "wifi", "sourcePath": sourcePath]
        )
    }

    public func downloadAnnotations(documentID: String) async throws -> [RemarkableRawAnnotation] {
        let credentials = try await credentials()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("remarkable-\(documentID)", isDirectory: true).path
        let download = try await offMain {
            try remarkableDownloadDocument(
                credentials: credentials, id: documentID, destination: destination)
        }
        return try await parseAnnotations(download.annotationPaths)
    }

    /// Parse the tablet's stroke files. One unreadable page is dropped rather
    /// than failing the whole document: a partial import beats none.
    private func parseAnnotations(_ paths: [String]) async throws -> [RemarkableRawAnnotation] {
        var annotations: [RemarkableRawAnnotation] = []
        for (page, path) in paths.enumerated() {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            guard let file = try? RMFileParser.parse(data) else {
                logger.warning("Unreadable stroke file at page \(page)")
                continue
            }
            for layer in file.layers {
                for (index, stroke) in layer.strokes.enumerated() {
                    let xs = stroke.points.map { CGFloat($0.x) }
                    let ys = stroke.points.map { CGFloat($0.y) }
                    guard let minX = xs.min(), let maxX = xs.max(),
                          let minY = ys.min(), let maxY = ys.max() else { continue }
                    annotations.append(RemarkableRawAnnotation(
                        id: "\(page)-\(layer.name)-\(index)",
                        pageNumber: page,
                        layerName: layer.name,
                        type: stroke.pen == .highlighter ? .highlight : .ink,
                        bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                        color: String(describing: stroke.color)
                    ))
                }
            }
        }
        return annotations
    }

    // MARK: - Writing (not yet implemented)

    public func uploadDocument(_ data: Data, filename: String, parentFolder: String?) async throws -> String {
        throw RemarkableError.uploadFailed(
            "Sending documents to the tablet over the local network is not implemented yet; reading works.")
    }

    public func createFolder(name: String, parent: String?) async throws -> String {
        throw RemarkableError.uploadFailed(
            "Creating folders on the tablet is not implemented yet.")
    }

    public func deleteDocument(documentID: String) async throws {
        throw RemarkableError.uploadFailed(
            "Deleting on the tablet is not implemented yet; delete it on the device.")
    }

    // MARK: - Device

    public func getDeviceInfo() async throws -> RemarkableDeviceInfo {
        let credentials = try await credentials()
        let info = try await offMain { try remarkableProbe(credentials: credentials) }
        return RemarkableDeviceInfo(
            deviceID: info.fingerprint,
            deviceName: info.firmware.map { "reMarkable \($0)" } ?? "reMarkable",
            storageUsed: nil,
            storageTotal: nil
        )
    }
}
