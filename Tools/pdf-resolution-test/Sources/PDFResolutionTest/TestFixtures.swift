//
//  TestFixtures.swift
//  PDFResolutionTest
//
//  Known DOIs with expected outcomes for testing PDF resolution.
//

import Foundation

// MARK: - Test Fixtures

/// Provides test fixtures for different publishers and access scenarios.
public struct TestFixtures {

    /// All available test fixtures
    public static let all: [TestFixture] = [
        // IOP Publishing (AAS Journals - ApJ, AJ, etc.)
        TestFixture(
            doi: "10.3847/1538-4357/ac7c74",
            title: "The Morphology of Galaxies in the Horizon-AGN Simulation",
            publisher: "IOP",
            expectedSource: .publisherProxy,
            hasArxiv: true,
            hasOpenAlex: true,
            notes: "AAS journal, IOP hosted"
        ),
        TestFixture(
            doi: "10.3847/2041-8213/ad0e00",
            title: "A Massive Quiescent Galaxy at z=4.658",
            publisher: "IOP",
            expectedSource: .publisherProxy,
            hasArxiv: true,
            hasOpenAlex: true,
            notes: "ApJL paper"
        ),
        TestFixture(
            doi: "10.1088/0004-637X/802/2/137",
            title: "IllustrisTNG Simulations",
            publisher: "IOP",
            expectedSource: .publisherProxy,
            hasArxiv: true,
            hasOpenAlex: true,
            notes: "Classic ApJ article"
        ),

        // APS (Physical Review journals)
        TestFixture(
            doi: "10.1103/PhysRevLett.116.061102",
            title: "Observation of Gravitational Waves from a Binary Black Hole Merger",
            publisher: "APS",
            expectedSource: .publisherProxy,
            hasArxiv: true,
            hasOpenAlex: true,
            notes: "LIGO detection paper, PRL"
        ),
        TestFixture(
            doi: "10.1103/PhysRevD.105.023520",
            title: "Cosmological Parameters from Planck",
            publisher: "APS",
            expectedSource: .publisherProxy,
            hasArxiv: true,
            hasOpenAlex: true,
            notes: "PRD paper"
        ),

        // Nature Publishing
        TestFixture(
            doi: "10.1038/s41586-024-07386-0",
            title: "Black Hole Image from Event Horizon Telescope",
            publisher: "Nature",
            expectedSource: .publisherProxy,
            hasArxiv: false,
            hasOpenAlex: true,
            notes: "Nature main journal, usually no arXiv"
        ),
        TestFixture(
            doi: "10.1038/s41550-022-01873-6",
            title: "Astronomy Research in Nature Astronomy",
            publisher: "Nature",
            expectedSource: .publisherProxy,
            hasArxiv: true,
            hasOpenAlex: true,
            notes: "Nature Astronomy"
        ),

        // Science (AAAS) - High CAPTCHA risk
        TestFixture(
            doi: "10.1126/science.aau4096",
            title: "Science Magazine Article",
            publisher: "Science",
            expectedSource: .unavailable,
            hasArxiv: false,
            hasOpenAlex: true,
            notes: "Science often requires CAPTCHA"
        ),

        // Elsevier - High CAPTCHA risk, prefer OpenAlex
        TestFixture(
            doi: "10.1016/j.physrep.2020.02.001",
            title: "Physics Reports Article",
            publisher: "Elsevier",
            expectedSource: .openAlex,
            hasArxiv: true,
            hasOpenAlex: true,
            notes: "Elsevier, high CAPTCHA risk"
        ),

        // A&A (Astronomy & Astrophysics)
        TestFixture(
            doi: "10.1051/0004-6361/202243048",
            title: "A&A Article on Galaxy Evolution",
            publisher: "A&A",
            expectedSource: .publisherDirect,
            hasArxiv: true,
            hasOpenAlex: true,
            notes: "A&A is usually open access"
        ),

        // MNRAS (Oxford/Wiley)
        TestFixture(
            doi: "10.1093/mnras/stac3593",
            title: "MNRAS Galaxy Study",
            publisher: "MNRAS",
            expectedSource: .publisherProxy,
            hasArxiv: true,
            hasOpenAlex: true,
            notes: "MNRAS via Oxford"
        ),

        // arXiv-only (no publisher DOI)
        TestFixture(
            doi: "10.48550/arXiv.2311.12345",
            title: "arXiv Preprint",
            publisher: "arXiv",
            expectedSource: .arxiv,
            hasArxiv: true,
            hasOpenAlex: true,
            notes: "arXiv DOI, no publisher version"
        ),

        // Open Access examples
        TestFixture(
            doi: "10.3390/galaxies10010001",
            title: "MDPI Open Access Galaxy Article",
            publisher: "MDPI",
            expectedSource: .publisherDirect,
            hasArxiv: false,
            hasOpenAlex: true,
            notes: "MDPI is fully open access"
        ),
    ]

    /// Fixtures for a specific publisher (by DOI prefix)
    public static func fixtures(forDOIPrefix prefix: String) -> [TestFixture] {
        all.filter { $0.doi.hasPrefix(prefix) }
    }

    /// Fixtures for a specific publisher name
    public static func fixtures(forPublisher publisher: String) -> [TestFixture] {
        let normalized = publisher.lowercased()
        return all.filter { $0.publisher.lowercased() == normalized }
    }

    /// Fixtures that expect arXiv as the source
    public static var arxivFixtures: [TestFixture] {
        all.filter { $0.expectedSource == .arxiv }
    }

    /// Fixtures that expect OpenAlex OA
    public static var openAlexFixtures: [TestFixture] {
        all.filter { $0.expectedSource == .openAlex }
    }

    /// Fixtures that require proxy access
    public static var proxyFixtures: [TestFixture] {
        all.filter { $0.expectedSource == .publisherProxy }
    }
}

// MARK: - Publisher Rules

/// Default publisher rules for PDF resolution
public struct DefaultPublisherRules {

    public static let rules: [PublisherInfo] = [
        PublisherInfo(
            id: "iop-aas",
            name: "IOP Publishing (AAS Journals)",
            doiPrefixes: ["10.3847"],
            pdfURLPattern: "https://iopscience.iop.org/article/{doi}/pdf",
            requiresProxy: true,
            captchaRisk: .low,
            notes: "AAS journals hosted by IOP"
        ),
        PublisherInfo(
            id: "iop-legacy",
            name: "IOP Publishing (Legacy ApJ)",
            doiPrefixes: ["10.1086"],
            pdfURLPattern: "https://iopscience.iop.org/article/{doi}/pdf",
            requiresProxy: true,
            captchaRisk: .low,
            notes: "Legacy ApJ DOIs"
        ),
        PublisherInfo(
            id: "iop-journals",
            name: "IOP Publishing (Journals)",
            doiPrefixes: ["10.1088"],
            pdfURLPattern: "https://iopscience.iop.org/article/{doi}/pdf",
            requiresProxy: true,
            captchaRisk: .low,
            notes: "IOP physics journals"
        ),
        PublisherInfo(
            id: "aps",
            name: "American Physical Society",
            doiPrefixes: ["10.1103"],
            pdfURLPattern: "https://link.aps.org/pdf/{doi}",
            requiresProxy: true,
            captchaRisk: .low,
            notes: "Physical Review journals"
        ),
        PublisherInfo(
            id: "nature",
            name: "Nature Publishing Group",
            doiPrefixes: ["10.1038"],
            pdfURLPattern: "https://www.nature.com/articles/{articleID}.pdf",
            requiresProxy: true,
            captchaRisk: .medium,
            notes: "articleID is the part after 10.1038/"
        ),
        PublisherInfo(
            id: "science",
            name: "Science (AAAS)",
            doiPrefixes: ["10.1126"],
            pdfURLPattern: "https://www.science.org/doi/pdf/{doi}",
            requiresProxy: true,
            captchaRisk: .high,
            notes: "High CAPTCHA risk, consider browser fallback"
        ),
        PublisherInfo(
            id: "elsevier",
            name: "Elsevier",
            doiPrefixes: ["10.1016"],
            pdfURLPattern: nil,
            requiresProxy: true,
            captchaRisk: .high,
            preferOpenAlex: true,
            notes: "No predictable URL pattern, use OpenAlex OA"
        ),
        PublisherInfo(
            id: "wiley",
            name: "Wiley",
            doiPrefixes: ["10.1002", "10.1111"],
            pdfURLPattern: nil,
            requiresProxy: true,
            captchaRisk: .medium,
            preferOpenAlex: true,
            notes: "Complex URL pattern, prefer OpenAlex"
        ),
        PublisherInfo(
            id: "aanda",
            name: "Astronomy & Astrophysics",
            doiPrefixes: ["10.1051"],
            pdfURLPattern: "https://www.aanda.org/articles/{articleRef}/pdf",
            requiresProxy: false,
            captchaRisk: .low,
            notes: "Usually open access"
        ),
        PublisherInfo(
            id: "mnras",
            name: "MNRAS (Oxford)",
            doiPrefixes: ["10.1093/mnras"],
            pdfURLPattern: nil,
            requiresProxy: true,
            captchaRisk: .medium,
            preferOpenAlex: true,
            notes: "Oxford Academic, complex auth"
        ),
        PublisherInfo(
            id: "mdpi",
            name: "MDPI",
            doiPrefixes: ["10.3390"],
            pdfURLPattern: nil,
            requiresProxy: false,
            captchaRisk: .low,
            preferOpenAlex: true,
            notes: "Fully open access, use OpenAlex URL"
        ),
        PublisherInfo(
            id: "arxiv",
            name: "arXiv",
            doiPrefixes: ["10.48550/arXiv"],
            pdfURLPattern: "https://arxiv.org/pdf/{arxivID}.pdf",
            requiresProxy: false,
            captchaRisk: .low,
            notes: "arXiv DOIs, always accessible"
        ),
    ]

    /// Find publisher info for a DOI
    public static func publisher(forDOI doi: String) -> PublisherInfo? {
        for rule in rules {
            for prefix in rule.doiPrefixes {
                if doi.hasPrefix(prefix) {
                    return rule
                }
            }
        }
        return nil
    }

    /// Construct PDF URL for a DOI using known patterns
    public static func constructPDFURL(forDOI doi: String) -> URL? {
        guard let publisher = publisher(forDOI: doi),
              let pattern = publisher.pdfURLPattern else {
            return nil
        }

        var urlString = pattern.replacingOccurrences(of: "{doi}", with: doi)

        // Handle special cases
        if publisher.id == "nature" {
            // Extract article ID from DOI
            let articleID = String(doi.dropFirst("10.1038/".count))
            urlString = urlString.replacingOccurrences(of: "{articleID}", with: articleID)
        } else if publisher.id == "arxiv" {
            // Extract arXiv ID from DOI
            if let arxivID = extractArXivID(fromDOI: doi) {
                urlString = urlString.replacingOccurrences(of: "{arxivID}", with: arxivID)
            } else {
                return nil
            }
        }

        return URL(string: urlString)
    }

    private static func extractArXivID(fromDOI doi: String) -> String? {
        // DOI format: 10.48550/arXiv.2311.12345
        let prefix = "10.48550/arXiv."
        guard doi.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(doi.dropFirst(prefix.count))
    }
}
