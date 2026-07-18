//
//  CitationSuggestionService.swift
//  imprint
//
//  Ranked citation suggestions: extract citation-worthy claims from a passage
//  (on-device model), then search the imbib library for supporting papers for
//  each claim. Returns candidates for the author (or an agent) to confirm —
//  nothing is inserted automatically (false positives are the main risk).
//

import Foundation
import OSLog
import ImpressLogging

@MainActor
final class CitationSuggestionService {
    static let shared = CitationSuggestionService()
    private init() {}

    private let imbib = ImbibIntegrationService.shared

    /// One extracted claim + the imbib papers that might support it.
    struct ClaimSuggestion: Identifiable {
        let id = UUID()
        let claim: String
        let query: String
        let candidates: [CitationResult]
    }

    /// Extract up to `maxClaims` citation-worthy claims from `text` and search
    /// imbib for `candidatesPerClaim` supporting papers each.
    func suggest(
        text: String,
        maxClaims: Int = 5,
        candidatesPerClaim: Int = 4
    ) async -> [ClaimSuggestion] {
        let claims = await extractClaims(from: text, max: maxClaims)
        var out: [ClaimSuggestion] = []
        for (claim, query) in claims {
            let candidates = (try? await imbib.searchPapers(query: query, maxResults: candidatesPerClaim)) ?? []
            out.append(ClaimSuggestion(claim: claim, query: query, candidates: candidates))
        }
        Logger.ai.infoCapture("Citation suggest: \(claims.count) claims, \(out.reduce(0){$0+$1.candidates.count}) candidates", category: "ai")
        return out
    }

    // MARK: - Claim extraction

    private func extractClaims(from text: String, max: Int) async -> [(claim: String, query: String)] {
        let system = """
        You help an author find citations for a scientific manuscript. From the passage below, identify up to \(max) specific factual claims or statements that should be supported by a citation (empirical results, prior methods, established facts, comparisons). Ignore the author's own new contributions.
        For EACH, output exactly one line, with no blank lines, in this pipe-delimited format:
        CLAIM ||| SEARCH QUERY
        - CLAIM: a short phrase (5 to 12 words) paraphrasing the statement that needs support.
        - SEARCH QUERY: 2 to 6 keywords to find supporting papers in a bibliography (topic + method, plus an author surname if one is stated).
        Output only these lines. If nothing needs a citation, output exactly: NONE
        """
        var full = ""
        do {
            for try await chunk in AIAssistantService.shared.streamMessage(systemPrompt: system, userMessage: text) {
                full += chunk
            }
        } catch {
            Logger.ai.warningCapture("Citation claim extraction failed: \(error.localizedDescription)", category: "ai")
            return []
        }
        return Self.parseClaims(full, max: max)
    }

    static func parseClaims(_ raw: String, max: Int) -> [(claim: String, query: String)] {
        var out: [(String, String)] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "|||").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            let claim = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\"'`- "))
            let query = parts[1]
            if claim.isEmpty || claim.uppercased() == "NONE" || query.isEmpty { continue }
            out.append((claim, query))
            if out.count >= max { break }
        }
        return out
    }
}
