//
//  ZenodoDepositTarget.swift
//  ImpressDeposit
//
//  Zenodo conformance to DepositTarget. Two API roots — production
//  (zenodo.org) and sandbox (sandbox.zenodo.org). Caller picks via init.
//
//  Workflow:
//    1. POST /api/deposit/depositions               → record id, bucket URL
//    2. PUT  {bucket}/{filename}  (body = file)     → upload
//    3. PUT  /api/deposit/depositions/{id}           → record metadata
//    4. POST /api/deposit/depositions/{id}/actions/publish → mint DOI
//
//  Per ADR-0014 D58.
//

import Foundation

public struct ZenodoDepositTarget: DepositTarget {

    public static let productionRoot = URL(string: "https://zenodo.org/api")!
    public static let sandboxRoot = URL(string: "https://sandbox.zenodo.org/api")!

    public let id: String = "zenodo"
    public let displayName: String = "Zenodo"
    public let credentialRequirement: DepositCredentialRequirement = .apiToken(
        label: "Personal Access Token",
        helpURL: URL(string: "https://zenodo.org/account/settings/applications/tokens/new/")
    )
    public let rateLimit: DepositRateLimit = DepositRateLimit(requestsPerHour: 5000)

    /// API base URL — production or sandbox.
    public let apiRoot: URL

    /// Personal Access Token. Retrieved from the keychain by the caller.
    public let token: String

    private let session: URLSession

    public init(
        apiRoot: URL = ZenodoDepositTarget.productionRoot,
        token: String,
        session: URLSession = .shared
    ) {
        self.apiRoot = apiRoot
        self.token = token
        self.session = session
    }

    public func deposit(
        artifact: DepositArtifact,
        progress: @Sendable @escaping (UploadProgress) async -> Void
    ) async throws -> DepositResult {
        guard !token.isEmpty else {
            throw DepositError.missingCredential(target: displayName)
        }

        await progress(UploadProgress(phase: .creatingRecord))
        let record = try await createDeposition(artifact: artifact)

        await progress(UploadProgress(phase: .uploading, bytesSent: 0, totalBytes: record.expectedBytes))
        try await uploadFile(
            to: record.bucketURL,
            file: artifact.file,
            progress: progress,
            totalBytes: record.expectedBytes
        )

        try await updateMetadata(recordID: record.id, artifact: artifact)

        await progress(UploadProgress(phase: .publishing))
        let published = try await publish(recordID: record.id)

        await progress(UploadProgress(phase: .completed, bytesSent: record.expectedBytes, totalBytes: record.expectedBytes))
        return published
    }

    // MARK: - Workflow steps

    private struct CreatedRecord {
        let id: String
        let bucketURL: URL
        let expectedBytes: Int64
    }

    private func createDeposition(artifact: DepositArtifact) async throws -> CreatedRecord {
        let url = apiRoot.appendingPathComponent("deposit/depositions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        try Self.checkHTTP(response, body: data)

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DepositError.httpError(statusCode: -1, body: "Zenodo create-deposition response was not a JSON object")
        }
        guard let idAny = obj["id"], let bucketStr = (obj["links"] as? [String: Any])?["bucket"] as? String,
              let bucketURL = URL(string: bucketStr) else {
            throw DepositError.httpError(statusCode: -1, body: "Zenodo create-deposition missing id / bucket links")
        }
        let id = (idAny as? Int).map(String.init) ?? (idAny as? String ?? "")
        let expectedBytes = artifact.file.byteSize ?? 0
        return CreatedRecord(id: id, bucketURL: bucketURL, expectedBytes: expectedBytes)
    }

    private func uploadFile(
        to bucketURL: URL,
        file: DepositFile,
        progress: @Sendable @escaping (UploadProgress) async -> Void,
        totalBytes: Int64
    ) async throws {
        let target = bucketURL.appendingPathComponent(file.filename)
        var req = URLRequest(url: target)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        // Zenodo's bucket API accepts the file as a raw PUT body. We use
        // URLSession.upload(for:fromFile:) when a file URL is available so
        // multi-GB uploads stream from disk instead of loading into RAM.
        let (data, response): (Data, URLResponse)
        switch file.body {
        case .fileURL(let localURL):
            (data, response) = try await session.upload(for: req, fromFile: localURL)
        case .data(let bytes, let mimeType):
            req.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            (data, response) = try await session.upload(for: req, from: bytes)
        }

        try Self.checkHTTP(response, body: data)

        // Approximate progress reporting — URLSession upload's per-byte
        // delegate isn't wired here yet (a follow-up adds it). For now we
        // signal "uploaded" at completion.
        await progress(UploadProgress(phase: .uploading, bytesSent: totalBytes, totalBytes: totalBytes))
    }

    private func updateMetadata(recordID: String, artifact: DepositArtifact) async throws {
        let url = apiRoot.appendingPathComponent("deposit/depositions/\(recordID)")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        var creators: [[String: String]] = []
        for author in artifact.authors {
            var creator: [String: String] = ["name": author.name]
            if let orcid = author.orcid { creator["orcid"] = orcid }
            if let aff = author.affiliation { creator["affiliation"] = aff }
            creators.append(creator)
        }

        var metadata: [String: Any] = [
            "title": artifact.title,
            "upload_type": "publication",
            "description": artifact.description.isEmpty ? artifact.title : artifact.description,
            "creators": creators.isEmpty ? [["name": "Unknown"]] : creators
        ]
        if let license = artifact.license {
            metadata["license"] = license.lowercased()
        }
        if !artifact.keywords.isEmpty {
            metadata["keywords"] = artifact.keywords
        }
        if let community = artifact.community {
            metadata["communities"] = [["identifier": community]]
        }

        let body: [String: Any] = ["metadata": metadata]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        try Self.checkHTTP(response, body: data)
    }

    private func publish(recordID: String) async throws -> DepositResult {
        let url = apiRoot
            .appendingPathComponent("deposit/depositions/\(recordID)/actions/publish")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: req)
        try Self.checkHTTP(response, body: data)

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DepositError.httpError(statusCode: -1, body: "Zenodo publish response was not a JSON object")
        }
        guard let doi = obj["doi"] as? String, !doi.isEmpty else {
            throw DepositError.noDOIReturned
        }
        let landingURL: URL
        if let links = obj["links"] as? [String: Any],
           let urlStr = (links["record_html"] ?? links["html"] ?? links["self_html"]) as? String,
           let url = URL(string: urlStr) {
            landingURL = url
        } else {
            landingURL = URL(string: "https://doi.org/\(doi)")!
        }
        return DepositResult(doi: doi, repositoryURL: landingURL, recordID: recordID)
    }

    // MARK: - Helpers

    private static func checkHTTP(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if 200..<300 ~= http.statusCode { return }
        let bodyStr = String(data: body.prefix(1024), encoding: .utf8)
        if http.statusCode == 429 {
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { TimeInterval($0) }
            throw DepositError.rateLimited(retryAfter: retryAfter)
        }
        throw DepositError.httpError(statusCode: http.statusCode, body: bodyStr)
    }
}

private extension DepositFile {
    var byteSize: Int64? {
        switch body {
        case .fileURL(let url):
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }
        case .data(let data, _):
            return Int64(data.count)
        }
    }
}
