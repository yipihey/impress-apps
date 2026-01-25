//
//  VagueMemoryQueryBuilder.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//

import Foundation

// MARK: - Vague Memory Query Builder

/// Builds ADS queries from vague memory descriptions using synonym expansion
/// and fuzzy matching strategies to maximize recall.
///
/// Key strategies for vague query success:
/// 1. Generous OR logic - Connect expanded terms with OR, not AND
/// 2. Synonym expansion - Dictionary of 50+ common astronomy terms
/// 3. Dual field search - Search both title: AND abs: fields
/// 4. Decade buffers - "1970s" searches 1968-1982 to catch edge cases
/// 5. Wildcard author matching - "starts with R" becomes author:"R*"
/// 6. Higher max results - Default to 100 results for vague queries
/// 7. Phrase preservation - Keep multi-word concepts quoted
public enum VagueMemoryQueryBuilder {

    // MARK: - Synonym Dictionary

    /// Astrophysics-focused synonym dictionary for query expansion.
    /// Each key maps to an array of related terms/abbreviations.
    public static let synonyms: [String: [String]] = [
        // Cosmology
        "dark matter": ["dark-matter", "DM", "WIMP", "CDM", "cold dark matter", "neutralino", "halo mass", "missing mass"],
        "dark energy": ["dark-energy", "cosmological constant", "lambda", "quintessence", "accelerating universe", "vacuum energy"],
        "cmb": ["cosmic microwave background", "microwave background", "CMBR", "CMB anisotropy", "CMB polarization"],
        "cosmic microwave background": ["CMB", "CMBR", "microwave background", "CMB anisotropy"],
        "big bang": ["early universe", "primordial", "cosmological", "cosmic nucleosynthesis", "BBN"],
        "inflation": ["inflationary", "inflaton", "slow-roll", "cosmic inflation"],
        "hubble constant": ["H0", "Hubble parameter", "expansion rate"],

        // Galaxies
        "galaxy rotation": ["rotation curve", "rotation curves", "galactic rotation", "spiral rotation", "flat rotation curve", "velocity curve"],
        "rotation curve": ["rotation curves", "galactic rotation", "galaxy rotation", "flat rotation"],
        "galaxy": ["galaxies", "galactic", "extragalactic"],
        "spiral galaxy": ["spiral galaxies", "disk galaxy", "Sa", "Sb", "Sc"],
        "elliptical galaxy": ["elliptical galaxies", "E0", "E7", "early-type galaxy"],
        "quasar": ["quasars", "QSO", "AGN", "active galactic nucleus", "active galactic nuclei", "quasi-stellar"],
        "agn": ["active galactic nucleus", "active galactic nuclei", "quasar", "QSO", "Seyfert"],
        "galaxy merger": ["galaxy mergers", "merging galaxies", "interacting galaxies", "galaxy interaction"],
        "galaxy cluster": ["cluster of galaxies", "galaxy clusters", "cluster mass"],
        "galaxy formation": ["galaxy evolution", "structure formation", "hierarchical formation"],

        // Compact objects
        "black hole": ["black holes", "BH", "schwarzschild", "kerr", "event horizon", "singularity", "massive black hole"],
        "supermassive black hole": ["SMBH", "massive black hole", "central black hole", "AGN"],
        "neutron star": ["neutron stars", "NS", "pulsar", "pulsars", "magnetar", "millisecond pulsar"],
        "pulsar": ["pulsars", "neutron star", "PSR", "millisecond pulsar", "radio pulsar"],
        "white dwarf": ["white dwarfs", "WD", "degenerate star"],
        "supernova": ["supernovae", "SNe", "SN", "stellar explosion", "type Ia", "core collapse", "SN Ia", "SNIa"],
        "type ia": ["type Ia supernova", "SN Ia", "SNIa", "thermonuclear supernova"],
        "gravitational wave": ["gravitational waves", "GW", "LIGO", "gravitational radiation", "merger", "inspiral", "chirp"],
        "binary": ["binary system", "binary star", "double star", "companion"],
        "x-ray binary": ["X-ray binaries", "XRB", "LMXB", "HMXB"],

        // Stars & stellar evolution
        "star formation": ["star-forming", "starburst", "stellar birth", "protostar", "molecular cloud"],
        "stellar evolution": ["star evolution", "main sequence", "red giant", "white dwarf", "stellar age"],
        "main sequence": ["MS", "hydrogen burning", "dwarf star"],
        "red giant": ["RGB", "giant branch", "AGB", "asymptotic giant branch"],
        "variable star": ["variable stars", "variability", "cepheid", "RR Lyrae", "eclipsing binary"],
        "cepheid": ["cepheids", "Cepheid variable", "classical Cepheid", "period-luminosity"],

        // Exoplanets
        "exoplanet": ["exoplanets", "extrasolar planet", "planetary system", "habitable zone", "transit", "radial velocity"],
        "hot jupiter": ["hot Jupiters", "close-in giant planet"],
        "habitable zone": ["habitable", "goldilocks zone", "liquid water"],
        "transit": ["transiting", "planetary transit", "occultation"],

        // High energy astrophysics
        "gamma ray": ["gamma rays", "GRB", "gamma-ray burst", "gamma-ray", "GeV", "TeV"],
        "gamma-ray burst": ["GRB", "gamma ray burst", "short GRB", "long GRB"],
        "x-ray": ["X-rays", "X-ray emission", "X-ray source", "soft X-ray", "hard X-ray"],
        "cosmic ray": ["cosmic rays", "CR", "high-energy particle", "ultra-high energy"],

        // Interstellar medium
        "interstellar": ["ISM", "interstellar medium", "diffuse gas"],
        "molecular cloud": ["molecular clouds", "GMC", "giant molecular cloud", "star-forming region"],
        "dust": ["interstellar dust", "dust grain", "extinction", "reddening"],
        "nebula": ["nebulae", "HII region", "planetary nebula", "emission nebula"],

        // Techniques & methods
        "spectroscopy": ["spectrum", "spectra", "spectral", "spectroscopic"],
        "photometry": ["photometric", "magnitude", "flux", "luminosity"],
        "redshift": ["z", "recession velocity", "cosmological redshift"],
        "proper motion": ["astrometry", "stellar motion", "parallax"],

        // Solar system (less common in ADS but useful)
        "asteroid": ["asteroids", "minor planet", "NEO", "near-Earth object"],
        "comet": ["comets", "cometary"],
    ]

    // MARK: - Query Building

    /// Build an ADS query from the vague memory form state.
    ///
    /// - Parameter state: The form state containing the vague memory description
    /// - Returns: An ADS query string optimized for recall
    public static func buildQuery(from state: VagueMemoryFormState) -> String {
        var queryParts: [String] = []

        // Process vague memory text with synonym expansion
        if !state.vagueMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let memoryQuery = buildMemoryQuery(state.vagueMemory)
            if !memoryQuery.isEmpty {
                queryParts.append(memoryQuery)
            }
        }

        // Process author hint
        if !state.authorHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let authorQuery = buildAuthorQuery(state.authorHint)
            if !authorQuery.isEmpty {
                queryParts.append(authorQuery)
            }
        }

        // Add year range
        if let yearRange = state.effectiveYearRange {
            let yearQuery = buildYearQuery(from: yearRange.start, to: yearRange.end)
            if !yearQuery.isEmpty {
                queryParts.append(yearQuery)
            }
        }

        return queryParts.joined(separator: " ")
    }

    // MARK: - Memory Query Building

    /// Build a query from the vague memory text, expanding synonyms and searching
    /// both title and abstract fields.
    private static func buildMemoryQuery(_ memory: String) -> String {
        let phrases = extractPhrases(from: memory)
        var expandedTerms: [String] = []

        for phrase in phrases {
            let lowercased = phrase.lowercased()

            // Check if this phrase has synonyms
            if let synonymList = findSynonyms(for: lowercased) {
                // Create an OR group of the phrase and its synonyms
                var allTerms = [phrase] + synonymList
                // Remove duplicates while preserving order
                var seen = Set<String>()
                allTerms = allTerms.filter { term in
                    let key = term.lowercased()
                    if seen.contains(key) { return false }
                    seen.insert(key)
                    return true
                }

                let quotedTerms = allTerms.map { term in
                    term.contains(" ") ? "\"\(term)\"" : term
                }
                let orGroup = quotedTerms.joined(separator: " OR ")
                expandedTerms.append("(\(orGroup))")
            } else {
                // No synonyms - just add the term
                let quoted = phrase.contains(" ") ? "\"\(phrase)\"" : phrase
                expandedTerms.append(quoted)
            }
        }

        if expandedTerms.isEmpty {
            return ""
        }

        // Search both title and abstract with OR between expanded terms
        // This maximizes recall for vague queries
        let searchTerms = expandedTerms.joined(separator: " ")
        return "(title:(\(searchTerms)) OR abs:(\(searchTerms)))"
    }

    /// Find synonyms for a phrase (case-insensitive).
    private static func findSynonyms(for phrase: String) -> [String]? {
        let lowercased = phrase.lowercased()

        // Direct match
        if let syns = synonyms[lowercased] {
            return syns
        }

        // Try to find partial matches for multi-word phrases
        for (key, values) in synonyms {
            if lowercased.contains(key) || key.contains(lowercased) {
                return values
            }
            // Check if any synonym contains our phrase
            if values.contains(where: { $0.lowercased() == lowercased }) {
                return [key] + values.filter { $0.lowercased() != lowercased }
            }
        }

        return nil
    }

    /// Extract meaningful phrases from the vague memory text.
    private static func extractPhrases(from text: String) -> [String] {
        // First, handle quoted phrases
        var phrases: [String] = []
        var remaining = text

        // Extract quoted phrases
        let quotePattern = #""([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: quotePattern, options: []) {
            let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                if let range = Range(match.range(at: 1), in: text) {
                    phrases.append(String(text[range]))
                }
                if let fullRange = Range(match.range, in: remaining) {
                    remaining.removeSubrange(fullRange)
                }
            }
        }

        // Look for known multi-word phrases in remaining text
        let lowercasedRemaining = remaining.lowercased()
        for key in synonyms.keys.sorted(by: { $0.count > $1.count }) {  // Longer phrases first
            if lowercasedRemaining.contains(key) {
                // Find the actual case version in the text
                if let range = remaining.range(of: key, options: .caseInsensitive) {
                    phrases.append(String(remaining[range]))
                    remaining.removeSubrange(range)
                }
            }
        }

        // Split remaining text into words and filter stop words
        let stopWords: Set<String> = [
            "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
            "of", "with", "by", "from", "about", "into", "through", "during",
            "before", "after", "above", "below", "between", "some", "something",
            "that", "this", "these", "those", "there", "was", "were", "been",
            "being", "have", "has", "had", "do", "does", "did", "will", "would",
            "could", "should", "may", "might", "must", "shall", "can", "need",
            "dare", "ought", "used", "related", "paper", "papers", "article",
            "hmm", "maybe", "think", "thought", "remember", "recall", "like",
            "similar", "kind", "sort", "stuff", "thing", "things"
        ]

        let words = remaining
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count > 2 && !stopWords.contains($0) }

        phrases.append(contentsOf: words)

        return phrases.filter { !$0.isEmpty }
    }

    // MARK: - Author Query Building

    /// Build an author query from a hint like "starts with R" or "Rubin".
    private static func buildAuthorQuery(_ hint: String) -> String {
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        // Detect "starts with X" pattern
        let startsWithPatterns = [
            #"starts?\s+with\s+(\w+)"#,
            #"beginning\s+with\s+(\w+)"#,
            #"first\s+letter\s+(\w+)"#,
            #"^(\w)\s*$"#  // Single letter
        ]

        for pattern in startsWithPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed) {
                let prefix = String(trimmed[range])
                return "author:\"\(prefix.capitalized)*\""
            }
        }

        // Detect "something like X" or "sounds like X" patterns
        let fuzzyPatterns = [
            #"(?:something|sounds?)\s+like\s+(\w+)"#,
            #"similar\s+to\s+(\w+)"#,
            #"maybe\s+(\w+)"#
        ]

        for pattern in fuzzyPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed) {
                let name = String(trimmed[range])
                // Use wildcards for fuzzy matching
                return "(author:\"\(name.capitalized)*\" OR author:\"*\(name.capitalized)*\")"
            }
        }

        // Detect common misspellings or partial names
        if lowercased.contains("first author") {
            // They want first author, extract the name
            let name = trimmed
                .replacingOccurrences(of: "first author", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return "author:\"^\(name.capitalized)\""
            }
        }

        // Default: treat as a name, possibly partial
        // Add wildcard if it looks like a partial name
        if trimmed.count <= 4 && trimmed.rangeOfCharacter(from: .whitespaces) == nil {
            // Short name - probably partial, use wildcard
            return "author:\"\(trimmed.capitalized)*\""
        } else if trimmed.contains(",") {
            // Looks like "Last, First" format - search exactly
            return "author:\"\(trimmed)\""
        } else {
            // Regular name search with some flexibility
            return "author:\"\(trimmed)\""
        }
    }

    // MARK: - Year Query Building

    /// Build a year range query.
    private static func buildYearQuery(from: Int?, to: Int?) -> String {
        switch (from, to) {
        case (let start?, let end?):
            return "year:\(start)-\(end)"
        case (let start?, nil):
            return "year:\(start)-"
        case (nil, let end?):
            return "year:-\(end)"
        case (nil, nil):
            return ""
        }
    }

    // MARK: - Query Preview

    /// Generate a human-readable preview of what the query will search for.
    public static func generatePreview(from state: VagueMemoryFormState) -> String {
        var parts: [String] = []

        if !state.vagueMemory.isEmpty {
            let phrases = extractPhrases(from: state.vagueMemory)
            if !phrases.isEmpty {
                parts.append("Topics: \(phrases.prefix(5).joined(separator: ", "))")
            }
        }

        if !state.authorHint.isEmpty {
            parts.append("Author: \(state.authorHint)")
        }

        if let decade = state.selectedDecade {
            parts.append("Time: \(decade.displayName)")
        } else if let yearRange = state.effectiveYearRange {
            if let start = yearRange.start, let end = yearRange.end {
                parts.append("Years: \(start)-\(end)")
            } else if let start = yearRange.start {
                parts.append("Years: \(start)+")
            } else if let end = yearRange.end {
                parts.append("Years: up to \(end)")
            }
        }

        return parts.isEmpty ? "Enter your vague memory..." : parts.joined(separator: " • ")
    }
}
