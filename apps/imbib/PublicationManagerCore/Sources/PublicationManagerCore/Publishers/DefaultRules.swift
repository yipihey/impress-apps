//
//  DefaultRules.swift
//  PublicationManagerCore
//
//  Built-in publisher rules.
//
//  Stage 7 item 9: the table moved to Rust
//  (`imbib-core`'s `publishers::DEFAULT_RULES`).
//

import Foundation
import ImbibRustCore

// MARK: - Default Publisher Rules

/// Default publisher rules.
///
/// **This is a shim.** The rules live in
/// `crates/imbib-core/src/publishers/rules.rs` and are pinned field-by-field by
/// `test_fixtures/golden/publisher_default_rules.json` — originally captured
/// from the Swift declaration this file used to hold; rules added since (e.g.
/// `theoj-astro`) are added to the table and the fixture together.
///
/// The port collapsed **three** copies of the same table, already disagreeing:
///
/// | Copy | Rows | Drift |
/// |---|---|---|
/// | this file | 16 | the live one |
/// | `Publishers/Resources/publisher-rules.json` | 12 | bundled by `Package.swift` and **never loaded** — `setCustomRulesPath` has zero callers — missing `aip`, `annual-reviews`, `springer`, `cambridge` |
/// | `Tools/pdf-resolution-test/…/TestFixtures.swift` | 16, own type | prefixes spelled `"10.3847"` without the trailing `/`, so its matches differ |
public struct DefaultPublisherRules {

    /// All default rules, in declaration order.
    ///
    /// Computed rather than stored: the source of truth is the Rust `const`, and
    /// a stored `let` here would be a fourth copy the moment anyone edited one
    /// and not the other. The FFI call is a table walk over ~17 records, and the
    /// only caller that runs per-DOI (`PublisherRegistry`) goes through
    /// `rule(forDOI:)` below, which does not build this array.
    public static var rules: [PublisherRule] {
        ImbibRustCore.publisherDefaultRules().map(PublisherRule.init(ffi:))
    }

    /// Find the rule that matches a DOI.
    ///
    /// **Divergence (nondeterminism removed):** this used to be
    /// `rules.first { $0.matches(doi:) }` here and a `Dictionary` iteration in
    /// `PublisherRegistry`, so with two matching prefixes the winner was
    /// *unspecified* per process launch and neither preferred the longer prefix.
    /// Rust resolves longest-matching-prefix, table order as the tiebreak.
    public static func rule(forDOI doi: String) -> PublisherRule? {
        ImbibRustCore.publisherRuleForDoi(doi: doi).map(PublisherRule.init(ffi:))
    }

    /// Get publisher name for a DOI.
    public static func publisherName(forDOI doi: String) -> String? {
        rule(forDOI: doi)?.name
    }

    /// Check if DOI is from a publisher with high CAPTCHA risk.
    public static func hasHighCaptchaRisk(_ doi: String) -> Bool {
        rule(forDOI: doi)?.captchaRisk == .high
    }

    /// Check if OpenAlex should be preferred for this DOI.
    public static func shouldPreferOpenAlex(_ doi: String) -> Bool {
        rule(forDOI: doi)?.preferOpenAlex ?? false
    }
}
