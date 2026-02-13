import Foundation
import ImpressAI
import ImpressKit
import OSLog

/// Registry of tools available to the Counsel agent loop.
///
/// Tools dispatch via HTTP to sibling apps using `SiblingBridge`.
/// Tool schemas match the MCP server definitions from `impress-mcp`.
public actor CounselToolRegistry {
    private let logger = Logger(subsystem: "com.impress.impel", category: "tool-registry")
    private let bridge = SiblingBridge.shared

    public init() {}

    // MARK: - Tool Definitions

    /// Returns all available tools as AITool definitions for the Anthropic API.
    public func allTools() -> [AITool] {
        imbibTools + imprintTools + imploreTools + impartTools
    }

    private var imbibTools: [AITool] {
        [
            AITool(
                name: "imbib_search_library",
                description: "Search the imbib bibliography library for papers matching a query.",
                inputSchema: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "query": AnySendable(["type": AnySendable("string"), "description": AnySendable("Search query for papers")] as [String: AnySendable]),
                        "limit": AnySendable(["type": AnySendable("integer"), "description": AnySendable("Max results (default 20)")] as [String: AnySendable])
                    ] as [String: AnySendable]),
                    "required": AnySendable([AnySendable("query")])
                ]
            ),
            AITool(
                name: "imbib_search_sources",
                description: "Search online sources (arXiv, ADS, Crossref, etc.) for papers.",
                inputSchema: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "query": AnySendable(["type": AnySendable("string"), "description": AnySendable("Search query")] as [String: AnySendable]),
                        "sources": AnySendable(["type": AnySendable("string"), "description": AnySendable("Comma-separated sources: arxiv,ads,crossref")] as [String: AnySendable]),
                        "limit": AnySendable(["type": AnySendable("integer"), "description": AnySendable("Max results per source")] as [String: AnySendable])
                    ] as [String: AnySendable]),
                    "required": AnySendable([AnySendable("query")])
                ]
            ),
            AITool(
                name: "imbib_add_papers",
                description: "Add papers to the imbib library by identifier (DOI, arXiv ID, or BibTeX).",
                inputSchema: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "identifiers": AnySendable(["type": AnySendable("array"), "items": AnySendable(["type": AnySendable("string")] as [String: AnySendable]), "description": AnySendable("Array of DOIs, arXiv IDs, or BibTeX strings")] as [String: AnySendable]),
                        "library": AnySendable(["type": AnySendable("string"), "description": AnySendable("Target library name (optional)")] as [String: AnySendable])
                    ] as [String: AnySendable]),
                    "required": AnySendable([AnySendable("identifiers")])
                ]
            ),
            AITool(
                name: "imbib_get_paper",
                description: "Get detailed information about a paper by cite key.",
                inputSchema: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "citeKey": AnySendable(["type": AnySendable("string"), "description": AnySendable("BibTeX cite key")] as [String: AnySendable])
                    ] as [String: AnySendable]),
                    "required": AnySendable([AnySendable("citeKey")])
                ]
            ),
            AITool(
                name: "imbib_export_bibtex",
                description: "Export BibTeX for specified papers.",
                inputSchema: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "citeKeys": AnySendable(["type": AnySendable("array"), "items": AnySendable(["type": AnySendable("string")] as [String: AnySendable]), "description": AnySendable("Cite keys to export")] as [String: AnySendable])
                    ] as [String: AnySendable]),
                    "required": AnySendable([AnySendable("citeKeys")])
                ]
            ),
            AITool(
                name: "imbib_create_artifact",
                description: "Create a research artifact in imbib. Artifacts capture non-paper items like notes, webpages, datasets, presentations, and code.",
                inputSchema: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "type": AnySendable(["type": AnySendable("string"), "description": AnySendable("Artifact type"), "enum": AnySendable([AnySendable("presentation"), AnySendable("poster"), AnySendable("dataset"), AnySendable("webpage"), AnySendable("note"), AnySendable("media"), AnySendable("code"), AnySendable("general")])] as [String: AnySendable]),
                        "title": AnySendable(["type": AnySendable("string"), "description": AnySendable("Artifact title")] as [String: AnySendable]),
                        "source_url": AnySendable(["type": AnySendable("string"), "description": AnySendable("Source URL (optional)")] as [String: AnySendable]),
                        "notes": AnySendable(["type": AnySendable("string"), "description": AnySendable("Notes or content (optional)")] as [String: AnySendable]),
                        "tags": AnySendable(["type": AnySendable("array"), "items": AnySendable(["type": AnySendable("string")] as [String: AnySendable]), "description": AnySendable("Tags (optional)")] as [String: AnySendable])
                    ] as [String: AnySendable]),
                    "required": AnySendable([AnySendable("type"), AnySendable("title")])
                ]
            ),
            AITool(
                name: "imbib_search_artifacts",
                description: "Search research artifacts in imbib by title, notes, or metadata.",
                inputSchema: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "query": AnySendable(["type": AnySendable("string"), "description": AnySendable("Search query")] as [String: AnySendable]),
                        "type": AnySendable(["type": AnySendable("string"), "description": AnySendable("Filter by artifact type (optional)")] as [String: AnySendable]),
                        "limit": AnySendable(["type": AnySendable("integer"), "description": AnySendable("Max results (default 20)")] as [String: AnySendable])
                    ] as [String: AnySendable]),
                    "required": AnySendable([AnySendable("query")])
                ]
            ),
        ]
    }

    private var imprintTools: [AITool] {
        [
            AITool(
                name: "imprint_list_documents",
                description: "List open documents in imprint.",
                inputSchema: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([:] as [String: AnySendable])
                ]
            ),
            AITool(
                name: "imprint_get_document",
                description: "Get the content of a document by ID.",
                inputSchema: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "id": AnySendable(["type": AnySendable("string"), "description": AnySendable("Document UUID")] as [String: AnySendable])
                    ] as [String: AnySendable]),
                    "required": AnySendable([AnySendable("id")])
                ]
            ),
        ]
    }

    private var imploreTools: [AITool] {
        [
            AITool(
                name: "implore_list_figures",
                description: "List figures in implore.",
                inputSchema: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([:] as [String: AnySendable])
                ]
            ),
        ]
    }

    private var impartTools: [AITool] {
        [
            AITool(
                name: "impart_list_conversations",
                description: "List research conversations in impart.",
                inputSchema: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "limit": AnySendable(["type": AnySendable("integer"), "description": AnySendable("Max results")] as [String: AnySendable])
                    ] as [String: AnySendable])
                ]
            ),
        ]
    }

    // MARK: - Tool Execution

    /// Execute a tool call by dispatching to the appropriate sibling app's HTTP API.
    public func execute(_ toolUse: AIToolUse) async -> AIToolResult {
        let name = toolUse.name
        let input = toolUse.input

        do {
            let result: String
            switch name {
            // imbib tools
            case "imbib_search_library":
                let query = stringParam(input, "query") ?? ""
                let limit = intParam(input, "limit") ?? 20
                let papers: [PaperSearchResult] = try await bridge.get(
                    "/api/search", from: .imbib,
                    query: ["query": query, "limit": String(limit)]
                )
                result = try jsonEncode(papers)

            case "imbib_search_sources":
                let query = stringParam(input, "query") ?? ""
                let sources = stringParam(input, "sources") ?? "arxiv,ads,crossref"
                let limit = intParam(input, "limit") ?? 10
                let data = try await bridge.getRaw(
                    "/api/search/sources", from: .imbib,
                    query: ["query": query, "sources": sources, "limit": String(limit)]
                )
                result = String(data: data, encoding: .utf8) ?? "[]"

            case "imbib_add_papers":
                let identifiers = arrayParam(input, "identifiers") ?? []
                let library = stringParam(input, "library")
                let body = AddPapersRequest(identifiers: identifiers, library: library)
                let addResult: AddPapersResult = try await bridge.post("/api/papers/add", to: .imbib, body: body)
                result = try jsonEncode(addResult)

            case "imbib_get_paper":
                let citeKey = stringParam(input, "citeKey") ?? ""
                let data = try await bridge.getRaw("/api/publications/\(citeKey)", from: .imbib)
                result = String(data: data, encoding: .utf8) ?? "{}"

            case "imbib_export_bibtex":
                let citeKeys = arrayParam(input, "citeKeys") ?? []
                let keysParam = citeKeys.joined(separator: ",")
                let data = try await bridge.getRaw("/api/export/bibtex", from: .imbib, query: ["keys": keysParam])
                result = String(data: data, encoding: .utf8) ?? ""

            case "imbib_create_artifact":
                let artifactType = stringParam(input, "type") ?? "general"
                let title = stringParam(input, "title") ?? ""
                let sourceURL = stringParam(input, "source_url")
                let notes = stringParam(input, "notes")
                let tags = arrayParam(input, "tags")
                var body: [String: Any] = [
                    "type": artifactType,
                    "title": title
                ]
                if let sourceURL { body["source_url"] = sourceURL }
                if let notes { body["notes"] = notes }
                if let tags { body["tags"] = tags }
                let data = try await bridge.postRaw("/api/artifacts", to: .imbib, body: body)
                result = String(data: data, encoding: .utf8) ?? "{}"

            case "imbib_search_artifacts":
                let query = stringParam(input, "query") ?? ""
                let type = stringParam(input, "type")
                let limit = intParam(input, "limit") ?? 20
                var queryParams = ["query": query, "limit": String(limit)]
                if let type { queryParams["type"] = type }
                let data = try await bridge.getRaw("/api/artifacts", from: .imbib, query: queryParams)
                result = String(data: data, encoding: .utf8) ?? "[]"

            // imprint tools
            case "imprint_list_documents":
                let docs: [DocumentInfo] = try await bridge.get("/api/documents", from: .imprint)
                result = try jsonEncode(docs)

            case "imprint_get_document":
                let id = stringParam(input, "id") ?? ""
                let data = try await bridge.getRaw("/api/documents/\(id)", from: .imprint)
                result = String(data: data, encoding: .utf8) ?? "{}"

            // implore tools
            case "implore_list_figures":
                let figures: [FigureInfo] = try await bridge.get("/api/figures", from: .implore)
                result = try jsonEncode(figures)

            // impart tools
            case "impart_list_conversations":
                let limit = intParam(input, "limit") ?? 20
                let convos: [ConversationInfo] = try await bridge.get(
                    "/api/research/conversations", from: .impart,
                    query: ["limit": String(limit)]
                )
                result = try jsonEncode(convos)

            default:
                return AIToolResult(toolUseId: toolUse.id, content: "Unknown tool: \(name)", isError: true)
            }

            logger.info("Tool \(name) executed successfully")
            return AIToolResult(toolUseId: toolUse.id, content: result)

        } catch {
            logger.error("Tool \(name) failed: \(error.localizedDescription)")
            return AIToolResult(toolUseId: toolUse.id, content: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Parameter Helpers

    private func stringParam(_ input: [String: AnySendable], _ key: String) -> String? {
        input[key]?.get() as String?
    }

    private func intParam(_ input: [String: AnySendable], _ key: String) -> Int? {
        if let i: Int = input[key]?.get() { return i }
        if let d: Double = input[key]?.get() { return Int(d) }
        return nil
    }

    private func arrayParam(_ input: [String: AnySendable], _ key: String) -> [String]? {
        if let arr: [AnySendable] = input[key]?.get() {
            return arr.compactMap { $0.get() as String? }
        }
        return nil
    }

    private func jsonEncode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "null"
    }
}
