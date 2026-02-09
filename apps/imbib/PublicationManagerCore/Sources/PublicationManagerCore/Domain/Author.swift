//
//  Author.swift
//  PublicationManagerCore
//
//  Domain struct replacing CDAuthor + CDPublicationAuthor.
//

import Foundation
import ImbibRustCore

/// Structured author data parsed from BibTeX.
public struct AuthorModel: Identifiable, Hashable, Sendable {
    public var id: String { displayName }
    public let givenName: String?
    public let familyName: String
    public let suffix: String?
    public let orcid: String?
    public let affiliation: String?

    public var displayName: String {
        if let given = givenName, !given.isEmpty {
            return "\(familyName), \(given)"
        }
        return familyName
    }

    public var shortName: String { familyName }

    public init(from row: AuthorRow) {
        self.givenName = row.givenName
        self.familyName = row.familyName
        self.suffix = row.suffix
        self.orcid = row.orcid
        self.affiliation = row.affiliation
    }

    public init(givenName: String?, familyName: String, suffix: String? = nil, orcid: String? = nil, affiliation: String? = nil) {
        self.givenName = givenName
        self.familyName = familyName
        self.suffix = suffix
        self.orcid = orcid
        self.affiliation = affiliation
    }
}
