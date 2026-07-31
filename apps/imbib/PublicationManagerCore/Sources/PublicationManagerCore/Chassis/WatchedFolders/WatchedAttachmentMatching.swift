// Chassis WIRING file — CROSS-PLATFORM (macOS + iOS). ADR-0023 W5.
//
//  WatchedAttachmentMatching.swift
//  PublicationManagerCore
//
//  ── PDFs beside a watched `.bib`, attached to the entries they belong to ────
//
//      FolderWatchService                 one folder, one filter, one gather —
//            │                            `.bib` AND `.pdf`, because the
//            │                            filter is built from the capability's
//            ▼                            `discoveryExtensions` (the UNION)
//      watchedImportDiscovered            a `watched-file` row per file, hashed,
//            │                            swept, flagged `missing` when it goes
//            ▼
//      the W2 loop, for `.bib` only       PDFs are NOT handed to `produceRows`:
//            │                            a PDF fans out to nothing
//            ▼
//      imbib_core::attachments            ← THIS file's Rust half: entries ×
//            │  match_attachments            candidate PDFs → verdicts
//            ▼
//      automatic → attach                 ambiguous → OFFER
//
//  ── The three things this file is careful about ─────────────────────────────
//
//  **1. It never attaches an ambiguous match.** The matcher returns a verdict
//  per pairing and only `.automatic` is acted on; everything else becomes a
//  `WatchedAttachmentOffer` for the review surface. The thresholds live in
//  Rust (`AttachmentThresholds`) and are read, not restated — a UI that
//  explained a number this file spelled would be a second copy of it.
//
//  **2. It is idempotent, twice over.** A re-scan must not double-attach, and
//  two things guarantee it independently: the coordinator only runs the matcher
//  when discovery reports the folder's contents actually moved, and the attach
//  step skips any PDF the publication already links. The second is the one that
//  matters, because it holds even if the first is wrong — and it is checked
//  against the store, not against remembered state.
//
//  **3. It attaches reference-in-place.** `AttachmentManager.linkExistingPDF`
//  and not `importAttachment`: D4's rule is that the watcher never copies and
//  the file stays the user's. The path stored on the `imbib/linked-file` row is
//  the PDF's ABSOLUTE path, which is why `resolveURL` grew an absolute branch —
//  every other linked file in imbib lives inside the library container, and a
//  watched PDF is the one that does not.
//
//  ── Why the role marker is derived and not stored ───────────────────────────
//
//  ADR-0023 W5 had a choice: a `role` column on `watched-file@1.0.0`, or ask
//  the capability. The schema's own test (`folder_does_not_restate_the
//  _capability`) already refuses to let a watched-folder row carry the
//  extensions or the ingest unit, on the grounds that the `FileDiscovery
//  Capability` is the authority and a column would be a second one. A per-file
//  `role` is that same restatement one row down: it would say "this is a PDF",
//  which the path already says and the declaration already interprets. So the
//  marker is `FileDiscoveryCapability.ingestUnit(forFileName:)`, computed, and
//  the store schema is untouched — no migration, and rows written by W2 read
//  correctly under W5 with no backfill.
//

import Foundation
import ImbibRustCore
import ImpressKit
import OSLog

// MARK: - The offer

/// One PDF the watcher could not attach on its own, and what it thinks.
///
/// A data value with no SwiftUI in it, the same shape `WatchedFileOffer` (W4)
/// has and for the same reason: the pane consumes it, nothing here consumes
/// the pane.
public struct WatchedAttachmentOffer: Identifiable, Hashable, Sendable {

    /// One entry this PDF might belong to.
    public struct Candidate: Identifiable, Hashable, Sendable {
        /// The publication's id.
        public let id: UUID
        public let citeKey: String
        public let title: String
        public let confidence: Double
        /// Why the matcher thinks so, in words the row renders.
        public let reason: String

        public init(id: UUID, citeKey: String, title: String, confidence: Double, reason: String) {
            self.id = id
            self.citeKey = citeKey
            self.title = title
            self.confidence = confidence
            self.reason = reason
        }

        /// `92%`. Rendered rather than the raw double, because a confidence is
        /// a judgement and a human reads it as a percentage.
        public var confidenceLabel: String {
            "\(Int((confidence * 100).rounded()))%"
        }
    }

    /// The PDF's absolute path — also this offer's identity, because one PDF
    /// yields one offer.
    public let id: String
    /// Candidates, best first. **Empty means the PDF matched nothing**, which
    /// is a legitimate and common state, not a failure.
    public let candidates: [Candidate]

    public init(path: String, candidates: [Candidate]) {
        self.id = path
        self.candidates = candidates
    }

    public var path: String { id }
    public var url: URL { URL(fileURLWithPath: path) }
    public var fileName: String { (path as NSString).lastPathComponent }

    /// True when no entry claimed this PDF at all.
    public var isUnmatched: Bool { candidates.isEmpty }

    /// The secondary line. Never empty — `WatchedFolderRowState.statusLine`'s
    /// rule: a field that is blank when healthy trains the eye to skip it.
    public var statusLine: String {
        guard let best = candidates.first else {
            return "No entry in this folder's bibliography matches this file"
        }
        if candidates.count == 1 {
            return "Possibly \(best.citeKey) — \(best.reason)"
        }
        return "\(candidates.count) possible entries — \(best.citeKey) is the closest at "
            + best.confidenceLabel
    }

    public var systemImage: String { isUnmatched ? "doc.questionmark" : "questionmark.folder" }
}

// MARK: - What one pass did

/// The outcome of one folder's attachment pass, for logs and for tests.
public struct WatchedAttachmentPass: Equatable, Sendable {
    /// PDFs attached without asking (unique, high confidence).
    public var attached: Int = 0
    /// Attachments that were already there — the idempotency count. A re-scan
    /// of an unchanged folder makes this equal to `attached` on the first pass
    /// and leaves `attached` at zero.
    public var alreadyAttached: Int = 0
    /// PDFs surfaced for review.
    public var offered: Int = 0
    /// PDFs no entry claimed.
    public var unmatched: Int = 0
    /// Attached PDFs whose file has vanished. Flagged, never detached (D4).
    public var missing: Int = 0

    public var isEmpty: Bool {
        attached == 0 && alreadyAttached == 0 && offered == 0 && unmatched == 0 && missing == 0
    }
}

// MARK: - The store verbs this needs from its host

/// The attachment side of `WatchedFolderImportHooks`, as closures.
///
/// Separate from `WatchedFolderImportHooks` on purpose: those hooks are the
/// PER-KIND fan-out (W4), one closure that every watched kind supplies. This is
/// imbib's alone — no other kind has an attachment unit — so bolting it onto
/// the shared struct would have put four `nil`s in three other apps' wiring.
@MainActor
public struct WatchedAttachmentHooks: Sendable {

    /// The entries one bibliography file produced, as the matcher wants them.
    public var entries: (_ publicationIDs: [UUID]) -> [AttachmentEntry]

    /// The absolute paths already linked to a publication — the idempotency
    /// check, read from the STORE rather than from anything remembered.
    public var linkedPaths: (_ publicationID: UUID) -> Set<String>

    /// Attach one PDF, reference-in-place. Returns false if the store refused.
    public var attach: (_ path: String, _ publicationID: UUID) -> Bool

    /// The library attachments are resolved against. `nil` is legal — the
    /// absolute-path branch of `resolveURL` does not need one.
    public var libraryID: () -> UUID?

    public init(
        entries: @escaping (_ publicationIDs: [UUID]) -> [AttachmentEntry],
        linkedPaths: @escaping (_ publicationID: UUID) -> Set<String>,
        attach: @escaping (_ path: String, _ publicationID: UUID) -> Bool,
        libraryID: @escaping () -> UUID? = { nil }
    ) {
        self.entries = entries
        self.linkedPaths = linkedPaths
        self.attach = attach
        self.libraryID = libraryID
    }

    /// imbib's real path.
    ///
    /// `linkExistingPDF` and NOT `importAttachment`: the second copies the file
    /// into the library's `Papers/` directory, and ADR-0023 D4 says the watcher
    /// never writes user files and the file stays the user's. `linkExistingPDF`
    /// has existed since imbib ADR-004 and had no caller until now; W5 is what
    /// it was for.
    public static var live: WatchedAttachmentHooks {
        WatchedAttachmentHooks(
            entries: { ids in
                let store = RustStoreAdapter.shared
                return ids.compactMap { id in
                    guard let detail = store.getPublicationDetail(id: id) else { return nil }
                    return AttachmentEntry(publication: detail)
                }
            },
            linkedPaths: { id in
                Set(
                    RustStoreAdapter.shared.listLinkedFiles(publicationId: id)
                        .compactMap(\.relativePath))
            },
            attach: { path, id in
                AttachmentManager.shared.linkExistingPDF(
                    relativePath: path,
                    for: id,
                    in: RustStoreAdapter.shared.getDefaultLibrary()?.id) != nil
            },
            libraryID: { RustStoreAdapter.shared.getDefaultLibrary()?.id })
    }
}

// MARK: - Publication → matcher input

public extension AttachmentEntry {

    /// One publication, as the Rust matcher's candidate entry.
    ///
    /// Every field is handed over rather than a chosen few: the matcher reads
    /// `title`, `author`, `year`, every `Bdsk-File-*` and the plain
    /// `file`/`local-file` forms, and a caller pre-selecting them would be a
    /// caller deciding which signals exist (its own doc comment says so).
    init(publication: PublicationModel) {
        var fields = publication.fields.map { BibTeXField(key: $0.key, value: $0.value) }

        // `author` is a first-class relation on a publication row, not a
        // payload field, so the fields bag usually has no `author` at all —
        // and without one the matcher loses both the surname signal and
        // imbib's own `Author_Year_Title` name. Re-materialising it in the
        // BibTeX spelling ("Family, Given and Family, Given") is what
        // `publication_to_bibtex` does one layer down, and using the same
        // spelling is what makes `split_authors` work on it.
        if publication.fields["author"] == nil, !publication.authors.isEmpty {
            let joined = publication.authors
                .map { author in
                    let given = author.givenName ?? ""
                    return given.isEmpty
                        ? author.familyName
                        : "\(author.familyName), \(given)"
                }
                .joined(separator: " and ")
            fields.append(BibTeXField(key: "author", value: joined))
        }

        // ── The `Bdsk-File-*` fields do not survive into `fields` ───────────
        //
        // And without this they never reach the matcher, which would leave its
        // MOST credible signal dead in the live path while passing every unit
        // test that hands the matcher a field bag directly.
        //
        // The chain: `bibtex_entry_to_publication` has a catch-all that puts
        // any unrecognised field into `extra_fields`, which is persisted as a
        // nested payload OBJECT — and `item_to_publication_detail` flattens
        // only TOP-LEVEL `Value::String`/`Value::Int` payload entries into
        // `fields`. So a publication imported from a BibDesk `.bib` carries its
        // `Bdsk-File-1` faithfully in the store and shows none of it here.
        //
        // `raw_bibtex` IS a top-level string, so the entry's original text is
        // right there. Reading the declaration back out of it is the narrow fix:
        // it needs no schema change, no FFI addition and no re-flattening of a
        // payload half the app reads. It is applied only when the flat bag has
        // no file field of its own, so a publication that DOES surface one is
        // untouched.
        let declaresFile = fields.contains {
            let key = $0.key.lowercased()
            return key.hasPrefix("bdsk-file-") || key == "file" || key == "local-file"
        }
        if !declaresFile, let raw = publication.rawBibTeX, !raw.isEmpty {
            fields.append(contentsOf: Self.fileFields(inRawBibTeX: raw))
        }

        self.init(
            id: publication.id.uuidString.lowercased(),
            citeKey: publication.citeKey,
            fields: fields)
    }

    /// The file-declaring fields of an entry's original BibTeX text.
    ///
    /// Parsed through imbib's real parser rather than scanned with a regex: a
    /// `Bdsk-File-1` value is base64 that can contain anything, braces
    /// included, and a hand-rolled scan of it is a second BibTeX parser with
    /// worse coverage. `try?` because this is an enrichment — an entry whose
    /// raw text will not parse still matches on every other signal.
    private static func fileFields(inRawBibTeX raw: String) -> [BibTeXField] {
        guard let entry = try? UnifiedFormatConverter.parseBibTeX(raw).first else { return [] }
        // Mapped rather than passed through: the parser's `BibTeXField` and the
        // matcher's are two types with the same shape from two modules, and a
        // `filter` alone would be trying to return one as the other.
        return entry.fields.compactMap { field in
            let key = field.key.lowercased()
            guard key.hasPrefix("bdsk-file-") || key == "file" || key == "local-file" else {
                return nil
            }
            return BibTeXField(key: field.key, value: field.value)
        }
    }
}

// MARK: - The pass

@MainActor
extension WatchedFolderIngestCoordinator {

    /// Match this folder's PDFs against the entries its `.bib` files produced,
    /// attach what is certain, and offer the rest.
    ///
    /// Called at the END of a scan, not per file, because the question is about
    /// the folder as a whole: "is this PDF unique?" cannot be answered while
    /// half the entries are still being imported. That is also what makes the
    /// ambiguity margin meaningful — a PDF matching two entries is only visible
    /// once both entries exist.
    @discardableResult
    func matchAttachments(in folderID: WatchedFolderID) -> WatchedAttachmentPass {
        guard let hooks = attachmentHooks else { return WatchedAttachmentPass() }
        guard let capability = BuiltinRecordKinds.fileDiscovery(forKindScope: kindScope),
            !capability.attachmentExtensions.isEmpty
        else {
            return WatchedAttachmentPass()
        }

        // PAGED, not `files(in:)`. That convenience takes the store's default
        // page (200 rows), which is right for a sidebar list and wrong here: a
        // folder with 300 files would match the first 200 and say nothing about
        // the rest — a silently partial answer, which is the failure mode this
        // whole campaign keeps finding. `allFiles` reads to the folder's
        // reported total and logs if it cannot.
        let rows = allFiles(in: folderID)
        var bibliographyRows: [WatchedFileRecord] = []
        var attachmentRows: [WatchedFileRecord] = []
        for row in rows {
            // The derived role marker. Nothing is stored; the path and the
            // declaration answer together.
            switch capability.ingestUnit(forFileName: row.path) {
            case .attachment: attachmentRows.append(row)
            case .entries, .file: bibliographyRows.append(row)
            case nil: continue
            }
        }

        // The early-out every user who watches no PDFs takes. Reading the
        // folder's rows is already done above (the sidebar needs them anyway);
        // everything expensive is below this line.
        guard !attachmentRows.isEmpty else { return WatchedAttachmentPass() }

        var pass = WatchedAttachmentPass()

        // ── The missing discipline (ADR-0023 D5/W5 point 5) ─────────────────
        //
        // A PDF that vanished keeps its `watched-file` row (W0's sweep already
        // marked it `missing`) AND keeps its attachment. Detaching would delete
        // a fact the user established; the row says the file is gone, which is
        // the honest thing and the one the PDF tab already renders
        // (`PublicationPDFAvailability.fileMissing`).
        let missingPaths = Set(attachmentRows.filter(\.isMissing).map(\.path))
        pass.missing = missingPaths.count
        if !missingPaths.isEmpty {
            Logger.files.warningCapture(
                "watched folder \(folderID.storageKey): \(missingPaths.count) attached PDF(s) are "
                    + "gone from disk — rows and attachments KEPT and flagged, nothing detached",
                category: "watched-folders")
        }

        let candidatePaths = attachmentRows.filter { !$0.isMissing }.map(\.path)
        guard !candidatePaths.isEmpty else {
            attachmentOffers[folderID] = []
            return pass
        }

        // Entries: every publication this folder's bibliography files produced.
        // A publication two files both produced appears once — it is one row,
        // and offering it twice would put the same choice on screen twice.
        var seen = Set<UUID>()
        var producedIDs: [UUID] = []
        for row in bibliographyRows {
            for id in row.producedPublicationIDs where seen.insert(id).inserted {
                producedIDs.append(id)
            }
        }
        let entries = hooks.entries(producedIDs)
        guard !entries.isEmpty else {
            // PDFs but no imported entries yet: every PDF is unclaimed, and
            // saying so beats saying nothing.
            attachmentOffers[folderID] = candidatePaths.map {
                WatchedAttachmentOffer(path: $0, candidates: [])
            }
            pass.unmatched = candidatePaths.count
            return pass
        }

        // ── The Rust half (ADR-0023 D5) ────────────────────────────────────
        let report = matchAttachments(entries: entries, pdfPaths: candidatePaths)

        // Titles for the offer rows, resolved once.
        var titleByID: [String: String] = [:]
        var citeKeyByID: [String: String] = [:]
        for entry in entries {
            citeKeyByID[entry.id] = entry.citeKey
            titleByID[entry.id] =
                entry.fields.first { $0.key.lowercased() == "title" }?.value ?? entry.citeKey
        }

        var offersByPath: [String: [WatchedAttachmentOffer.Candidate]] = [:]

        for match in report.matches {
            guard let publicationID = UUID(uuidString: match.entryId) else { continue }
            switch match.verdict {
            case .automatic:
                // The idempotency check, against the STORE. It holds on a
                // re-scan even if the coordinator's "did anything move?"
                // reasoning is wrong, which is the only kind of guarantee
                // worth having here — a double attach is a duplicate row in a
                // user's library.
                if hooks.linkedPaths(publicationID).contains(match.pdfPath) {
                    pass.alreadyAttached += 1
                    continue
                }
                if hooks.attach(match.pdfPath, publicationID) {
                    pass.attached += 1
                    Logger.files.infoCapture(
                        "watched folder \(folderID.storageKey): attached "
                            + "\((match.pdfPath as NSString).lastPathComponent) to "
                            + "\(match.citeKey) — \(match.reason) "
                            + "(\(Int((match.confidence * 100).rounded()))%)",
                        category: "watched-folders")
                } else {
                    Logger.files.warningCapture(
                        "watched folder \(folderID.storageKey): the store refused to link "
                            + "\(match.pdfPath) to \(match.citeKey)",
                        category: "watched-folders")
                }

            case .offer:
                // Never attached. This is the W4 offer pattern: the app is
                // OFFERING something, not reporting something it already did.
                offersByPath[match.pdfPath, default: []].append(
                    WatchedAttachmentOffer.Candidate(
                        id: publicationID,
                        citeKey: match.citeKey,
                        title: titleByID[match.entryId] ?? match.citeKey,
                        confidence: match.confidence,
                        reason: match.reason))
            }
        }

        var offers = offersByPath.map { WatchedAttachmentOffer(path: $0.key, candidates: $0.value) }
        offers.append(
            contentsOf: report.unmatchedPdfs.map { WatchedAttachmentOffer(path: $0, candidates: []) }
        )
        // Candidates first (they are actionable), then unclaimed files; each
        // group by name, so the list does not reshuffle when a file is touched.
        offers.sort {
            $0.isUnmatched == $1.isUnmatched
                ? $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                : !$0.isUnmatched
        }
        attachmentOffers[folderID] = offers

        pass.offered = offers.filter { !$0.isUnmatched }.count
        pass.unmatched = report.unmatchedPdfs.count

        if !pass.isEmpty {
            Logger.files.infoCapture(
                "watched folder \(folderID.storageKey): \(pass.attached) PDF(s) attached, "
                    + "\(pass.alreadyAttached) already attached, \(pass.offered) offered for "
                    + "review, \(pass.unmatched) matched nothing, \(pass.missing) missing",
                category: "watched-folders")
        }
        return pass
    }

    /// Every `watched-file` row in one folder, paged.
    ///
    /// The kernel caps a page at `MAX_FILE_LIST_LIMIT` (2 000), so a folder
    /// larger than that takes several reads. The loop is bounded by the total
    /// the store itself reports and by a page count, so a store that kept
    /// returning rows could not spin it.
    private func allFiles(in folderID: WatchedFolderID) -> [WatchedFileRecord] {
        guard let storeID = storeFolderID(for: folderID) else { return [] }
        let pageSize = 2_000
        var collected: [WatchedFileRecord] = []
        var offset = 0
        while true {
            let page: (files: [WatchedFileRecord], total: Int)
            do {
                page = try attachmentFilesPage(
                    folderID: storeID, limit: pageSize, offset: offset)
            } catch {
                Logger.files.errorCapture(
                    "watched folder \(folderID.storageKey): could not read its files — "
                        + "\((error as? LocalizedError)?.errorDescription ?? "\(error)")",
                    category: "watched-folders")
                return collected
            }
            collected.append(contentsOf: page.files)
            offset += page.files.count
            if page.files.isEmpty || collected.count >= page.total { return collected }
        }
    }

    /// The Rust matcher, wrapped so the ONE FFI call site is here.
    ///
    /// `nonisolated` would be nicer, but the caller is main-actor anyway and
    /// the work is bounded by (entries × PDFs) string comparisons on a folder,
    /// which is the same order the sidebar already does to draw itself.
    private func matchAttachments(
        entries: [AttachmentEntry], pdfPaths: [String]
    ) -> AttachmentMatchReport {
        ImbibRustCore.matchAttachments(entries: entries, pdfPaths: pdfPaths)
    }
}
