//
//  TagPathNormalizer.swift
//  PublicationManagerCore
//
//  Normalizes tag path segments: lowercase, spaces→hyphens, collapse multiples, trim.
//  Defensive layer against LLM output that ignores formatting instructions.
//

import Foundation

/// Normalizes individual tag path segments and full tag paths.
///
/// Ensures no spaces in tag paths (which break the filter tokenizer),
/// consistent casing, and clean formatting regardless of LLM output quality.
public enum TagPathNormalizer {

    /// Normalize a single path segment (e.g., "Dark Energy" → "dark-energy").
    public static func normalize(_ segment: String) -> String {
        var result = segment
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Replace spaces and underscores with hyphens
        result = result.replacingOccurrences(of: " ", with: "-")
        result = result.replacingOccurrences(of: "_", with: "-")

        // Collapse multiple consecutive hyphens
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }

        // Trim leading/trailing hyphens
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return result
    }

    /// Normalize a full tag path (e.g., "ai/Dark Energy/Sub Topic" → "ai/dark-energy/sub-topic").
    ///
    /// Splits on `/`, normalizes each segment, removes empty segments, and rejoins.
    public static func normalizePath(_ path: String) -> String {
        path.components(separatedBy: "/")
            .map { normalize($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }
}
