//
//  ImprintRustHandlersBridge.swift
//  imprint (macOS)
//
//  Phase 2E scaffolding — the Rust trait `imprint_service::ImprintHttpHandlers`
//  (see `crates/imprint-service/src/handlers.rs`) defines the stateless slice
//  of `ImprintHTTPRouter`. The actual cross-language wiring (UniFFI bindings
//  for `imprint-service`) ships in Phase 3.
//
//  Bodies are stubs because UniFFI bindings for imprint-service ship in
//  Phase 3. Until then this file exists so the call sites are named and
//  ImprintHTTPRouter has a single, focused target to cut over to. Do NOT
//  modify ImprintHTTPRouter.swift to actually call this bridge yet — that is
//  a separate, reviewable PR once the bindings exist.
//
//  What lives behind each method (in Rust) is documented in
//  `crates/imprint-service/src/handlers.rs`. The Swift signatures here mirror
//  the trait so the Phase 3 cutover is mechanical:
//
//      // Before (Swift):
//      private func handleGetOutline(id: String) async -> HTTPResponse {
//          ...
//          let outline = extractOutline(doc.source)
//          ...
//      }
//
//      // After (Phase 3):
//      private func handleGetOutline(id: String) async -> HTTPResponse {
//          ...
//          let outline = try await ImprintRustHandlersBridge.shared
//              .documentOutline(source: doc.source)
//          ...
//      }
//

import Foundation

// MARK: - DTOs (Swift mirrors of the Rust types in handlers.rs)

/// One heading extracted from Typst source. Mirrors
/// `imprint_service::handlers::OutlineEntry`.
public struct ImprintOutlineEntry: Sendable, Equatable {
    public let level: UInt32
    public let title: String
    public let line: UInt32
    public let position: UInt32
}

/// One `@citekey` reference. Mirrors
/// `imprint_service::handlers::CitationUsage`.
public struct ImprintCitationUsage: Sendable, Equatable {
    public let citeKey: String
    public let position: UInt32
    public let length: UInt32
}

/// A single match returned by `searchInText`. Mirrors
/// `imprint_service::handlers::TextMatch`.
public struct ImprintTextMatch: Sendable, Equatable {
    public let position: UInt32
    public let length: UInt32
    public let text: String
}

/// A cross-document search hit. Mirrors
/// `imprint_service::search::SearchHit`.
public struct ImprintSearchHit: Sendable, Equatable {
    public let itemID: String
    public let documentID: String
    public let sectionKey: String
    public let title: String
    public let sectionType: String?
    public let score: Float
    public let excerpt: String?
}

/// A persisted section. Mirrors
/// `imprint_service::sections::SectionRecord` (with `Date` instead of an
/// epoch millis integer for convenience on the Swift side).
public struct ImprintSectionRecord: Sendable, Equatable {
    public let itemID: UUID
    public let documentID: UUID
    public let sectionKey: String
    public let title: String
    public let body: String
    public let sectionType: String?
    public let orderIndex: Int64?
    public let wordCount: Int64
    public let contentHash: String?
    public let createdAt: Date
}

/// Metadata accompanying a section put. Mirrors
/// `imprint_service::sections::SectionMetadata`.
public struct ImprintSectionMetadata: Sendable, Equatable {
    public var title: String?
    public var sectionType: String?
    public var orderIndex: Int64?
    public init(title: String? = nil, sectionType: String? = nil, orderIndex: Int64? = nil) {
        self.title = title
        self.sectionType = sectionType
        self.orderIndex = orderIndex
    }
}

/// Outcome of a search-and-replace. Mirrors
/// `imprint_service::handlers::ReplaceResult`.
public struct ImprintReplaceResult: Sendable, Equatable {
    public let replacements: UInt32
    public let newBody: String
}

// MARK: - Bridge

/// Future Swift façade over `imprint_service::ImprintHttpHandlers`.
///
/// This is a STUB in Phase 2E. Every method calls `fatalError` to make sure
/// no production code accidentally exercises it before the Phase 3 UniFFI
/// bindings land. See the file header for the cutover plan.
public final class ImprintRustHandlersBridge: @unchecked Sendable {

    public static let shared = ImprintRustHandlersBridge()

    private init() {}

    // ── Section CRUD ────────────────────────────────────────────────────────

    public func listSections(documentID: UUID) async throws -> [ImprintSectionRecord] {
        fatalError("Phase 2E: wire ImprintRustHandlersBridge → ImprintHttpHandlers via UniFFI")
    }

    public func getSection(documentID: UUID, sectionKey: String) async throws -> ImprintSectionRecord? {
        fatalError("Phase 2E: wire ImprintRustHandlersBridge → ImprintHttpHandlers via UniFFI")
    }

    public func putSection(
        documentID: UUID,
        sectionKey: String,
        body: String,
        metadata: ImprintSectionMetadata
    ) async throws -> ImprintSectionRecord {
        fatalError("Phase 2E: wire ImprintRustHandlersBridge → ImprintHttpHandlers via UniFFI")
    }

    public func deleteSection(documentID: UUID, sectionKey: String) async throws {
        fatalError("Phase 2E: wire ImprintRustHandlersBridge → ImprintHttpHandlers via UniFFI")
    }

    public func replaceInSection(
        documentID: UUID,
        sectionKey: String,
        find: String,
        replace: String,
        replaceAll: Bool
    ) async throws -> ImprintReplaceResult {
        fatalError("Phase 2E: wire ImprintRustHandlersBridge → ImprintHttpHandlers via UniFFI")
    }

    // ── Pure-text helpers ───────────────────────────────────────────────────

    public func documentOutline(source: String) async throws -> [ImprintOutlineEntry] {
        fatalError("Phase 2E: wire ImprintRustHandlersBridge → ImprintHttpHandlers via UniFFI")
    }

    public func documentCitations(source: String) async throws -> [ImprintCitationUsage] {
        fatalError("Phase 2E: wire ImprintRustHandlersBridge → ImprintHttpHandlers via UniFFI")
    }

    public func searchInText(
        source: String,
        query: String,
        caseSensitive: Bool
    ) async throws -> [ImprintTextMatch] {
        fatalError("Phase 2E: wire ImprintRustHandlersBridge → ImprintHttpHandlers via UniFFI")
    }

    // ── Cross-document section search ───────────────────────────────────────

    public func search(query: String, limit: Int) async throws -> [ImprintSearchHit] {
        fatalError("Phase 2E: wire ImprintRustHandlersBridge → ImprintHttpHandlers via UniFFI")
    }
}
