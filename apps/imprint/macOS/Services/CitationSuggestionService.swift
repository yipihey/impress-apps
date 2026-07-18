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
        Logger.ai.infoCapture("Citation raw output (\(full.count) chars): \(full.prefix(400).replacingOccurrences(of: "\n", with: " ⏎ "))", category: "ai")
        return Self.parseClaims(full, max: max)
    }

    /// Lenient parse handling both the single-line `CLAIM ||| QUERY` format and
    /// the labeled two-line format small models actually emit:
    /// `CLAIM: …` then `SEARCH QUERY: …`.
    static func parseClaims(_ raw: String, max: Int) -> [(claim: String, query: String)] {
        var out: [(String, String)] = []
        var pendingClaim: String?

        func emit(_ claim: String, _ query: String) {
            guard out.count < max, claim.count >= 8, claim.uppercased() != "NONE" else { return }
            let q = query.isEmpty ? deriveQuery(from: claim) : query
            guard !q.isEmpty else { return }
            out.append((claim, q))
        }

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^\\s*(?:[-*•]|\\d+[.)])\\s*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.uppercased() == "NONE" { continue }
            if out.count >= max { break }

            // Single-line "CLAIM ||| QUERY".
            if line.contains("|||") {
                let parts = line.components(separatedBy: "|||")
                emit(stripLabel(parts[0]), parts.count >= 2 ? stripLabel(parts[1]) : "")
                pendingClaim = nil
                continue
            }

            // Labeled two-line format.
            let upper = line.uppercased()
            if upper.hasPrefix("CLAIM") {
                pendingClaim = stripLabel(line)
            } else if upper.hasPrefix("SEARCH QUERY") || upper.hasPrefix("QUERY") {
                if let claim = pendingClaim {
                    emit(claim, stripLabel(line))
                    pendingClaim = nil
                }
            }
        }
        if let claim = pendingClaim { emit(claim, "") }  // trailing claim, no query line
        return out
    }

    /// Strip a leading "LABEL:" prefix (e.g. "CLAIM:", "SEARCH QUERY:") + quotes.
    private static func stripLabel(_ s: String) -> String {
        var text = s
        if let colon = text.firstIndex(of: ":"),
           text.distance(from: text.startIndex, to: colon) < 16,
           text[..<colon].allSatisfy({ $0.isLetter || $0.isWhitespace }) {
            text = String(text[text.index(after: colon)...])
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " \"'`"))
    }

    /// Derive a keyword search query from a claim when the model omitted one.
    private static func deriveQuery(from claim: String) -> String {
        let stop: Set<String> = ["the","a","an","of","and","or","to","in","on","for","with","that",
                                  "this","are","is","be","by","as","from","which","using","used",
                                  "been","has","have","its","their","such","than","then","also"]
        let words = claim.lowercased().split { !$0.isLetter }.map(String.init)
            .filter { $0.count > 3 && !stop.contains($0) }
        return words.prefix(5).joined(separator: " ")
    }
}
