//
//  PerformanceTestFixtures.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-08.
//

import Foundation
import CoreData
@testable import PublicationManagerCore

/// Factory for generating realistic CDPublication entries in bulk for performance testing.
@MainActor
public enum PerformanceTestFixtures {

    // MARK: - Data Pools

    /// Realistic author last names
    private static let lastNames = [
        "Einstein", "Feynman", "Hawking", "Curie", "Newton",
        "Maxwell", "Bohr", "Dirac", "Heisenberg", "Schrödinger",
        "Planck", "Fermi", "Pauli", "Born", "Rutherford",
        "Thomson", "Oppenheimer", "Sagan", "Penrose", "Witten",
        "Smith", "Jones", "Brown", "Wilson", "Taylor",
        "Anderson", "Thomas", "Jackson", "White", "Harris",
        "Martin", "Garcia", "Miller", "Davis", "Rodriguez"
    ]

    /// Realistic author first names
    private static let firstNames = [
        "Albert", "Richard", "Stephen", "Marie", "Isaac",
        "James", "Niels", "Paul", "Werner", "Erwin",
        "Max", "Enrico", "Wolfgang", "Lise", "Ernest",
        "J. J.", "Robert", "Carl", "Roger", "Edward",
        "John", "Sarah", "Michael", "Emily", "David",
        "Jennifer", "Robert", "Lisa", "William", "Patricia",
        "Charles", "Linda", "Christopher", "Elizabeth", "Daniel"
    ]

    /// Realistic title prefixes
    private static let titlePrefixes = [
        "On the", "A Study of", "Observations of", "Theory of",
        "Analysis of", "Evidence for", "Discovery of", "Properties of",
        "Measurements of", "Investigation of", "Detection of",
        "Constraints on", "Simulations of", "Modeling of",
        "New Results on", "First Detection of", "Spectroscopy of"
    ]

    /// Realistic title subjects
    private static let titleSubjects = [
        "Quantum Entanglement", "Black Hole Mergers", "Dark Matter",
        "Gravitational Waves", "Exoplanet Atmospheres", "Cosmic Rays",
        "Neutron Stars", "Supernova Remnants", "Galaxy Clusters",
        "Active Galactic Nuclei", "Star Formation", "Molecular Clouds",
        "Stellar Evolution", "Solar Flares", "Planetary Nebulae",
        "White Dwarfs", "Gamma Ray Bursts", "Fast Radio Bursts",
        "Pulsar Timing", "Interstellar Medium", "Cosmic Microwave Background"
    ]

    /// Realistic journal names
    private static let journals = [
        "The Astrophysical Journal", "Monthly Notices of the RAS",
        "Astronomy & Astrophysics", "Nature", "Science",
        "Physical Review Letters", "Physical Review D",
        "Journal of Cosmology and Astroparticle Physics",
        "The Astronomical Journal", "Publications of the ASP",
        "ApJ Letters", "MNRAS Letters", "Nature Astronomy"
    ]

    /// Entry types with weights for realistic distribution
    private static let entryTypes = [
        "article", "article", "article", "article", "article",  // 50%
        "inproceedings", "inproceedings",  // 20%
        "phdthesis", "mastersthesis",  // 20%
        "book"  // 10%
    ]

    // MARK: - Publication Generation

    /// Generate publications with realistic variation.
    ///
    /// - Parameters:
    ///   - count: Number of publications to create
    ///   - context: The managed object context
    /// - Returns: Array of created CDPublication objects
    public static func createPublications(
        count: Int,
        in context: NSManagedObjectContext
    ) -> [CDPublication] {
        var publications: [CDPublication] = []
        publications.reserveCapacity(count)

        for i in 0..<count {
            let pub = createPublication(index: i, in: context)
            publications.append(pub)
        }

        return publications
    }

    /// Generate publications with many authors each (stress test author formatting).
    ///
    /// - Parameters:
    ///   - count: Number of publications to create
    ///   - authorsPerPub: Number of authors per publication
    ///   - context: The managed object context
    /// - Returns: Array of created CDPublication objects
    public static func createPublicationsWithManyAuthors(
        count: Int,
        authorsPerPub: Int,
        in context: NSManagedObjectContext
    ) -> [CDPublication] {
        var publications: [CDPublication] = []
        publications.reserveCapacity(count)

        for i in 0..<count {
            let pub = createPublication(index: i, authorCount: authorsPerPub, in: context)
            publications.append(pub)
        }

        return publications
    }

    /// Create a single publication with realistic data.
    private static func createPublication(
        index: Int,
        authorCount: Int? = nil,
        in context: NSManagedObjectContext
    ) -> CDPublication {
        let pub = CDPublication(context: context)

        // Core identity
        pub.id = UUID()
        pub.entryType = entryTypes[index % entryTypes.count]

        // Generate title
        let titlePrefix = titlePrefixes[index % titlePrefixes.count]
        let titleSubject = titleSubjects[(index * 7) % titleSubjects.count]
        let title = "\(titlePrefix) \(titleSubject) in \(generateRegionSuffix(for: index))"
        pub.title = title

        // Generate authors (1-10 if not specified)
        let numAuthors = authorCount ?? ((index % 10) + 1)
        let authorString = generateAuthors(count: numAuthors, seed: index)
        pub.fields["author"] = authorString

        // Generate cite key
        let firstAuthor = lastNames[index % lastNames.count]
        let year = 2000 + (index % 25)
        let titleWord = titleSubject.components(separatedBy: " ").first ?? "Study"
        pub.citeKey = "\(firstAuthor)\(year)\(titleWord)"

        // Year
        pub.year = Int16(year)

        // Journal/venue (for articles)
        if pub.entryType == "article" {
            pub.fields["journal"] = journals[index % journals.count]
            pub.fields["volume"] = String((index % 900) + 100)
            pub.fields["pages"] = "\((index % 900) + 1)-\((index % 900) + 15)"
        }

        // DOI (most papers have one)
        if index % 5 != 4 {  // 80% have DOI
            pub.doi = "10.1234/test.\(index)"
        }

        // arXiv ID (about 60%)
        if index % 5 < 3 {
            let arxivNum = String(format: "%04d.%05d", (index / 100) + 2301, index % 100000)
            pub.arxivIDNormalized = arxivNum
            pub.fields["eprint"] = arxivNum
        }

        // Abstract (realistic length variation)
        let abstractLength = (index % 5) + 2  // 2-6 sentences
        pub.abstract = generateAbstract(sentences: abstractLength, seed: index)

        // Dates
        let baseDate = Date()
        let daysAgo = TimeInterval((index % 365) * 24 * 60 * 60)
        pub.dateAdded = baseDate.addingTimeInterval(-daysAgo)
        pub.dateModified = baseDate.addingTimeInterval(-daysAgo / 2)

        // Read status (30% read)
        pub.isRead = (index % 10) < 3

        // Citation count (realistic distribution: most low, some high)
        if index % 20 == 0 {
            pub.citationCount = Int32((index % 500) + 100)  // High citation papers
        } else {
            pub.citationCount = Int32(index % 50)  // Normal
        }

        // Categories for arXiv papers
        if pub.arxivIDNormalized != nil {
            pub.fields["primaryclass"] = generateCategory(for: index)
        }

        return pub
    }

    // MARK: - Helper Methods

    private static func generateAuthors(count: Int, seed: Int) -> String {
        var authors: [String] = []
        for i in 0..<count {
            let lastName = lastNames[(seed + i * 3) % lastNames.count]
            let firstName = firstNames[(seed + i * 7) % firstNames.count]
            authors.append("\(lastName), \(firstName)")
        }
        return authors.joined(separator: " and ")
    }

    private static func generateRegionSuffix(for index: Int) -> String {
        let regions = ["NGC \(index % 9999 + 1)", "the Galactic Center",
                       "M\(index % 110 + 1)", "the Local Group",
                       "High-Redshift Sources", "the Solar Neighborhood",
                       "the Milky Way Halo", "Nearby Galaxies"]
        return regions[index % regions.count]
    }

    private static func generateAbstract(sentences: Int, seed: Int) -> String {
        let templates = [
            "We present new observations of {subject} using {instrument}.",
            "In this paper, we analyze data from {survey} to constrain {subject}.",
            "We report the detection of {phenomenon} in {location}.",
            "Our results suggest that {subject} plays a crucial role in {process}.",
            "We find evidence for {phenomenon} with a significance of {sigma} sigma.",
            "These findings have implications for our understanding of {subject}."
        ]

        var abstract: [String] = []
        for i in 0..<sentences {
            let template = templates[(seed + i) % templates.count]
            let filled = template
                .replacingOccurrences(of: "{subject}", with: titleSubjects[seed % titleSubjects.count])
                .replacingOccurrences(of: "{instrument}", with: ["HST", "JWST", "Chandra", "ALMA"][i % 4])
                .replacingOccurrences(of: "{survey}", with: ["SDSS", "2MASS", "Gaia", "Pan-STARRS"][i % 4])
                .replacingOccurrences(of: "{phenomenon}", with: ["variability", "emission", "absorption"][i % 3])
                .replacingOccurrences(of: "{location}", with: generateRegionSuffix(for: seed + i))
                .replacingOccurrences(of: "{process}", with: ["galaxy evolution", "star formation", "chemical enrichment"][i % 3])
                .replacingOccurrences(of: "{sigma}", with: String((seed % 5) + 3))
            abstract.append(filled)
        }

        return abstract.joined(separator: " ")
    }

    private static func generateCategory(for index: Int) -> String {
        let categories = [
            "astro-ph.GA", "astro-ph.CO", "astro-ph.HE", "astro-ph.SR",
            "astro-ph.EP", "astro-ph.IM", "gr-qc", "hep-th",
            "physics.space-ph", "cs.LG"
        ]
        return categories[index % categories.count]
    }

    // MARK: - Cleanup

    /// Delete all publications from the context.
    public static func cleanup(in context: NSManagedObjectContext) {
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        if let publications = try? context.fetch(request) {
            for pub in publications {
                context.delete(pub)
            }
        }
    }
}
