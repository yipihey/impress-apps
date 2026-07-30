//
//  ADSQueryNormalizer.swift
//  ImpressSmartSearch
//
//  Normalization for ADS query strings — fixes the mistakes a language model
//  (or a hurrying human) makes: unquoted authors, unquoted multi-word values,
//  lowercase boolean operators, `a:`/`t:`/`b:` shorthands, `First Last` author
//  order.
//
//  The rules live in Rust (`crates/impress-smart-search`, module
//  `ads_normalizer`). Before this port there were THREE implementations of
//  them: this file, a byte-identical copy in PublicationManagerCore, and an
//  unwired Rust port in imbib-core that had already drifted (its
//  boolean-operator rule skipped every second operator — `"and or not"` came
//  out as `"AND or NOT"`). Nothing noticed, because the only caller of the Rust
//  one was a property test that checked totality rather than results. All three
//  are now the one Rust implementation, pinned by
//  `test_fixtures/golden/ads_normalize.json`.
//

import Foundation
import ImbibRustCore

public enum ADSQueryNormalizer {

    public struct Result {
        public let correctedQuery: String
        /// One human-readable line per rule that fired, in the order the Swift
        /// original reported them (last match first, per rule).
        public let corrections: [String]
        public var wasModified: Bool { !corrections.isEmpty }
    }

    /// Apply all normalization rules in order.
    public static func normalize(_ query: String) -> Result {
        let r = smartSearchNormalizeAdsQuery(query: query)
        return Result(correctedQuery: r.correctedQuery, corrections: r.corrections)
    }
}
