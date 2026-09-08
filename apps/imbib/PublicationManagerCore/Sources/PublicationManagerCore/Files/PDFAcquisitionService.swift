//
//  PDFAcquisitionService.swift
//  PublicationManagerCore
//
//  ONE way to get a publication's PDF onto disk. Before this, four callers
//  (`PDFTab`, `NotesTab`, `DetachedPDFView`, `AutomationService.downloadPDFs`)
//  each resolved, downloaded, sniffed and imported on their own — three copies
//  of the `%PDF` header check, two different duplicate policies, and an
//  automation route that posted a notification nothing observed. The
//  reMarkable mirror (ADR-025) adds a fifth caller, `EInkSourceFetcher`, which
//  must never open a browser and must not download a paper the PDF tab is
//  already fetching. So: one actor, one in-flight table keyed by publication,
//  one policy switch.
//
//  Pipeline: `lookup` (existing local file? which library?) → `resolve`
//  (`PDFURLResolverV2`) → `fetch` (bytes) → `%PDF` sniff → `importPDF`
//  (`AttachmentManager`, duplicate-aware) → `lookup` again for the display
//  point of the three-point trace (category `pdf-acquire`).
//
//  Every step is an injectable closure (`PDFAcquisitionDependencies`) so the
//  dedupe / cancel / sniff / policy behaviour is unit-tested without a
//  network or a store; `.live` is the production wiring.
//

import Foundation
import OSLog

// MARK: - Policy

/// Who is waiting for the file.
public enum PDFAcquisitionPolicy: String, Sendable {
    /// A person is looking at the pane: user-initiated priority, and a source
    /// that needs a person (paywall, CAPTCHA) is reported as
    /// `requiresUserAction` with the URL the caller may open in a browser.
    case interactive
    /// Nobody is watching (automation, the e-ink source fetcher): utility
    /// priority, and a source that needs a person is "nothing to fetch"
    /// (`nil`), never an error — the caller must not open a browser.
    case background

    var taskPriority: TaskPriority {
        switch self {
        case .interactive: return .userInitiated
        case .background: return .utility
        }
    }
}

// MARK: - Errors

public enum PDFAcquisitionError: LocalizedError, Sendable, Equatable {
    /// The store knows no publication with this id.
    case publicationNotFound(UUID)
    /// Only a person can get past the publisher (paywall / CAPTCHA); the URL
    /// is the page to open. Interactive policy only — background returns nil.
    case requiresUserAction(browserURL: URL, reason: String)
    /// The server answered something other than 200.
    case httpStatus(url: URL, code: Int)
    /// The server answered 200 with zero bytes.
    case emptyDownload(url: URL)
    /// The bytes do not start with `%PDF` — almost always an HTML error page.
    case notAPDF(url: URL, preview: String)
    /// The transport failed (URLError etc.); `message` is its description.
    case downloadFailed(url: URL, message: String)
    /// Writing the file or the linked-file record failed.
    case importFailed(String)
    /// `cancel(publicationID:)` was called, or the awaiting task was cancelled.
    case cancelled

    /// The URL that was tried, for the caller's "open in browser" fallback.
    public var sourceURL: URL? {
        switch self {
        case .requiresUserAction(let url, _), .httpStatus(let url, _), .emptyDownload(let url),
             .notAPDF(let url, _), .downloadFailed(let url, _):
            return url
        case .publicationNotFound, .importFailed, .cancelled:
            return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .publicationNotFound(let id):
            return "No publication with id \(id.uuidString)"
        case .requiresUserAction(_, let reason):
            return reason
        case .httpStatus(let url, let code):
            return "HTTP \(code) from \(url.host ?? url.absoluteString)"
        case .emptyDownload(let url):
            return "Downloaded empty file from \(url.host ?? url.absoluteString)"
        case .notAPDF(let url, _):
            return "Downloaded file from \(url.host ?? url.absoluteString) is not a valid PDF"
        case .downloadFailed(_, let message):
            return "Download failed: \(message)"
        case .importFailed(let message):
            return "PDF import failed: \(message)"
        case .cancelled:
            return "PDF download cancelled"
        }
    }
}

// MARK: - Subject

/// What the service needs to know about a publication before fetching.
public struct PDFAcquisitionSubject: Sendable, Equatable {
    public let publicationID: UUID
    public let citeKey: String
    /// The library the file is imported into (nil → the default library).
    public let libraryID: UUID?
    /// An existing, materialised local PDF, if any.
    public let localPDF: URL?

    public init(publicationID: UUID, citeKey: String, libraryID: UUID? = nil, localPDF: URL? = nil) {
        self.publicationID = publicationID
        self.citeKey = citeKey
        self.libraryID = libraryID
        self.localPDF = localPDF
    }
}

// MARK: - Dependencies

/// The four steps, as closures. `.live` is production; tests inject fakes.
public struct PDFAcquisitionDependencies: Sendable {
    /// The publication's current state, or nil when the store does not know it.
    public var lookup: @MainActor @Sendable (UUID) -> PDFAcquisitionSubject?
    /// Where the PDF can be fetched from (`PDFURLResolverV2`).
    public var resolve: @Sendable (UUID, PDFAcquisitionPolicy) async -> PDFAccessStatus
    /// The bytes at a URL; throws `PDFAcquisitionError` for HTTP / transport failures.
    public var fetch: @Sendable (URL) async throws -> Data
    /// Store the bytes as the publication's PDF (duplicate-aware); returns the local file URL.
    public var importPDF: @MainActor @Sendable (Data, PDFAcquisitionSubject) throws -> URL

    public init(
        lookup: @escaping @MainActor @Sendable (UUID) -> PDFAcquisitionSubject?,
        resolve: @escaping @Sendable (UUID, PDFAcquisitionPolicy) async -> PDFAccessStatus,
        fetch: @escaping @Sendable (URL) async throws -> Data,
        importPDF: @escaping @MainActor @Sendable (Data, PDFAcquisitionSubject) throws -> URL
    ) {
        self.lookup = lookup
        self.resolve = resolve
        self.fetch = fetch
        self.importPDF = importPDF
    }

    /// Production wiring: `RustStoreAdapter`, `PDFURLResolverV2`, `URLSession`, `AttachmentManager`.
    public static let live = PDFAcquisitionDependencies(
        lookup: { id in
            guard let pub = RustStoreAdapter.shared.getPublicationDetail(id: id) else { return nil }
            let libraryID = pub.libraryIDs.first
            let local = pub.linkedFiles.first { $0.isPDF && $0.isLocallyMaterialized }
                ?? pub.linkedFiles.first { $0.isPDF }
            let url = local.flatMap { AttachmentManager.shared.resolveURL(for: $0, in: libraryID) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            return PDFAcquisitionSubject(publicationID: id, citeKey: pub.citeKey, libraryID: libraryID, localPDF: url)
        },
        resolve: { id, _ in
            guard let pub = await MainActor.run(body: { RustStoreAdapter.shared.getPublicationDetail(id: id) }) else {
                return .unavailable(reason: .noPDFFound)
            }
            let settings = await PDFSettingsStore.shared.settings
            return await PDFURLResolverV2.shared.resolve(for: pub, settings: settings)
        },
        fetch: { url in
            try await AttachmentManager.fetchPDFBytes(from: url)
        },
        importPDF: { data, subject in
            let manager = AttachmentManager.shared
            let linked: LinkedFileModel
            switch manager.checkForDuplicate(data: data, in: subject.publicationID) {
            case .duplicate(let existing, let hash) where existing.sha256 == hash:
                Logger.files.infoCapture(
                    "[pdf-acquire] \(subject.citeKey): bytes match existing \(existing.filename), reusing",
                    category: "pdf-acquire")
                linked = existing
            case .duplicate(_, let hash), .noDuplicate(let hash):
                linked = try manager.importPDF(data: data, for: subject.publicationID, in: subject.libraryID, precomputedHash: hash)
            }
            guard let url = manager.resolveURL(for: linked, in: subject.libraryID) else {
                throw PDFAcquisitionError.importFailed("linked file \(linked.filename) has no resolvable path")
            }
            return url
        }
    )
}

// MARK: - Service

public actor PDFAcquisitionService {

    public static let shared = PDFAcquisitionService()

    private let deps: PDFAcquisitionDependencies
    /// One task per publication; a second caller for the same id awaits it.
    private var inFlight: [UUID: Task<URL?, Error>] = [:]

    public init(dependencies: PDFAcquisitionDependencies = .live) {
        self.deps = dependencies
    }

    /// Publications with a download in progress right now.
    public var inFlightPublicationIDs: Set<UUID> { Set(inFlight.keys) }

    /// Get the publication's PDF onto disk and return its local URL.
    ///
    /// - Returns: the local file (existing or freshly imported), or `nil`
    ///   when no direct source exists — for `.background` that includes
    ///   sources a person would have to unlock.
    /// - Throws: `PDFAcquisitionError`; `.interactive` callers get
    ///   `.requiresUserAction(browserURL:)` where a browser would help.
    public func acquire(publicationID: UUID, policy: PDFAcquisitionPolicy) async throws -> URL? {
        if let existing = inFlight[publicationID] {
            Logger.files.infoCapture(
                "[pdf-acquire] \(publicationID) requested (\(policy.rawValue)): joining the download already in flight",
                category: "pdf-acquire")
            return try await Self.value(of: existing)
        }

        let deps = self.deps
        let task = Task.detached(priority: policy.taskPriority) {
            try await Self.run(publicationID: publicationID, policy: policy, deps: deps)
        }
        inFlight[publicationID] = task
        defer { inFlight[publicationID] = nil }
        return try await Self.value(of: task)
    }

    /// Cancel the download in flight for a publication, if any. Every caller
    /// awaiting it receives `PDFAcquisitionError.cancelled`.
    public func cancel(publicationID: UUID) {
        guard let task = inFlight[publicationID] else { return }
        Logger.files.infoCapture("[pdf-acquire] \(publicationID) cancelled", category: "pdf-acquire")
        task.cancel()
    }

    // MARK: - Pipeline

    private static func value(of task: Task<URL?, Error>) async throws -> URL? {
        do {
            return try await task.value
        } catch is CancellationError {
            throw PDFAcquisitionError.cancelled
        }
    }

    private static func run(
        publicationID: UUID,
        policy: PDFAcquisitionPolicy,
        deps: PDFAcquisitionDependencies
    ) async throws -> URL? {
        // 1. Mutation point: what was asked.
        guard let subject = await deps.lookup(publicationID) else {
            Logger.files.warningCapture(
                "[pdf-acquire] \(publicationID) requested (\(policy.rawValue)): publication not found",
                category: "pdf-acquire")
            throw PDFAcquisitionError.publicationNotFound(publicationID)
        }
        Logger.files.infoCapture(
            "[pdf-acquire] \(subject.citeKey) requested (\(policy.rawValue)) library=\(subject.libraryID?.uuidString ?? "default")",
            category: "pdf-acquire")

        if let local = subject.localPDF {
            Logger.files.infoCapture(
                "[pdf-acquire] \(subject.citeKey): already local at \(local.lastPathComponent)",
                category: "pdf-acquire")
            return local
        }

        try Task.checkCancellation()
        let status = await deps.resolve(publicationID, policy)
        try Task.checkCancellation()

        guard let url = status.pdfURL else {
            if let browserURL = status.browserURL {
                switch policy {
                case .interactive:
                    Logger.files.infoCapture(
                        "[pdf-acquire] \(subject.citeKey): \(status.displayDescription) — browser at \(browserURL.absoluteString)",
                        category: "pdf-acquire")
                    throw PDFAcquisitionError.requiresUserAction(browserURL: browserURL, reason: status.displayDescription)
                case .background:
                    Logger.files.infoCapture(
                        "[pdf-acquire] \(subject.citeKey): \(status.displayDescription) — needs a person, skipping (background)",
                        category: "pdf-acquire")
                    return nil
                }
            }
            Logger.files.infoCapture(
                "[pdf-acquire] \(subject.citeKey): no source (\(status.displayDescription))",
                category: "pdf-acquire")
            return nil
        }

        Logger.files.infoCapture(
            "[pdf-acquire] \(subject.citeKey): fetching \(url.absoluteString) (\(status.displayDescription))",
            category: "pdf-acquire")
        let data: Data
        do {
            data = try await deps.fetch(url)
        } catch let error as PDFAcquisitionError {
            Logger.files.warningCapture("[pdf-acquire] \(subject.citeKey): \(error.localizedDescription)", category: "pdf-acquire")
            throw error
        } catch is CancellationError {
            throw PDFAcquisitionError.cancelled
        } catch {
            Logger.files.warningCapture(
                "[pdf-acquire] \(subject.citeKey): download failed: \(error.localizedDescription)",
                category: "pdf-acquire")
            throw PDFAcquisitionError.downloadFailed(url: url, message: error.localizedDescription)
        }
        try Task.checkCancellation()

        guard Self.hasPDFMagic(data) else {
            let preview = Self.preview(of: data)
            Logger.files.warningCapture(
                "[pdf-acquire] \(subject.citeKey): \(data.count) bytes from \(url.host ?? "?") are not a PDF; starts with \"\(preview)\"",
                category: "pdf-acquire")
            throw PDFAcquisitionError.notAPDF(url: url, preview: preview)
        }

        // 2. Save point: the linked file.
        let saved: URL
        do {
            saved = try await deps.importPDF(data, subject)
        } catch let error as PDFAcquisitionError {
            throw error
        } catch {
            Logger.files.errorCapture(
                "[pdf-acquire] \(subject.citeKey): import failed: \(error.localizedDescription)",
                category: "pdf-acquire")
            throw PDFAcquisitionError.importFailed(error.localizedDescription)
        }
        Logger.files.infoCapture(
            "[pdf-acquire] \(subject.citeKey): saved \(data.count) bytes as \(saved.lastPathComponent)",
            category: "pdf-acquire")

        // 3. Display point: does the store now report a local PDF?
        let after = await deps.lookup(publicationID)
        if let local = after?.localPDF {
            Logger.files.infoCapture(
                "[pdf-acquire] \(subject.citeKey): display — store reports local PDF \(local.lastPathComponent)",
                category: "pdf-acquire")
        } else {
            Logger.files.warningCapture(
                "[pdf-acquire] \(subject.citeKey): display — file saved but the store reports NO local PDF",
                category: "pdf-acquire")
        }
        return saved
    }

    // MARK: - PDF sniffing

    /// `%PDF` — the four bytes every PDF starts with. An HTML error page
    /// served with a 200 is the usual failure this catches.
    public static let pdfMagic = Data([0x25, 0x50, 0x44, 0x46])

    public static func hasPDFMagic(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual(pdfMagic)
    }

    /// The first bytes as printable text, for the log line and the error.
    static func preview(of data: Data, limit: Int = 64) -> String {
        let head = data.prefix(limit)
        let text = String(decoding: head, as: UTF8.self)
        return text.map { $0.isASCII && !$0.isNewline ? String($0) : "·" }.joined()
    }
}
