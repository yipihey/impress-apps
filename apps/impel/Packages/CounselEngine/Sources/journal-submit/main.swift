//
//  journal-submit/main.swift
//
//  CLI for submitting a single manuscript to the impress journal pipeline.
//
//  Usage:
//    journal-submit --kind <new-manuscript|new-revision|fragment> \
//                   --title "<title>" \
//                   --source-file <path/to/draft.tex> \
//                   [--source-format <tex|typst>] \
//                   [--parent-manuscript <uuid>] \
//                   [--parent-revision <uuid>] \
//                   [--persona <persona-id>] \
//                   [--metadata <path/to/metadata.json>]
//
//  On success prints a JSON line: {"task_id": "...", "status": "pending", "content_hash": "..."}
//  Per docs/plan-journal-pipeline.md §3.6 / ADR-0011 D6.
//

import CounselEngine
import Foundation

struct CLIOptions {
    var kind: SubmissionKind = .newManuscript
    var title: String?
    var sourceFile: String?
    var sourceFormat: SourceFormat = .tex
    var parentManuscript: String?
    var parentRevision: String?
    var personaID: String?
    var metadataFile: String?
    var bibFile: String?
    var originConversation: String?
    var similarityHint: String?
}

func usage() {
    let s = """
    Usage: journal-submit [options]

      --kind                 new-manuscript | new-revision | fragment   (default: new-manuscript)
      --title <text>         Manuscript title (required)
      --source-file <path>   Path to .tex / .typ source file (required)
      --source-format        tex | typst (default: tex)
      --parent-manuscript    UUID of parent manuscript (required for new-revision/fragment)
      --parent-revision      UUID of predecessor revision (optional, for new-revision)
      --persona              Submitter persona ID (e.g. "scout")
      --metadata <path>      Path to a JSON file with extra submitter metadata
      --bib-file <path>      Path to a .bib file to attach
      --origin-conversation  Origin conversation reference (path or item ID)
      --similarity-hint      UUID of manuscript the submitter believes this resembles
      --help                 Print this message
    """
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func parseArgs(_ args: [String]) -> CLIOptions? {
    var opts = CLIOptions()
    var i = 1
    while i < args.count {
        let arg = args[i]
        let next: String? = (i + 1 < args.count) ? args[i + 1] : nil
        switch arg {
        case "--help", "-h":
            usage()
            return nil
        case "--kind":
            guard let v = next, let k = SubmissionKind(rawValue: v) else {
                FileHandle.standardError.write(Data("Invalid or missing --kind\n".utf8))
                return nil
            }
            opts.kind = k; i += 2
        case "--title":
            guard let v = next else { return nil }
            opts.title = v; i += 2
        case "--source-file":
            guard let v = next else { return nil }
            opts.sourceFile = v; i += 2
        case "--source-format":
            guard let v = next, let f = SourceFormat(rawValue: v) else {
                FileHandle.standardError.write(Data("Invalid --source-format\n".utf8))
                return nil
            }
            opts.sourceFormat = f; i += 2
        case "--parent-manuscript":
            opts.parentManuscript = next; i += 2
        case "--parent-revision":
            opts.parentRevision = next; i += 2
        case "--persona":
            opts.personaID = next; i += 2
        case "--metadata":
            opts.metadataFile = next; i += 2
        case "--bib-file":
            opts.bibFile = next; i += 2
        case "--origin-conversation":
            opts.originConversation = next; i += 2
        case "--similarity-hint":
            opts.similarityHint = next; i += 2
        default:
            FileHandle.standardError.write(Data("Unknown option: \(arg)\n".utf8))
            usage()
            return nil
        }
    }
    return opts
}

func readFile(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

@main
struct JournalSubmitMain {
    static func main() async {
        let args = CommandLine.arguments
        guard let opts = parseArgs(args) else {
            exit(2)
        }
        guard let title = opts.title, !title.isEmpty else {
            FileHandle.standardError.write(Data("--title is required\n".utf8))
            exit(2)
        }
        guard let sourceFile = opts.sourceFile else {
            FileHandle.standardError.write(Data("--source-file is required\n".utf8))
            exit(2)
        }

        let sourcePayload: String
        do {
            sourcePayload = try readFile(sourceFile)
        } catch {
            FileHandle.standardError.write(Data("Failed to read \(sourceFile): \(error.localizedDescription)\n".utf8))
            exit(1)
        }

        var metadataJSON: String?
        if let mf = opts.metadataFile {
            do { metadataJSON = try readFile(mf) }
            catch {
                FileHandle.standardError.write(Data("Failed to read --metadata: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        var bibPayload: String?
        if let bf = opts.bibFile {
            do { bibPayload = try readFile(bf) }
            catch {
                FileHandle.standardError.write(Data("Failed to read --bib-file: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }

        let payload = ManuscriptSubmission(
            submissionKind: opts.kind,
            title: title,
            sourceFormat: opts.sourceFormat,
            sourcePayload: sourcePayload,
            parentManuscriptRef: opts.parentManuscript,
            parentRevisionRef: opts.parentRevision,
            submitterPersonaID: opts.personaID,
            originConversationRef: opts.originConversation,
            metadataJSON: metadataJSON,
            bibliographyPayload: bibPayload,
            similarityHint: opts.similarityHint
        )

        do {
            let result = try await JournalSubmissionService.shared.submit(payload)
            // Print on stdout as a single JSON line.
            let dict: [String: String] = [
                "task_id": result.taskID,
                "status": result.status,
                "content_hash": result.contentHash,
            ]
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            if let s = String(data: data, encoding: .utf8) {
                print(s)
            }
            exit(0)
        } catch let JournalSubmissionError.invalidPayload(msg) {
            FileHandle.standardError.write(Data("Invalid submission: \(msg)\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("Submission failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
