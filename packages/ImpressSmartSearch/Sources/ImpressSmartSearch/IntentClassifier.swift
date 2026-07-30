//
//  IntentClassifier.swift
//  ImpressSmartSearch
//
//  Deterministic, no-LLM classification of Cmd+S search input. Decides which
//  downstream path to take:
//
//    .identifier  → bare DOI / arXiv / bibcode / PMID
//    .fielded     → ADS-syntax query (passthrough)
//    .reference   → pasted citation string(s)
//    .url         → fetch the page and scrape identifiers
//    .freeText    → anything else
//
//  Designed for hot-path use (every keystroke).
//
//  The rules live in Rust (`crates/impress-smart-search`, module `intent`) and
//  reach us through ImbibCore.xcframework. This file is the boundary: it maps
//  the flat FFI record back onto `SearchIntent`. Behavior is pinned by
//  `crates/impress-smart-search/test_fixtures/golden/intent_*.json`, captured
//  from the Swift implementation this replaced, and asserted from both sides
//  (Rust: `tests/golden_parity.rs`; Swift: `PublicationManagerCoreTests/Golden/
//  SmartSearchParityTests.swift`, which runs through this very function).
//

import Foundation
import ImbibRustCore

public enum IntentClassifier {

    /// Classify a user input string. Empty input → `.freeText("")`.
    ///
    /// Synchronous and cheap — one FFI hop, no allocation beyond the result.
    public static func classify(_ input: String) -> SearchIntent {
        Self.intent(from: smartSearchClassify(input: input))
    }

    /// Split a multi-reference paste into individual citation blocks.
    public static func splitReferenceBlocks(_ text: String) -> [String] {
        smartSearchSplitReferenceBlocks(text: text)
    }

    // MARK: - FFI → SearchIntent

    private static func intent(from ffi: SmartSearchIntent) -> SearchIntent {
        switch ffi.kind {
        case "identifier":
            guard let kind = ffi.identifierKind,
                  let value = ffi.value,
                  let id = Self.identifier(kind: kind, value: value) else {
                // Unreachable: Rust always sets both fields for this kind. Fall
                // back to free text rather than trapping in the search field.
                return .freeText(query: input(from: ffi))
            }
            return .identifier(id)
        case "fielded":
            return .fielded(query: ffi.query ?? "")
        case "reference":
            return .reference(blocks: ffi.blocks)
        case "url":
            guard let value = ffi.value, let url = URL(string: value) else {
                return .freeText(query: input(from: ffi))
            }
            return .url(url)
        default:
            return .freeText(query: ffi.query ?? "")
        }
    }

    private static func identifier(kind: String, value: String) -> PaperIdentifierLite? {
        switch kind {
        case "doi": return .doi(value)
        case "arxiv": return .arxiv(value)
        case "bibcode": return .bibcode(value)
        case "pmid": return .pmid(value)
        default: return nil
        }
    }

    /// Best-effort recovery text for the unreachable fallback branches above.
    private static func input(from ffi: SmartSearchIntent) -> String {
        ffi.query ?? ffi.value ?? ""
    }
}
