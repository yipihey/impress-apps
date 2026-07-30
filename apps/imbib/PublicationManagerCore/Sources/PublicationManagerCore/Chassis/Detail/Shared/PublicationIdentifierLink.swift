//
//  PublicationIdentifierLink.swift
//  PublicationManagerCore
//
//  Stage 5b (SPLIT rule) — the publication detail pane's identifier row, as
//  DATA.
//
//  The four identifier resolvers (DOI, arXiv, NASA ADS, PubMed) were written
//  out THREE times: macOS `InfoTab.identifiersSection`, iOS
//  `IOSInfoTab.identifiersSection`, and iOS `DetailView.moreMenu` (which had
//  only three of the four — PubMed silently absent from the More menu). Each
//  copy hardcoded the same URL templates. A resolver written per surface is a
//  resolver that drifts: the iOS copy already disagreed with macOS about
//  whether PubMed exists.
//
//  This file is the single declaration. Both chromes keep their own LAYOUT
//  (macOS: `FlowLayout` + `Link` + hover help + copy context menu; iOS: a
//  horizontal `ScrollView` of tappable buttons + a `Menu`), because that is
//  what genuinely differs between a pointer and a thumb.
//

import Foundation

/// One external identifier of a publication, with everything a chrome needs to
/// render and open it.
///
/// `Sendable` value type: it is derived from the store row, never held.
public struct PublicationIdentifierLink: Identifiable, Hashable, Sendable {

    /// The identifier scheme. Order of `allCases` IS the display order both
    /// platforms shipped (DOI, arXiv, ADS, PubMed).
    public enum Kind: String, CaseIterable, Sendable {
        case doi
        case arxiv
        case ads
        case pubmed

        /// Short label shown before the value ("DOI:", "arXiv:", …).
        public var label: String {
            switch self {
            case .doi: return "DOI"
            case .arxiv: return "arXiv"
            case .ads: return "ADS"
            case .pubmed: return "PubMed"
            }
        }

        /// macOS hover-help text, frozen from `InfoTab.identifiersSection`.
        public var openHelpText: String {
            switch self {
            case .doi: return "Open DOI resolver"
            case .arxiv: return "Open on arXiv"
            case .ads: return "Open on NASA ADS"
            case .pubmed: return "Open on PubMed"
            }
        }

        /// Menu-item title, frozen from iOS `DetailView.moreMenu`
        /// ("Open DOI" / "Open arXiv" / "Open ADS"). PubMed had no row there;
        /// it gets the same shape rather than staying missing.
        public var menuTitle: String { "Open \(label)" }

        /// The one place each scheme's URL template lives.
        public func urlString(for value: String) -> String {
            switch self {
            case .doi: return "https://doi.org/\(value)"
            case .arxiv: return "https://arxiv.org/abs/\(value)"
            case .ads: return "https://ui.adsabs.harvard.edu/abs/\(value)"
            case .pubmed: return "https://pubmed.ncbi.nlm.nih.gov/\(value)"
            }
        }
    }

    public let kind: Kind
    public let value: String

    public var id: String { kind.rawValue }
    public var label: String { kind.label }
    public var openHelpText: String { kind.openHelpText }
    public var menuTitle: String { kind.menuTitle }
    public var urlString: String { kind.urlString(for: value) }
    public var url: URL? { URL(string: urlString) }

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }
}

extension PublicationIdentifierLink {

    /// Every identifier this paper actually has, in the shipped display order.
    ///
    /// Empty strings are treated as absent — a `doi: ""` row used to render a
    /// link to `https://doi.org/`.
    public static func all(
        doi: String?, arxivID: String?, bibcode: String?, pmid: String?
    ) -> [PublicationIdentifierLink] {
        let pairs: [(Kind, String?)] = [
            (.doi, doi), (.arxiv, arxivID), (.ads, bibcode), (.pubmed, pmid),
        ]
        return pairs.compactMap { kind, value in
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                return nil
            }
            return PublicationIdentifierLink(kind: kind, value: value)
        }
    }

    public static func all(for publication: PublicationModel) -> [PublicationIdentifierLink] {
        all(
            doi: publication.doi, arxivID: publication.arxivID,
            bibcode: publication.bibcode, pmid: publication.pmid)
    }

    public static func all(for paper: any PaperRepresentable) -> [PublicationIdentifierLink] {
        all(doi: paper.doi, arxivID: paper.arxivID, bibcode: paper.bibcode, pmid: paper.pmid)
    }

    /// Whether the Identifiers section should render at all. Both chromes had
    /// their own four-way `||` for this.
    public static func any(for publication: PublicationModel) -> Bool {
        !all(for: publication).isEmpty
    }

    public static func any(for paper: any PaperRepresentable) -> Bool {
        !all(for: paper).isEmpty
    }
}
