//
//  journal-backfill/main.swift
//
//  CLI tool that walks a directory of Claude Code session transcripts
//  (~/.claude/projects/<project-id>/*.jsonl), extracts inline LaTeX/Typst
//  code blocks, and submits each as a manuscript-submission item.
//
//  This is the ONE-OFF backfill mechanism per ADR-0011 D6 + plan §3.6.
//  Steady-state submissions go through the HTTP / MCP / CLI direct routes;
//  this tool exists only to import pre-existing transcript content.
//
//  Usage:
//    journal-backfill <transcript-dir-or-file> [--dry-run] [--persona <id>]
//
//  Default persona: "scout" (since Scout is the natural triager).
//  Dry-run prints what would be submitted without writing to the store.
//

import CounselEngine
import Foundation

/// Source mode for the backfill walker.
enum BackfillMode {
    /// Walk .jsonl Claude session transcripts and extract fenced code blocks.
    case transcripts
    /// Walk .md files and submit each as one manuscript (Phase 7).
    /// Used for the recursive ingestion test (PDR §9.3) — the journal's
    /// own design docs become the journal's first stored content.
    case markdown
    /// Treat the input path as a manuscript bundle directory (or a parent
    /// of bundle subdirectories). Phase 8 — packs each bundle as a
    /// `.tar.zst` archive, stores it content-addressed, and submits the
    /// resulting bundle ref + manifest.
    case bundleDir
    /// Ingest a single pre-built `.tar.zst` bundle archive. Phase 8.
    case bundleFile
}

struct BackfillOptions {
    var path: String = ""
    var dryRun: Bool = false
    var personaID: String = "scout"
    var minBlockLines: Int = 5  // skip tiny snippets
    /// When true, compute the SHA-256 of each candidate block and skip
    /// any whose hash matches an existing manuscript-submission already
    /// in the workspace store. Lets the CLI be re-run safely (Phase 5.4).
    var skipExisting: Bool = false
    /// Source mode. Default = transcripts (the original Phase 1 use case);
    /// `--markdown-dir` flips to markdown-file mode (Phase 7).
    var mode: BackfillMode = .transcripts
}

func usage() {
    let s = """
    Usage: journal-backfill <path> [options]

      <path>               File or directory to ingest
      --markdown-dir       Treat <path> as a directory of .md files (one
                           manuscript per file). Default mode walks .jsonl
                           transcripts and extracts fenced code blocks.
      --bundle-dir         (Phase 8) Treat <path> as a manuscript bundle
                           directory, OR as a parent containing bundle
                           subdirectories (auto-detected). Each bundle
                           is packed as .tar.zst and submitted with a
                           manifest.
      --bundle-file        (Phase 8) Ingest a single pre-built .tar.zst
                           bundle from disk (e.g. an arXiv source tarball
                           after re-pack).
      --dry-run            Parse and report what would be submitted; no writes
      --persona <id>       Submitter persona ID (default: scout)
      --min-block-lines N  (transcripts mode) Skip code blocks shorter than
                           N lines (default: 5)
      --skip-existing      Skip content whose SHA-256 matches a submission
                           already in the workspace store (lets the CLI be
                           re-run safely)
      --help               Print this message
    """
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func parseArgs(_ args: [String]) -> BackfillOptions? {
    var opts = BackfillOptions()
    var positional: [String] = []
    var i = 1
    while i < args.count {
        let arg = args[i]
        let next: String? = (i + 1 < args.count) ? args[i + 1] : nil
        switch arg {
        case "--help", "-h":
            usage(); return nil
        case "--dry-run":
            opts.dryRun = true; i += 1
        case "--persona":
            guard let v = next else { return nil }
            opts.personaID = v; i += 2
        case "--min-block-lines":
            guard let v = next, let n = Int(v) else { return nil }
            opts.minBlockLines = n; i += 2
        case "--skip-existing":
            opts.skipExisting = true; i += 1
        case "--markdown-dir", "--md":
            opts.mode = .markdown; i += 1
        case "--bundle-dir":
            opts.mode = .bundleDir; i += 1
        case "--bundle-file":
            opts.mode = .bundleFile; i += 1
        default:
            if arg.hasPrefix("--") {
                FileHandle.standardError.write(Data("Unknown option: \(arg)\n".utf8))
                return nil
            }
            positional.append(arg); i += 1
        }
    }
    guard let p = positional.first else {
        FileHandle.standardError.write(Data("Missing <path> argument\n".utf8))
        usage(); return nil
    }
    opts.path = p
    return opts
}

// MARK: - Transcript walker

/// One extracted code block from a transcript.
struct ExtractedBlock {
    let sourcePath: String          // .jsonl file the block came from
    let messageIndex: Int           // line number within the .jsonl (0-based)
    let language: String            // tex | typst (lowercased)
    let content: String             // the code block body
    let title: String               // first \title{...} or \section heading, else fallback
}

func collectJSONLFiles(under path: String) -> [String] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
    if !isDir.boolValue {
        return path.hasSuffix(".jsonl") ? [path] : []
    }
    guard let enumerator = fm.enumerator(atPath: path) else { return [] }
    var out: [String] = []
    for case let rel as String in enumerator {
        if rel.hasSuffix(".jsonl") {
            out.append((path as NSString).appendingPathComponent(rel))
        }
    }
    return out.sorted()
}

/// Extract LaTeX/Typst code blocks from a single .jsonl transcript.
func extractBlocks(from jsonlPath: String, minLines: Int) -> [ExtractedBlock] {
    guard let raw = try? String(contentsOfFile: jsonlPath, encoding: .utf8) else { return [] }
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    var blocks: [ExtractedBlock] = []

    for (idx, line) in lines.enumerated() {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        // Claude session shapes: {message: {content: "..."}} or {message: {content: [...]}}
        var combinedText = ""
        if let msg = obj["message"] as? [String: Any] {
            if let s = msg["content"] as? String {
                combinedText += s
            } else if let arr = msg["content"] as? [[String: Any]] {
                for piece in arr {
                    if (piece["type"] as? String) == "text", let t = piece["text"] as? String {
                        combinedText += t
                    }
                }
            }
        }
        if combinedText.isEmpty { continue }

        // Find fenced code blocks: ```latex ... ``` / ```tex ... ``` / ```typst ... ```
        let pattern = #"```(latex|tex|typst|typ)\s*\n([\s\S]*?)\n```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
        let nsText = combinedText as NSString
        let matches = regex.matches(in: combinedText, range: NSRange(location: 0, length: nsText.length))
        for m in matches {
            guard m.numberOfRanges == 3 else { continue }
            let langRange = m.range(at: 1)
            let bodyRange = m.range(at: 2)
            let lang = nsText.substring(with: langRange).lowercased()
            let body = nsText.substring(with: bodyRange)
            let lineCount = body.split(separator: "\n").count
            if lineCount < minLines { continue }

            let normalizedLang = (lang == "typst" || lang == "typ") ? "typst" : "tex"
            let title = inferTitle(body: body, fallback: "Untitled \(normalizedLang) block from \((jsonlPath as NSString).lastPathComponent):\(idx)")

            blocks.append(ExtractedBlock(
                sourcePath: jsonlPath,
                messageIndex: idx,
                language: normalizedLang,
                content: body,
                title: title
            ))
        }
    }
    return blocks
}

/// Try to infer a sensible title: first \title{...}, else first \section{...},
/// else first non-empty line.
func inferTitle(body: String, fallback: String) -> String {
    let titlePattern = #"\\title\{([^}]+)\}"#
    if let regex = try? NSRegularExpression(pattern: titlePattern),
       let m = regex.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)),
       m.numberOfRanges == 2 {
        return (body as NSString).substring(with: m.range(at: 1))
    }
    let sectionPattern = #"\\section\{([^}]+)\}"#
    if let regex = try? NSRegularExpression(pattern: sectionPattern),
       let m = regex.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)),
       m.numberOfRanges == 2 {
        return (body as NSString).substring(with: m.range(at: 1))
    }
    let firstLine = body.split(separator: "\n").first.map(String.init) ?? fallback
    return firstLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : firstLine
}

// MARK: - Markdown walker (Phase 7)

/// One markdown file becomes one ManuscriptSubmission. The file's first
/// `# H1` line is the title; if there's no H1, the filename (sans `.md`
/// extension) is used.
struct MarkdownDoc {
    let path: String
    let title: String
    let body: String
}

/// Recursively collect `.md` files under `path`. Single-file paths return
/// just that file when it ends in `.md`.
func collectMarkdownFiles(under path: String) -> [String] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
    if !isDir.boolValue {
        return path.lowercased().hasSuffix(".md") ? [path] : []
    }
    guard let enumerator = fm.enumerator(atPath: path) else { return [] }
    var out: [String] = []
    for case let rel as String in enumerator {
        if rel.lowercased().hasSuffix(".md") {
            out.append((path as NSString).appendingPathComponent(rel))
        }
    }
    return out.sorted()
}

/// Read a markdown file and produce a `MarkdownDoc`. Title is the first
/// line that starts with `# ` (a top-level heading). If no H1 is found,
/// falls back to the filename without extension.
func readMarkdown(at path: String) -> MarkdownDoc? {
    guard let body = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    var title: String? = nil
    for line in body.split(separator: "\n", omittingEmptySubsequences: false).prefix(50) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") {
            // Skip "##", "###", etc. — only the first H1 wins.
            title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            break
        }
    }
    let resolvedTitle: String = {
        if let title, !title.isEmpty { return title }
        let base = (path as NSString).lastPathComponent
        if base.lowercased().hasSuffix(".md") { return String(base.dropLast(3)) }
        return base
    }()
    return MarkdownDoc(path: path, title: resolvedTitle, body: body)
}

@main
struct JournalBackfillMain {
    static func main() async {
        let args = CommandLine.arguments
        guard let opts = parseArgs(args) else { exit(2) }

        switch opts.mode {
        case .transcripts: await runTranscripts(opts: opts)
        case .markdown:    await runMarkdown(opts: opts)
        case .bundleDir:   await runBundleDir(opts: opts)
        case .bundleFile:  await runBundleFile(opts: opts)
        }
    }

    // MARK: - Markdown mode (Phase 7)

    static func runMarkdown(opts: BackfillOptions) async {
        let files = collectMarkdownFiles(under: opts.path)
        if files.isEmpty {
            FileHandle.standardError.write(Data("No .md files found under \(opts.path)\n".utf8))
            exit(1)
        }
        var existingHashes: Set<String> = []
        if opts.skipExisting {
            existingHashes = await fetchExistingSubmissionHashes()
            FileHandle.standardError.write(Data(
                "skip-existing: found \(existingHashes.count) prior submissions in workspace store\n".utf8
            ))
        }
        var submitted = 0
        var skipped = 0
        var failed = 0
        for file in files {
            guard let doc = readMarkdown(at: file) else {
                FileHandle.standardError.write(Data("FAILED to read \(file)\n".utf8))
                failed += 1
                continue
            }
            let hash = sha256Hex(of: doc.body)
            if opts.skipExisting, existingHashes.contains(hash) {
                print("[SKIP] \(doc.path) — content_hash \(hash.prefix(12))… already submitted")
                skipped += 1
                continue
            }
            if opts.dryRun {
                print("[DRY] \(doc.path) hash=\(hash.prefix(12))… title=\"\(doc.title)\" bytes=\(doc.body.utf8.count)")
                submitted += 1
                continue
            }
            // Phase 8: `markdown` is now a first-class source_format.
            let payload = ManuscriptSubmission(
                submissionKind: .newManuscript,
                title: doc.title,
                sourceFormat: .markdown,
                sourcePayload: doc.body,
                submitterPersonaID: opts.personaID,
                originConversationRef: doc.path,
                metadataJSON: nil,
                bibliographyPayload: nil,
                similarityHint: nil
            )
            do {
                let result = try await JournalSubmissionService.shared.submit(payload)
                print("submitted \(result.taskID) — \(doc.path) — \"\(doc.title)\"")
                submitted += 1
                existingHashes.insert(hash)
            } catch {
                FileHandle.standardError.write(Data("FAILED \(doc.path): \(error.localizedDescription)\n".utf8))
                failed += 1
            }
        }
        FileHandle.standardError.write(Data(
            "summary: mode=markdown files=\(files.count) submitted=\(submitted) skipped=\(skipped) failed=\(failed) dry_run=\(opts.dryRun)\n".utf8
        ))
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: - Bundle modes (Phase 8)

    /// Pack and submit one or more manuscript bundle directories.
    ///
    /// Auto-detects:
    /// - If <path> contains source files at root or has manifest.json, treat
    ///   as a single bundle directory.
    /// - Otherwise, iterate <path>'s immediate subdirectories; each subdir
    ///   is one bundle.
    static func runBundleDir(opts: BackfillOptions) async {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: opts.path, isDirectory: &isDir), isDir.boolValue else {
            FileHandle.standardError.write(Data("Path is not a directory: \(opts.path)\n".utf8))
            exit(1)
        }

        let bundleDirs = detectBundleDirs(under: opts.path)
        if bundleDirs.isEmpty {
            FileHandle.standardError.write(Data(
                "No manuscript bundles detected under \(opts.path)\n".utf8
            ))
            exit(1)
        }

        let existingHashes: Set<String>
        if opts.skipExisting {
            existingHashes = await fetchExistingSubmissionHashes()
            FileHandle.standardError.write(Data(
                "skip-existing: found \(existingHashes.count) prior submissions in workspace store\n".utf8
            ))
        } else {
            existingHashes = []
        }

        let builder = ManuscriptBundleBuilder()
        var submitted = 0
        var skipped = 0
        var failed = 0
        var seenHashes = existingHashes
        for dir in bundleDirs {
            let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
            do {
                let result = try await builder.buildFromDirectory(dirURL)
                if opts.skipExisting, seenHashes.contains(result.sha256) {
                    print("[SKIP] \(dir) — bundle SHA \(result.sha256.prefix(12))… already submitted")
                    skipped += 1
                    continue
                }
                let title = inferBundleTitle(dirURL: dirURL, manifest: result.manifest)
                let manifestJSON = try result.manifest.canonicalJSONString()
                if opts.dryRun {
                    print("[DRY] \(dir) sha=\(result.sha256.prefix(12))… title=\"\(title)\" entries=\(result.manifest.entries.count) bytes=\(result.archiveSize) format=\(result.manifest.sourceFormat.rawValue)")
                    submitted += 1
                    continue
                }
                let payload = ManuscriptSubmission(
                    submissionKind: .newManuscript,
                    title: title,
                    sourceFormat: bundleFormatToSourceFormat(result.manifest.sourceFormat),
                    sourcePayload: bundleSourcePayloadRef(sha256: result.sha256),
                    submitterPersonaID: opts.personaID,
                    originConversationRef: dir,
                    bundleManifestJSON: manifestJSON
                )
                let res = try await JournalSubmissionService.shared.submit(payload)
                print("submitted \(res.taskID) — \(dir) — \"\(title)\" — sha=\(result.sha256.prefix(12))…")
                submitted += 1
                seenHashes.insert(result.sha256)
            } catch {
                FileHandle.standardError.write(Data("FAILED \(dir): \(error.localizedDescription)\n".utf8))
                failed += 1
            }
        }
        FileHandle.standardError.write(Data(
            "summary: mode=bundle-dir bundles=\(bundleDirs.count) submitted=\(submitted) skipped=\(skipped) failed=\(failed) dry_run=\(opts.dryRun)\n".utf8
        ))
        exit(failed == 0 ? 0 : 1)
    }

    /// Ingest a single pre-built `.tar.zst` bundle file. The file is
    /// hash-verified and copied (if not already present) into the
    /// content-addressed blob root, then submitted with the manifest
    /// extracted from the archive.
    static func runBundleFile(opts: BackfillOptions) async {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: opts.path, isDirectory: &isDir), !isDir.boolValue else {
            FileHandle.standardError.write(Data(
                "Path is not a regular file: \(opts.path)\n".utf8
            ))
            exit(1)
        }
        guard opts.path.hasSuffix(".tar.zst") else {
            FileHandle.standardError.write(Data(
                "--bundle-file expects a .tar.zst path; got \(opts.path)\n".utf8
            ))
            exit(1)
        }

        let archiveURL = URL(fileURLWithPath: opts.path)
        let archiveData: Data
        do {
            archiveData = try Data(contentsOf: archiveURL)
        } catch {
            FileHandle.standardError.write(Data(
                "FAILED to read \(opts.path): \(error.localizedDescription)\n".utf8
            ))
            exit(1)
        }
        let sha = sha256Hex(of: archiveData)

        // Place into blob root if missing.
        let blobRoot = ManuscriptBundleBuilder.defaultBlobRoot
        let prefix1 = String(sha.prefix(2))
        let prefix2 = String(sha.dropFirst(2).prefix(2))
        let blobURL = blobRoot
            .appendingPathComponent(prefix1, isDirectory: true)
            .appendingPathComponent(prefix2, isDirectory: true)
            .appendingPathComponent("\(sha).tar.zst")
        if !fm.fileExists(atPath: blobURL.path) {
            do {
                try fm.createDirectory(at: blobURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try archiveData.write(to: blobURL, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data(
                    "FAILED to copy archive into blob root: \(error.localizedDescription)\n".utf8
                ))
                exit(1)
            }
        }

        if opts.skipExisting {
            let existingHashes = await fetchExistingSubmissionHashes()
            if existingHashes.contains(sha) {
                print("[SKIP] \(opts.path) — bundle SHA \(sha.prefix(12))… already submitted")
                FileHandle.standardError.write(Data(
                    "summary: mode=bundle-file submitted=0 skipped=1 failed=0 dry_run=\(opts.dryRun)\n".utf8
                ))
                exit(0)
            }
        }

        // Read manifest by extracting via the reader.
        let reader = ManuscriptBundleReader()
        do {
            let read = try await reader.read(sha256: sha)
            let title = inferBundleTitle(dirURL: read.extractedURL, manifest: read.manifest)
            let manifestJSON = try read.manifest.canonicalJSONString()
            if opts.dryRun {
                print("[DRY] \(opts.path) sha=\(sha.prefix(12))… title=\"\(title)\" entries=\(read.manifest.entries.count) bytes=\(archiveData.count) format=\(read.manifest.sourceFormat.rawValue)")
                FileHandle.standardError.write(Data(
                    "summary: mode=bundle-file submitted=1 skipped=0 failed=0 dry_run=true\n".utf8
                ))
                exit(0)
            }
            let payload = ManuscriptSubmission(
                submissionKind: .newManuscript,
                title: title,
                sourceFormat: bundleFormatToSourceFormat(read.manifest.sourceFormat),
                sourcePayload: bundleSourcePayloadRef(sha256: sha),
                submitterPersonaID: opts.personaID,
                originConversationRef: opts.path,
                bundleManifestJSON: manifestJSON
            )
            let res = try await JournalSubmissionService.shared.submit(payload)
            print("submitted \(res.taskID) — \(opts.path) — \"\(title)\" — sha=\(sha.prefix(12))…")
            FileHandle.standardError.write(Data(
                "summary: mode=bundle-file submitted=1 skipped=0 failed=0 dry_run=false\n".utf8
            ))
        } catch {
            FileHandle.standardError.write(Data(
                "FAILED \(opts.path): \(error.localizedDescription)\n".utf8
            ))
            FileHandle.standardError.write(Data(
                "summary: mode=bundle-file submitted=0 skipped=0 failed=1 dry_run=\(opts.dryRun)\n".utf8
            ))
            exit(1)
        }
    }

    // MARK: - Transcript mode (original Phase 1)

    static func runTranscripts(opts: BackfillOptions) async {
        let files = collectJSONLFiles(under: opts.path)
        if files.isEmpty {
            FileHandle.standardError.write(Data("No .jsonl files found under \(opts.path)\n".utf8))
            exit(1)
        }

        var totalBlocks = 0
        var totalSubmitted = 0
        var totalFailed = 0
        var totalSkipped = 0

        // Pre-compute the set of content_hashes already in the store, so
        // re-running the CLI is idempotent under --skip-existing. Only
        // queries the store when the flag is set (saves the open cost).
        var existingHashes: Set<String> = []
        if opts.skipExisting {
            existingHashes = await fetchExistingSubmissionHashes()
            FileHandle.standardError.write(Data(
                "skip-existing: found \(existingHashes.count) prior submissions in workspace store\n".utf8
            ))
        }

        for file in files {
            let blocks = extractBlocks(from: file, minLines: opts.minBlockLines)
            totalBlocks += blocks.count
            for block in blocks {
                let blockHash = sha256Hex(of: block.content)
                if opts.skipExisting, existingHashes.contains(blockHash) {
                    print("[SKIP] \(file):\(block.messageIndex) — content_hash \(blockHash.prefix(12))… already submitted")
                    totalSkipped += 1
                    continue
                }
                if opts.dryRun {
                    print("[DRY] \(file):\(block.messageIndex) lang=\(block.language) hash=\(blockHash.prefix(12))… title=\"\(block.title)\" lines=\(block.content.split(separator: "\n").count)")
                    totalSubmitted += 1
                    continue
                }
                let payload = ManuscriptSubmission(
                    submissionKind: .newManuscript,
                    title: block.title,
                    sourceFormat: block.language == "typst" ? .typst : .tex,
                    sourcePayload: block.content,
                    submitterPersonaID: opts.personaID,
                    originConversationRef: "\(file)#\(block.messageIndex)",
                    metadataJSON: nil,
                    bibliographyPayload: nil,
                    similarityHint: nil
                )
                do {
                    let result = try await JournalSubmissionService.shared.submit(payload)
                    print("submitted \(result.taskID) — \(file):\(block.messageIndex) — \"\(block.title)\"")
                    totalSubmitted += 1
                    existingHashes.insert(blockHash)  // avoid re-submitting in same run
                } catch {
                    FileHandle.standardError.write(Data("FAILED \(file):\(block.messageIndex): \(error.localizedDescription)\n".utf8))
                    totalFailed += 1
                }
            }
        }

        FileHandle.standardError.write(Data(
            "summary: files=\(files.count) blocks=\(totalBlocks) submitted=\(totalSubmitted) skipped=\(totalSkipped) failed=\(totalFailed) dry_run=\(opts.dryRun)\n".utf8
        ))
        exit(totalFailed == 0 ? 0 : 1)
    }
}

// MARK: - Helpers

import CryptoKit
import ImpressKit

#if canImport(ImpressRustCore)
import ImpressRustCore
#endif

private func sha256Hex(of text: String) -> String {
    sha256Hex(of: Data(text.utf8))
}

private func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data)
        .compactMap { String(format: "%02x", $0) }
        .joined()
}

/// Detect bundle directories under `path`. Returns `[path]` itself when
/// `path` looks like a single bundle dir, or its immediate subdirectories
/// otherwise. A "bundle dir" is one with a manifest.json or any source
/// file (.tex/.typ/.md/.html) at the top level.
private func detectBundleDirs(under path: String) -> [String] {
    let fm = FileManager.default
    let url = URL(fileURLWithPath: path, isDirectory: true)
    if dirLooksLikeBundle(url) {
        return [path]
    }
    let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    var subBundles: [String] = []
    for child in contents {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
        if dirLooksLikeBundle(child) {
            subBundles.append(child.path)
        }
    }
    return subBundles.sorted()
}

private func dirLooksLikeBundle(_ url: URL) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
        return true
    }
    let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    let sourceExts: Set<String> = ["tex", "typ", "md", "markdown", "html", "htm"]
    for child in contents {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: child.path, isDirectory: &isDir), !isDir.boolValue else { continue }
        let ext = child.pathExtension.lowercased()
        if sourceExts.contains(ext) {
            return true
        }
    }
    return false
}

/// Infer a manuscript title for a bundle. Reads the first H1/title line of
/// the manifest's main source; falls back to the bundle directory name.
private func inferBundleTitle(dirURL: URL, manifest: ManuscriptBundleManifest) -> String {
    let mainURL = dirURL.appendingPathComponent(manifest.mainSource)
    if let body = try? String(contentsOf: mainURL, encoding: .utf8) {
        switch manifest.sourceFormat {
        case .markdown:
            for line in body.split(separator: "\n", omittingEmptySubsequences: false).prefix(100) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("# ") {
                    return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
            }
        case .tex:
            if let m = matchFirst(pattern: #"\\title\{([^}]+)\}"#, in: body) {
                return m
            }
        case .typst:
            // Typst headings: `= Title` at column 0
            for line in body.split(separator: "\n", omittingEmptySubsequences: false).prefix(100) {
                if line.hasPrefix("= ") {
                    return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
            }
        case .html:
            if let m = matchFirst(pattern: #"<title>([^<]+)</title>"#, in: body) {
                return m
            }
        }
    }
    let base = dirURL.lastPathComponent
    return base.isEmpty ? "Untitled manuscript" : base
}

private func matchFirst(pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsText = text as NSString
    guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
          m.numberOfRanges == 2 else { return nil }
    return nsText.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func bundleFormatToSourceFormat(_ f: BundleSourceFormat) -> SourceFormat {
    switch f {
    case .tex: return .tex
    case .typst: return .typst
    case .markdown: return .markdown
    case .html: return .html
    }
}

/// Read all `manuscript-submission@1.0.0` items from the workspace store and
/// return the set of their content_hash values. Empty on any failure.
private func fetchExistingSubmissionHashes() async -> Set<String> {
    #if canImport(ImpressRustCore)
    do {
        try SharedWorkspace.ensureDirectoryExists()
        let store = try SharedStore.open(path: SharedWorkspace.databaseURL.path)
        let rows = try store.queryBySchema(
            schemaRef: "manuscript-submission",
            limit: 50000,
            offset: 0
        )
        var out: Set<String> = []
        for row in rows {
            guard let data = row.payloadJson.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hash = obj["content_hash"] as? String
            else { continue }
            out.insert(hash)
        }
        return out
    } catch {
        FileHandle.standardError.write(Data(
            "warning: --skip-existing could not read workspace store: \(error.localizedDescription)\n".utf8
        ))
        return []
    }
    #else
    return []
    #endif
}
