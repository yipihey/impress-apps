import CryptoKit
import Foundation
import ImpressOCR
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct BuildOptions {
    let pdf: URL
    let output: URL
    let pages: String?
    let dpi: Int
    let workers: Int
    let mode: OCRRecognitionMode
    let level: OCRRecognitionLevel
    let languages: [String]
    let customWords: [String]
    let automaticallyDetectsLanguage: Bool
    let usesLanguageCorrection: Bool
    let force: Bool
}

private struct OCRRunIdentity: Codable, Equatable {
    let schemaVersion: Int
    let sourcePDF: String
    let sourceSHA256: String
    let sourcePages: Int
    let dpi: Int
    let engine: String
    let engineVersion: String
    let visionRevision: String
    let vision: AppleVisionOCRConfiguration

    var profile: String {
        "pdf-page-ocr;dpi=\(dpi);vision-revision=\(visionRevision);\(vision.profileIdentity)"
    }
}

private struct OCRRunFile: Codable {
    let identity: OCRRunIdentity
    let updatedAt: String
}

private struct CorpusManifest: Codable {
    struct OCR: Codable {
        let engine: String
        let engineVersion: String
        let visionRevision: String
        let mode: String
        let dpi: Int
        let languages: [String]
        let profile: String
        let layout: String

        enum CodingKeys: String, CodingKey {
            case engine
            case engineVersion = "engine_version"
            case visionRevision = "vision_revision"
            case mode
            case dpi
            case languages
            case profile
            case layout
        }
    }

    let schemaVersion: Int
    let sourcePDF: String
    let sourceSHA256: String
    let sourcePages: Int
    let indexedPages: Int
    let complete: Bool
    let ocr: OCR
    let database: String
    let builtAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sourcePDF = "source_pdf"
        case sourceSHA256 = "source_sha256"
        case sourcePages = "source_pages"
        case indexedPages = "indexed_pages"
        case complete
        case ocr
        case database
        case builtAt = "built_at"
    }
}

@main
private enum ImpressOCRCommand {
    static func main() async {
        do {
            let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            try await build(options)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    private static func build(_ options: BuildOptions) async throws {
        let pdf = options.pdf.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: pdf.path) else {
            throw CLIError.invalidArgument("Source PDF does not exist: \(pdf.path)")
        }
        try FileManager.default.createDirectory(
            at: options.output,
            withIntermediateDirectories: true
        )
        let pageDirectory = options.output.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pageDirectory,
            withIntermediateDirectories: true
        )

        let pageCount = try PDFOCRProcessor.pageCount(for: pdf)
        let selectedPages = try parsePageSpec(options.pages, pageCount: pageCount)
        let sourceHash = try sha256(url: pdf)
        let revision = options.mode == .document ? "document-revision1" : "text-revision3"
        let engineVersion = "\(revision); \(ProcessInfo.processInfo.operatingSystemVersionString)"
        let vision = AppleVisionOCRConfiguration(
            mode: options.mode,
            recognitionLevel: options.level,
            recognitionLanguages: options.languages,
            automaticallyDetectsLanguage: options.automaticallyDetectsLanguage,
            usesLanguageCorrection: options.usesLanguageCorrection,
            customWords: options.customWords,
            minimumTextHeightFraction: 0
        )
        let identity = OCRRunIdentity(
            schemaVersion: 2,
            sourcePDF: pdf.path,
            sourceSHA256: sourceHash,
            sourcePages: pageCount,
            dpi: options.dpi,
            engine: "apple-vision",
            engineVersion: engineVersion,
            visionRevision: revision,
            vision: vision
        )
        let runURL = options.output.appendingPathComponent("run.json")
        try validateRunIdentity(identity, at: runURL)
        try writeJSON(
            OCRRunFile(identity: identity, updatedAt: ISO8601DateFormatter().string(from: Date())),
            to: runURL
        )

        let pending = selectedPages.filter {
            options.force || !FileManager.default.fileExists(atPath: pageURL($0, in: pageDirectory).path)
        }
        print(
            "Apple Vision OCR: \(pending.count) uncached of \(selectedPages.count) requested "
                + "pages (\(pageCount) total), \(options.mode.rawValue) mode, "
                + "\(options.dpi) DPI, \(options.workers) workers"
        )

        let configuration = PDFOCRConfiguration(
            dpi: options.dpi,
            maximumConcurrentPages: options.workers,
            vision: vision
        )
        let processor = PDFOCRProcessor(configuration: configuration)
        var completed = 0
        let cacheBatchSize = max(1, options.workers * 4)
        for start in stride(from: 0, to: pending.count, by: cacheBatchSize) {
            let end = min(pending.count, start + cacheBatchSize)
            let batch = Array(pending[start..<end])
            let results = try await processor.process(pdf: pdf, pages: batch)
            for result in results {
                try writeJSON(result, to: pageURL(result.pageIndex, in: pageDirectory))
                completed += 1
                if completed.isMultiple(of: 10) || completed == pending.count {
                    print(
                        "Processed \(completed)/\(pending.count) uncached pages "
                            + "(PDF page \(result.pageIndex + 1), "
                            + "confidence \(String(format: "%.1f", result.meanConfidence)))"
                    )
                }
            }
        }

        let cachedPages = try loadCachedPages(from: pageDirectory)
        let builtAt = ISO8601DateFormatter().string(from: Date())
        let databaseURL = options.output.appendingPathComponent("index.sqlite3")
        try buildDatabase(
            at: databaseURL,
            pages: cachedPages,
            identity: identity,
            builtAt: builtAt
        )
        let manifest = CorpusManifest(
            schemaVersion: identity.schemaVersion,
            sourcePDF: identity.sourcePDF,
            sourceSHA256: identity.sourceSHA256,
            sourcePages: identity.sourcePages,
            indexedPages: cachedPages.count,
            complete: cachedPages.count == identity.sourcePages,
            ocr: .init(
                engine: identity.engine,
                engineVersion: identity.engineVersion,
                visionRevision: identity.visionRevision,
                mode: identity.vision.mode.rawValue,
                dpi: identity.dpi,
                languages: identity.vision.recognitionLanguages,
                profile: identity.profile,
                layout: "normalized-line-boxes-v1"
            ),
            database: databaseURL.lastPathComponent,
            builtAt: builtAt
        )
        try writeJSON(manifest, to: options.output.appendingPathComponent("manifest.json"))
        print("Indexed \(cachedPages.count)/\(pageCount) pages in \(databaseURL.path)")
    }
}

private enum CLIError: LocalizedError {
    case usage
    case invalidArgument(String)
    case incompatibleCache(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return """
            Usage: impress-ocr build PDF --output DIR [options]
              --pages 1-10,462       one-based page selection
              --dpi 220              render resolution
              --workers 1            bounded concurrent Vision requests
              --mode document|text   structured or line-oriented recognition
              --level accurate|fast  text-mode recognition level
              --language en-US       repeatable recognition language
              --custom-word WORD     repeatable domain vocabulary
              --automatic-language-detection
              --no-language-correction
              --force                redo selected cached pages
            """
        case .invalidArgument(let message), .incompatibleCache(let message):
            return message
        case .sqlite(let message):
            return "SQLite error: \(message)"
        }
    }
}

private func parseArguments(_ arguments: [String]) throws -> BuildOptions {
    guard arguments.first == "build", arguments.count >= 2 else {
        throw CLIError.usage
    }
    var index = 1
    var pdf: URL?
    var output: URL?
    var pages: String?
    var dpi = 220
    var workers = 1
    var mode = OCRRecognitionMode.text
    var level = OCRRecognitionLevel.accurate
    var languages: [String] = []
    var customWords: [String] = []
    var automaticallyDetectsLanguage = false
    var usesLanguageCorrection = true
    var force = false

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--output":
            output = URL(fileURLWithPath: try value(after: argument, arguments: arguments, index: &index))
        case "--pages":
            pages = try value(after: argument, arguments: arguments, index: &index)
        case "--dpi":
            dpi = try positiveInt(value(after: argument, arguments: arguments, index: &index), name: argument)
        case "--workers":
            workers = try positiveInt(value(after: argument, arguments: arguments, index: &index), name: argument)
        case "--mode":
            let raw = try value(after: argument, arguments: arguments, index: &index)
            guard let parsed = OCRRecognitionMode(rawValue: raw) else {
                throw CLIError.invalidArgument("Unknown OCR mode: \(raw)")
            }
            mode = parsed
        case "--level":
            let raw = try value(after: argument, arguments: arguments, index: &index)
            guard let parsed = OCRRecognitionLevel(rawValue: raw) else {
                throw CLIError.invalidArgument("Unknown recognition level: \(raw)")
            }
            level = parsed
        case "--language":
            languages.append(try value(after: argument, arguments: arguments, index: &index))
        case "--custom-word":
            customWords.append(try value(after: argument, arguments: arguments, index: &index))
        case "--automatic-language-detection":
            automaticallyDetectsLanguage = true
        case "--no-language-correction":
            usesLanguageCorrection = false
        case "--force":
            force = true
        case "--help", "-h":
            throw CLIError.usage
        default:
            guard !argument.hasPrefix("-"), pdf == nil else {
                throw CLIError.invalidArgument("Unexpected argument: \(argument)")
            }
            pdf = URL(fileURLWithPath: argument)
        }
        index += 1
    }
    guard let pdf, let output else { throw CLIError.usage }
    return BuildOptions(
        pdf: pdf,
        output: output.standardizedFileURL,
        pages: pages,
        dpi: dpi,
        workers: min(workers, 8),
        mode: mode,
        level: level,
        languages: languages.isEmpty ? ["en-US"] : languages,
        customWords: customWords,
        automaticallyDetectsLanguage: automaticallyDetectsLanguage,
        usesLanguageCorrection: usesLanguageCorrection,
        force: force
    )
}

private func value(after option: String, arguments: [String], index: inout Int) throws -> String {
    index += 1
    guard index < arguments.count else {
        throw CLIError.invalidArgument("\(option) requires a value")
    }
    return arguments[index]
}

private func positiveInt(_ value: String, name: String) throws -> Int {
    guard let number = Int(value), number > 0 else {
        throw CLIError.invalidArgument("\(name) requires a positive integer")
    }
    return number
}

private func parsePageSpec(_ spec: String?, pageCount: Int) throws -> [Int] {
    guard let spec, !spec.isEmpty else { return Array(0..<pageCount) }
    var selected = Set<Int>()
    for component in spec.split(separator: ",") {
        let bounds = component.split(separator: "-", maxSplits: 1).map(String.init)
        if bounds.count == 1 {
            guard let page = Int(bounds[0]) else {
                throw CLIError.invalidArgument("Invalid page: \(component)")
            }
            selected.insert(page - 1)
        } else {
            guard let first = Int(bounds[0]), let last = Int(bounds[1]), first <= last else {
                throw CLIError.invalidArgument("Invalid page range: \(component)")
            }
            selected.formUnion((first...last).map { $0 - 1 })
        }
    }
    let invalid = selected.filter { $0 < 0 || $0 >= pageCount }.sorted()
    guard invalid.isEmpty else {
        throw CLIError.invalidArgument(
            "Pages outside 1-\(pageCount): \(invalid.map { String($0 + 1) }.joined(separator: ", "))"
        )
    }
    return selected.sorted()
}

private func pageURL(_ pageIndex: Int, in directory: URL) -> URL {
    directory.appendingPathComponent(String(format: "page-%04d.json", pageIndex + 1))
}

private func validateRunIdentity(_ identity: OCRRunIdentity, at url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let existing = try JSONDecoder().decode(OCRRunFile.self, from: Data(contentsOf: url))
    guard existing.identity == identity else {
        throw CLIError.incompatibleCache(
            "Output directory belongs to different source bytes or OCR settings: \(url.deletingLastPathComponent().path)"
        )
    }
}

private func loadCachedPages(from directory: URL) throws -> [OCRPageResult] {
    let urls = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try urls.map { try JSONDecoder().decode(OCRPageResult.self, from: Data(contentsOf: $0)) }
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let temporary = url.appendingPathExtension("tmp")
    try encoder.encode(value).write(to: temporary, options: .atomic)
    if FileManager.default.fileExists(atPath: url.path) {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } else {
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}

private func sha256(url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: 1_048_576) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func buildDatabase(
    at databaseURL: URL,
    pages: [OCRPageResult],
    identity: OCRRunIdentity,
    builtAt: String
) throws {
    let temporary = databaseURL
        .deletingLastPathComponent()
        .appendingPathComponent("index-\(UUID().uuidString).sqlite3.tmp")
    let database = try SQLiteDatabase(path: temporary.path)
    try database.exec(
        """
        PRAGMA journal_mode = DELETE;
        PRAGMA synchronous = FULL;
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE pages (
            pdf_page INTEGER PRIMARY KEY,
            section_hint TEXT NOT NULL,
            text TEXT NOT NULL,
            char_count INTEGER NOT NULL,
            word_count INTEGER NOT NULL,
            mean_confidence REAL NOT NULL,
            median_confidence REAL NOT NULL,
            low_confidence_fraction REAL NOT NULL,
            status TEXT NOT NULL,
            layout_json TEXT NOT NULL,
            structure_json TEXT
        );
        CREATE VIRTUAL TABLE pages_fts USING fts5(
            section_hint,
            text,
            content='pages',
            content_rowid='pdf_page',
            tokenize='unicode61 remove_diacritics 2'
        );
        """
    )
    let insertPage = try database.prepare("INSERT INTO pages VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    let insertFTS = try database.prepare(
        "INSERT INTO pages_fts(rowid, section_hint, text) VALUES (?, ?, ?)"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for page in pages.sorted(by: { $0.pageIndex < $1.pageIndex }) {
        try insertPage.reset()
        try insertPage.bind(Int64(page.pageIndex + 1), at: 1)
        try insertPage.bind(page.sectionHint, at: 2)
        try insertPage.bind(page.text, at: 3)
        try insertPage.bind(Int64(page.text.count), at: 4)
        try insertPage.bind(Int64(page.wordCount), at: 5)
        try insertPage.bind(page.meanConfidence, at: 6)
        try insertPage.bind(page.medianConfidence, at: 7)
        try insertPage.bind(page.lowConfidenceFraction, at: 8)
        try insertPage.bind(page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "blank" : "ocr", at: 9)
        try insertPage.bind(String(decoding: encoder.encode(page.observations), as: UTF8.self), at: 10)
        if let structure = page.structure {
            try insertPage.bind(String(decoding: encoder.encode(structure), as: UTF8.self), at: 11)
        } else {
            try insertPage.bindNull(at: 11)
        }
        try insertPage.stepDone()

        try insertFTS.reset()
        try insertFTS.bind(Int64(page.pageIndex + 1), at: 1)
        try insertFTS.bind(page.sectionHint, at: 2)
        try insertFTS.bind(page.text, at: 3)
        try insertFTS.stepDone()
    }
    insertPage.finalize()
    insertFTS.finalize()

    let metadata: [String: String] = [
        "schema_version": String(identity.schemaVersion),
        "source_pdf": identity.sourcePDF,
        "source_sha256": identity.sourceSHA256,
        "source_pages": String(identity.sourcePages),
        "indexed_pages": String(pages.count),
        "engine": identity.engine,
        "engine_version": identity.engineVersion,
        "vision_revision": identity.visionRevision,
        "mode": identity.vision.mode.rawValue,
        "dpi": String(identity.dpi),
        "language": identity.vision.recognitionLanguages.joined(separator: ","),
        "profile": identity.profile,
        "layout": "normalized-line-boxes-v1",
        "built_at": builtAt,
    ]
    let insertMetadata = try database.prepare("INSERT INTO metadata(key, value) VALUES (?, ?)")
    for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
        try insertMetadata.reset()
        try insertMetadata.bind(key, at: 1)
        try insertMetadata.bind(value, at: 2)
        try insertMetadata.stepDone()
    }
    insertMetadata.finalize()
    guard try database.scalarText("PRAGMA integrity_check") == "ok" else {
        throw CLIError.sqlite("integrity_check failed")
    }
    try database.close()
    if FileManager.default.fileExists(atPath: databaseURL.path) {
        _ = try FileManager.default.replaceItemAt(databaseURL, withItemAt: temporary)
    } else {
        try FileManager.default.moveItem(at: temporary, to: databaseURL)
    }
}

private final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            throw CLIError.sqlite("could not open \(path)")
        }
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw CLIError.sqlite(errorMessage)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CLIError.sqlite(errorMessage)
        }
        return SQLiteStatement(database: self, handle: statement)
    }

    func scalarText(_ sql: String) throws -> String {
        let statement = try prepare(sql)
        guard sqlite3_step(statement.handle) == SQLITE_ROW,
              let value = sqlite3_column_text(statement.handle, 0) else {
            throw CLIError.sqlite(errorMessage)
        }
        return String(cString: value)
    }

    func close() throws {
        guard let handle else { return }
        guard sqlite3_close(handle) == SQLITE_OK else {
            throw CLIError.sqlite(errorMessage)
        }
        self.handle = nil
    }

    fileprivate var errorMessage: String {
        guard let message = sqlite3_errmsg(handle) else { return "unknown error" }
        return String(cString: message)
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }
}

private final class SQLiteStatement {
    unowned let database: SQLiteDatabase
    private var statement: OpaquePointer?

    fileprivate var handle: OpaquePointer {
        precondition(statement != nil, "SQLite statement already finalized")
        return statement!
    }

    init(database: SQLiteDatabase, handle: OpaquePointer) {
        self.database = database
        self.statement = handle
    }

    func bind(_ value: String, at index: Int32) throws {
        guard sqlite3_bind_text(handle, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw CLIError.sqlite(database.errorMessage)
        }
    }

    func bind(_ value: Int64, at index: Int32) throws {
        guard sqlite3_bind_int64(handle, index, value) == SQLITE_OK else {
            throw CLIError.sqlite(database.errorMessage)
        }
    }

    func bind(_ value: Double, at index: Int32) throws {
        guard sqlite3_bind_double(handle, index, value) == SQLITE_OK else {
            throw CLIError.sqlite(database.errorMessage)
        }
    }

    func bindNull(at index: Int32) throws {
        guard sqlite3_bind_null(handle, index) == SQLITE_OK else {
            throw CLIError.sqlite(database.errorMessage)
        }
    }

    func stepDone() throws {
        guard sqlite3_step(handle) == SQLITE_DONE else {
            throw CLIError.sqlite(database.errorMessage)
        }
    }

    func reset() throws {
        guard sqlite3_reset(handle) == SQLITE_OK, sqlite3_clear_bindings(handle) == SQLITE_OK else {
            throw CLIError.sqlite(database.errorMessage)
        }
    }

    func finalize() {
        if let statement {
            sqlite3_finalize(statement)
            self.statement = nil
        }
    }

    deinit {
        finalize()
    }
}
