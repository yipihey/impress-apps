//
//  RustQueryBuilder.swift
//  PublicationManagerCore
//
//  Search query building backed by the Rust imbib-core library.
//

import Foundation
import ImbibRustCore

/// Search query builder using the Rust imbib-core library.
public enum RustQueryBuilder {

    /// Build an ADS classic query.
    public static func buildClassicQuery(
        authors: String,
        objects: String,
        titleWords: String,
        titleLogic: PublicationManagerCore.QueryLogic,
        abstractWords: String,
        abstractLogic: PublicationManagerCore.QueryLogic,
        yearFrom: Int?,
        yearTo: Int?,
        database: PublicationManagerCore.ADSDatabase,
        refereedOnly: Bool,
        articlesOnly: Bool
    ) -> String {
        let rustTitleLogic: ImbibRustCore.QueryLogic = titleLogic == .and ? .and : .or
        let rustAbstractLogic: ImbibRustCore.QueryLogic = abstractLogic == .and ? .and : .or
        let rustDatabase: ImbibRustCore.AdsDatabase
        switch database {
        case .astronomy: rustDatabase = .astronomy
        case .physics: rustDatabase = .physics
        case .arxiv: rustDatabase = .arxiv
        case .all: rustDatabase = .all
        }

        return ImbibRustCore.buildClassicQuery(
            authors: authors,
            objects: objects,
            titleWords: titleWords,
            titleLogic: rustTitleLogic,
            abstractWords: abstractWords,
            abstractLogic: rustAbstractLogic,
            yearFrom: yearFrom.map { Int32($0) },
            yearTo: yearTo.map { Int32($0) },
            database: rustDatabase,
            refereedOnly: refereedOnly,
            articlesOnly: articlesOnly
        )
    }

    /// Build an ADS paper query from identifiers.
    public static func buildPaperQuery(
        bibcode: String,
        doi: String,
        arxivID: String
    ) -> String {
        ImbibRustCore.buildPaperQuery(bibcode: bibcode, doi: doi, arxivId: arxivID)
    }

    /// Check if classic form is empty.
    public static func isClassicFormEmpty(
        authors: String,
        objects: String,
        titleWords: String,
        abstractWords: String,
        yearFrom: Int?,
        yearTo: Int?
    ) -> Bool {
        ImbibRustCore.isClassicFormEmpty(
            authors: authors,
            objects: objects,
            titleWords: titleWords,
            abstractWords: abstractWords,
            yearFrom: yearFrom.map { Int32($0) },
            yearTo: yearTo.map { Int32($0) }
        )
    }

    /// Check if paper form is empty.
    public static func isPaperFormEmpty(
        bibcode: String,
        doi: String,
        arxivID: String
    ) -> Bool {
        ImbibRustCore.isPaperFormEmpty(bibcode: bibcode, doi: doi, arxivId: arxivID)
    }

    /// Build an arXiv author + categories query.
    public static func buildArXivAuthorCategoryQuery(
        author: String,
        categories: Set<String>,
        includeCrossListed: Bool
    ) -> String {
        ImbibRustCore.buildArxivAuthorCategoryQuery(
            author: author,
            categories: Array(categories),
            includeCrossListed: includeCrossListed
        )
    }
}
