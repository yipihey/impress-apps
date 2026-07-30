//
//  PublisherHTMLParsers.swift
//  PublicationManagerCore
//
//  Publisher-specific HTML parsing strategies for extracting PDF URLs from
//  landing pages.
//
//  Stage 7 item 9: the twenty extraction patterns and the host dispatch moved to
//  Rust (`crates/imbib-core/src/publishers/html.rs`).
//

import Foundation
import ImbibRustCore
import OSLog

// MARK: - Publisher HTML Parsers

/// Publisher-specific HTML parsers for extracting PDF URLs from landing pages.
///
/// **This is a shim.** All sixteen strategies — IOP, APS, Nature, Oxford,
/// Elsevier, A&A, Science, Wiley, Springer, Cambridge, Annual Reviews, MDPI,
/// Frontiers, PLOS, AIP and the generic fallback — live in `imbib-core`'s
/// `publishers::html` module, pinned by 82 golden cases in
/// `crates/imbib-core/test_fixtures/golden/publisher_parse{,r_id}.json`.
///
/// **The fetch stays here**, in `LandingPagePDFResolver`: `URLSession` carries
/// the system proxy configuration, App Transport Security, the sandbox's network
/// entitlement and the cookie/redirect policy, none of which has a Rust
/// equivalent worth building. This type is the half that runs after the bytes
/// arrive.
///
/// Two Foundation behaviours the Rust side reproduces exactly rather than
/// approximating, because seven of the strategies rewrite `baseURL.path` as
/// text: `URL.path` is percent-DECODED and drops one trailing slash, and
/// assigning to `URLComponents.path` RE-ENCODES. See
/// docs/parser-batch-swift-rust-split.md §5.
///
/// ## Supported Publishers
///
/// - IOP Science (ApJ, AJ, JCAP, CQG, etc.)
/// - APS (Physical Review journals)
/// - Nature Publishing Group
/// - Oxford Academic (MNRAS, etc.)
/// - Elsevier/ScienceDirect
/// - A&A (EDP Sciences), Science (AAAS), Wiley, Springer, Cambridge,
///   Annual Reviews, MDPI, Frontiers, PLOS, AIP
/// - Generic fallback for unknown publishers
public struct PublisherHTMLParsers: Sendable {

    // MARK: - Initialization

    public init() {}

    // MARK: - Parsing

    /// Parse HTML and extract PDF URL using publisher-specific logic.
    ///
    /// - Parameters:
    ///   - html: The HTML content of the landing page
    ///   - baseURL: The URL of the landing page (for resolving relative URLs)
    ///   - publisherHost: The hostname (e.g., "iopscience.iop.org")
    /// - Returns: PDF URL if found, nil otherwise
    public func parse(html: String, baseURL: URL, publisherHost: String) -> URL? {
        guard
            let resolved = ImbibRustCore.publisherExtractPdfUrl(
                html: html,
                baseUrl: baseURL.absoluteString,
                publisherHost: publisherHost
            )
        else { return nil }
        return URL(string: resolved)
    }

    /// Get parser ID for a publisher host (for logging/debugging).
    ///
    /// Note this is `contains`, not a suffix match, and the tests run in a fixed
    /// order — so `evil-nature.com.example.org` selects the Nature strategy.
    /// Preserved; the worst outcome is the wrong extraction strategy for a page
    /// that was already fetched.
    public func parserID(for publisherHost: String) -> String {
        ImbibRustCore.publisherParserId(publisherHost: publisherHost)
    }
}
