//
//  RemarkableCloudBackend.swift
//  PublicationManagerCore
//
//  reMarkable Cloud API backend implementation.
//  ADR-019: reMarkable Tablet Integration
//
//  API documentation: https://github.com/juruen/rmapi
//  Uses device code authentication flow.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "remarkableCloud")

// MARK: - Cloud Backend Actor

/// Backend for syncing with reMarkable Cloud API.
///
/// Uses the unofficial reMarkable Cloud API with device code authentication.
/// The authentication flow is:
/// 1. Request a device code from auth server
/// 2. User enters code at my.remarkable.com/device/browser/connect
/// 3. Poll for completion and receive device token
/// 4. Use device token to get user token for API calls
public actor RemarkableCloudBackend: RemarkableSyncBackend {

    // MARK: - Backend Protocol

    public let backendID: String = "cloud"
    public let displayName: String = "reMarkable Cloud"

    // MARK: - API Endpoints

    private static let authHost = "webapp-prod.cloud.remarkable.engineering"
    private static let syncHost = "document-storage-production-dot-remarkable-production.appspot.com"
    private static let discoveryHost = "service-manager-production-dot-remarkable-production.appspot.com"

    private static let deviceTokenURL = "https://\(authHost)/token/json/2/device/new"
    private static let userTokenURL = "https://\(authHost)/token/json/2/user/new"
    private static let deviceCodeURL = "https://\(authHost)/token/json/2/device/new"
    private static let listDocsURL = "https://\(syncHost)/document-storage/json/2/docs"
    private static let uploadRequestURL = "https://\(syncHost)/document-storage/json/2/upload/request"
    private static let updateStatusURL = "https://\(syncHost)/document-storage/json/2/upload/update-status"
    private static let deleteURL = "https://\(syncHost)/document-storage/json/2/delete"

    // MARK: - State

    private var userToken: String?
    private let settings = RemarkableSettingsStore.shared
    private let session: URLSession

    // MARK: - Initialization

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - Availability

    public func isAvailable() async -> Bool {
        // Check if we have a stored token
        guard let token = try? await MainActor.run(body: { try settings.retrieveToken() }),
              !token.isEmpty else {
            return false
        }

        // Try to refresh user token to verify it's still valid
        do {
            userToken = try await refreshUserToken(deviceToken: token)
            return true
        } catch {
            logger.warning("Failed to refresh user token: \(error)")
            return false
        }
    }

    // MARK: - Authentication

    /// Start the device code authentication flow.
    ///
    /// Returns a code that the user must enter at my.remarkable.com/device/browser/connect
    public func startAuthentication() async throws -> DeviceCodeResponse {
        let uuid = UUID().uuidString.lowercased()
        let body = DeviceCodeRequest(
            code: uuid,
            deviceDesc: "desktop-macos",
            deviceID: uuid
        )

        var request = URLRequest(url: URL(string: Self.deviceCodeURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemarkableError.authFailed("Invalid response")
        }

        // reMarkable API returns 200 with empty body for device code request
        if httpResponse.statusCode == 200 {
            // Post notification with the code for UI display
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .remarkableShowAuthCode,
                    object: nil,
                    userInfo: ["code": uuid]
                )
            }

            return DeviceCodeResponse(
                deviceCode: uuid,
                userCode: uuid,
                verificationURL: "https://my.remarkable.com/device/browser/connect"
            )
        }

        logger.error("Auth request failed: \(httpResponse.statusCode)")
        throw RemarkableError.authFailed("Server returned \(httpResponse.statusCode)")
    }

    /// Poll for authentication completion after user enters code.
    public func pollForAuthCompletion(deviceCode: String, timeout: TimeInterval = 120) async throws {
        let startTime = Date()
        let pollInterval: TimeInterval = 2.0

        while Date().timeIntervalSince(startTime) < timeout {
            do {
                let deviceToken = try await fetchDeviceToken(code: deviceCode)
                userToken = try await refreshUserToken(deviceToken: deviceToken)

                // Store token securely
                await MainActor.run {
                    try? settings.storeToken(deviceToken)
                    settings.isAuthenticated = true
                }

                logger.info("Authentication successful")
                return
            } catch {
                // Continue polling
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }

        throw RemarkableError.authTimeout
    }

    private func fetchDeviceToken(code: String) async throws -> String {
        var request = URLRequest(url: URL(string: Self.deviceTokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "code": code,
            "deviceDesc": "desktop-macos",
            "deviceID": code
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RemarkableError.authFailed("Device token request failed")
        }

        // Token is returned as plain text
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw RemarkableError.authFailed("Empty device token")
        }

        return token
    }

    private func refreshUserToken(deviceToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: Self.userTokenURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RemarkableError.authFailed("User token refresh failed")
        }

        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw RemarkableError.authFailed("Empty user token")
        }

        return token
    }

    public func authenticate() async throws {
        let codeResponse = try await startAuthentication()
        try await pollForAuthCompletion(deviceCode: codeResponse.deviceCode)
    }

    public func disconnect() async {
        userToken = nil
        await MainActor.run {
            settings.clearCredentials()
        }
    }

    // MARK: - Document Operations

    public func listDocuments() async throws -> [RemarkableDocumentInfo] {
        try await ensureAuthenticated()

        var request = URLRequest(url: URL(string: Self.listDocsURL)!)
        request.setValue("Bearer \(userToken!)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RemarkableError.downloadFailed("Failed to list documents")
        }

        let docs = try JSONDecoder().decode([CloudDocument].self, from: data)
        return docs.filter { $0.type == "DocumentType" }.map { doc in
            RemarkableDocumentInfo(
                id: doc.id,
                name: doc.visibleName,
                parentFolderID: doc.parent.isEmpty ? nil : doc.parent,
                lastModified: ISO8601DateFormatter().date(from: doc.modifiedClient) ?? Date(),
                version: doc.version,
                pageCount: 0,  // Would need separate call to get page count
                hasAnnotations: false  // Would need to check .rm files
            )
        }
    }

    public func listFolders() async throws -> [RemarkableFolderInfo] {
        try await ensureAuthenticated()

        var request = URLRequest(url: URL(string: Self.listDocsURL)!)
        request.setValue("Bearer \(userToken!)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RemarkableError.downloadFailed("Failed to list folders")
        }

        let allDocs = try JSONDecoder().decode([CloudDocument].self, from: data)
        return allDocs.filter { $0.type == "CollectionType" }.map { doc in
            // Count documents in this folder
            let childCount = allDocs.filter { $0.parent == doc.id && $0.type == "DocumentType" }.count
            return RemarkableFolderInfo(
                id: doc.id,
                name: doc.visibleName,
                parentFolderID: doc.parent.isEmpty ? nil : doc.parent,
                documentCount: childCount
            )
        }
    }

    public func uploadDocument(_ data: Data, filename: String, parentFolder: String?) async throws -> String {
        try await ensureAuthenticated()

        let documentID = UUID().uuidString.lowercased()

        // Step 1: Request upload URL
        let uploadRequest = UploadRequest(
            id: documentID,
            type: "DocumentType",
            version: 1
        )

        var req = URLRequest(url: URL(string: Self.uploadRequestURL)!)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(userToken!)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode([uploadRequest])

        let (responseData, response) = try await session.data(for: req)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RemarkableError.uploadFailed("Failed to request upload URL")
        }

        let uploadResponses = try JSONDecoder().decode([UploadResponse].self, from: responseData)
        guard let uploadInfo = uploadResponses.first else {
            throw RemarkableError.uploadFailed("No upload URL returned")
        }

        // Step 2: Upload the document archive
        let archive = try createDocumentArchive(data: data, documentID: documentID, filename: filename, parentFolder: parentFolder)

        var uploadReq = URLRequest(url: URL(string: uploadInfo.blobURLPut)!)
        uploadReq.httpMethod = "PUT"
        uploadReq.setValue("Bearer \(userToken!)", forHTTPHeaderField: "Authorization")
        uploadReq.httpBody = archive

        let (_, uploadResponse) = try await session.data(for: uploadReq)

        guard let uploadHttpResponse = uploadResponse as? HTTPURLResponse,
              uploadHttpResponse.statusCode == 200 else {
            throw RemarkableError.uploadFailed("Failed to upload document data")
        }

        // Step 3: Update status to mark upload complete
        try await updateUploadStatus(documentID: documentID, version: 1)

        logger.info("Uploaded document: \(documentID) (\(filename))")
        return documentID
    }

    public func downloadAnnotations(documentID: String) async throws -> [RemarkableRawAnnotation] {
        try await ensureAuthenticated()

        // Get document info to find the blob URL
        var request = URLRequest(url: URL(string: Self.listDocsURL)!)
        request.setValue("Bearer \(userToken!)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RemarkableError.downloadFailed("Failed to get document list")
        }

        let docs = try JSONDecoder().decode([CloudDocument].self, from: data)
        guard let doc = docs.first(where: { $0.id == documentID }),
              let blobURL = doc.blobURLGet else {
            throw RemarkableError.documentNotFound(documentID)
        }

        // Download and extract the document archive
        let extractedDoc = try await RemarkableDocumentDownloader.shared.downloadDocument(
            documentID: documentID,
            blobURL: blobURL,
            userToken: userToken!
        )

        // Parse annotations from each page
        let pageAnnotations = try await RemarkableDocumentDownloader.shared.parseAnnotations(from: extractedDoc)

        // Convert parsed annotations to RemarkableRawAnnotation array
        var rawAnnotations: [RemarkableRawAnnotation] = []

        for pageAnn in pageAnnotations {
            guard pageAnn.hasStrokes else { continue }

            for layer in pageAnn.rmFile.layers {
                for stroke in layer.strokes {
                    // Skip eraser strokes
                    guard !stroke.isEraser else { continue }

                    // Determine annotation type
                    let annotationType: RemarkableRawAnnotation.AnnotationType = stroke.isHighlight ? .highlight : .ink

                    // Encode stroke data for storage
                    let strokeData = try? JSONEncoder().encode(StrokeDataEnvelope(
                        pen: stroke.pen.rawValue,
                        color: stroke.color.rawValue,
                        width: stroke.width,
                        points: stroke.points.map { StrokePointEnvelope(x: $0.x, y: $0.y, pressure: $0.pressure) }
                    ))

                    let annotation = RemarkableRawAnnotation(
                        id: UUID().uuidString,
                        pageNumber: pageAnn.pageNumber,
                        layerName: layer.name,
                        type: annotationType,
                        strokeData: strokeData,
                        bounds: stroke.bounds,
                        color: stroke.color.hexColor
                    )
                    rawAnnotations.append(annotation)
                }
            }
        }

        logger.info("Downloaded \(rawAnnotations.count) annotations from document \(documentID)")
        return rawAnnotations
    }

    // Helper types for stroke data encoding
    private struct StrokeDataEnvelope: Codable {
        let pen: Int
        let color: Int
        let width: Float
        let points: [StrokePointEnvelope]
    }

    private struct StrokePointEnvelope: Codable {
        let x: Float
        let y: Float
        let pressure: Float
    }

    public func downloadDocument(documentID: String) async throws -> RemarkableDocumentBundle {
        try await ensureAuthenticated()

        // Get document metadata
        let docs = try await listDocuments()
        guard let docInfo = docs.first(where: { $0.id == documentID }) else {
            throw RemarkableError.downloadFailed("Document not found")
        }

        // TODO: Implement full document bundle download
        // This would download the .zip archive and extract PDF + annotations
        throw RemarkableError.downloadFailed("Full document download not yet implemented")
    }

    public func createFolder(name: String, parent: String?) async throws -> String {
        try await ensureAuthenticated()

        let folderID = UUID().uuidString.lowercased()

        let metadata = DocumentMetadata(
            id: folderID,
            type: "CollectionType",
            visibleName: name,
            parent: parent ?? "",
            version: 1,
            modifiedClient: ISO8601DateFormatter().string(from: Date())
        )

        // Request upload URL for folder
        let uploadRequest = UploadRequest(
            id: folderID,
            type: "CollectionType",
            version: 1
        )

        var req = URLRequest(url: URL(string: Self.uploadRequestURL)!)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(userToken!)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode([uploadRequest])

        let (responseData, response) = try await session.data(for: req)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RemarkableError.uploadFailed("Failed to create folder")
        }

        let uploadResponses = try JSONDecoder().decode([UploadResponse].self, from: responseData)
        guard let uploadInfo = uploadResponses.first else {
            throw RemarkableError.uploadFailed("No upload URL for folder")
        }

        // Upload folder metadata
        let metadataData = try JSONEncoder().encode(metadata)
        var uploadReq = URLRequest(url: URL(string: uploadInfo.blobURLPut)!)
        uploadReq.httpMethod = "PUT"
        uploadReq.setValue("Bearer \(userToken!)", forHTTPHeaderField: "Authorization")
        uploadReq.httpBody = metadataData

        let (_, uploadResponse) = try await session.data(for: uploadReq)

        guard let uploadHttpResponse = uploadResponse as? HTTPURLResponse,
              uploadHttpResponse.statusCode == 200 else {
            throw RemarkableError.uploadFailed("Failed to upload folder")
        }

        try await updateUploadStatus(documentID: folderID, version: 1)

        logger.info("Created folder: \(folderID) (\(name))")
        return folderID
    }

    public func deleteDocument(documentID: String) async throws {
        try await ensureAuthenticated()

        let deleteReq = DeleteRequest(id: documentID, version: 1)

        var request = URLRequest(url: URL(string: Self.deleteURL)!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(userToken!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([deleteReq])

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RemarkableError.uploadFailed("Failed to delete document")
        }

        logger.info("Deleted document: \(documentID)")
    }

    public func getDeviceInfo() async throws -> RemarkableDeviceInfo {
        // reMarkable Cloud API doesn't provide device info directly
        // Return placeholder info based on authentication status
        let deviceID = await MainActor.run { settings.deviceID ?? "unknown" }
        let deviceName = await MainActor.run { settings.deviceName ?? "reMarkable" }

        return RemarkableDeviceInfo(
            deviceID: deviceID,
            deviceName: deviceName
        )
    }

    // MARK: - Private Helpers

    private func ensureAuthenticated() async throws {
        if userToken != nil {
            return  // Already authenticated
        }

        // Try to refresh from stored device token
        if let deviceToken = try? await MainActor.run(body: { try settings.retrieveToken() }) {
            userToken = try await refreshUserToken(deviceToken: deviceToken)
        } else {
            throw RemarkableError.notAuthenticated
        }
    }

    private func updateUploadStatus(documentID: String, version: Int) async throws {
        let statusUpdate = UploadStatusUpdate(id: documentID, version: version)

        var request = URLRequest(url: URL(string: Self.updateStatusURL)!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(userToken!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([statusUpdate])

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RemarkableError.uploadFailed("Failed to update status")
        }
    }

    private func createDocumentArchive(data: Data, documentID: String, filename: String, parentFolder: String?) throws -> Data {
        let fileManager = FileManager.default

        // Create temp directory for archive contents
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        // Clean filename for display (remove .pdf extension if present)
        let displayName = filename.hasSuffix(".pdf")
            ? String(filename.dropLast(4))
            : filename

        // 1. Write the PDF file
        let pdfPath = tempDir.appendingPathComponent("\(documentID).pdf")
        try data.write(to: pdfPath)

        // 2. Create .content file (JSON metadata)
        let contentData: [String: Any] = [
            "dummyDocument": false,
            "extraMetadata": [:] as [String: Any],
            "fileType": "pdf",
            "fontName": "",
            "lastOpenedPage": 0,
            "lineHeight": -1,
            "margins": 100,
            "orientation": "portrait",
            "pageCount": 0,  // Will be updated by reMarkable
            "pages": [] as [String],  // Empty initially
            "textAlignment": "left",
            "textScale": 1,
            "transform": [
                "m11": 1, "m12": 0, "m13": 0,
                "m21": 0, "m22": 1, "m23": 0,
                "m31": 0, "m32": 0, "m33": 1
            ]
        ]
        let contentJSON = try JSONSerialization.data(withJSONObject: contentData, options: .prettyPrinted)
        let contentPath = tempDir.appendingPathComponent("\(documentID).content")
        try contentJSON.write(to: contentPath)

        // 3. Create .metadata file (document metadata - stored separately from archive)
        // The metadata is uploaded as part of the update-status call, not in the archive

        // 4. Create .pagedata file (empty for new documents)
        let pagedataPath = tempDir.appendingPathComponent("\(documentID).pagedata")
        try Data().write(to: pagedataPath)

        // 5. Create the ZIP archive using /usr/bin/zip
        let archivePath = tempDir.appendingPathComponent("archive.zip")

        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = [
            "-r",
            archivePath.lastPathComponent,
            "\(documentID).pdf",
            "\(documentID).content",
            "\(documentID).pagedata"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            logger.error("zip command failed: \(errorMessage)")
            throw RemarkableError.uploadFailed("Failed to create archive: \(errorMessage)")
        }

        return try Data(contentsOf: archivePath)
        #else
        // On iOS, we would need a ZIP library - for now, this is macOS-only functionality
        throw RemarkableError.uploadFailed("Document upload is only supported on macOS")
        #endif
    }
}

// MARK: - API Types

private struct DeviceCodeRequest: Codable {
    let code: String
    let deviceDesc: String
    let deviceID: String
}

public struct DeviceCodeResponse: Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: String
}

private struct CloudDocument: Codable {
    let id: String
    let version: Int
    let message: String?
    let success: Bool?
    let blobURLGet: String?
    let blobURLGetExpires: String?
    let modifiedClient: String
    let type: String
    let visibleName: String
    let currentPage: Int?
    let bookmarked: Bool?
    let parent: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case version = "Version"
        case message = "Message"
        case success = "Success"
        case blobURLGet = "BlobURLGet"
        case blobURLGetExpires = "BlobURLGetExpires"
        case modifiedClient = "ModifiedClient"
        case type = "Type"
        case visibleName = "VissibleName"  // Note: API typo
        case currentPage = "CurrentPage"
        case bookmarked = "Bookmarked"
        case parent = "Parent"
    }
}

private struct UploadRequest: Codable {
    let id: String
    let type: String
    let version: Int

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case type = "Type"
        case version = "Version"
    }
}

private struct UploadResponse: Codable {
    let id: String
    let version: Int
    let blobURLPut: String
    let blobURLPutExpires: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case version = "Version"
        case blobURLPut = "BlobURLPut"
        case blobURLPutExpires = "BlobURLPutExpires"
    }
}

private struct UploadStatusUpdate: Codable {
    let id: String
    let version: Int

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case version = "Version"
    }
}

private struct DeleteRequest: Codable {
    let id: String
    let version: Int

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case version = "Version"
    }
}

private struct DocumentMetadata: Codable {
    let id: String
    let type: String
    let visibleName: String
    let parent: String
    let version: Int
    let modifiedClient: String

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case type = "Type"
        case visibleName = "VissibleName"
        case parent = "Parent"
        case version = "Version"
        case modifiedClient = "ModifiedClient"
    }
}
