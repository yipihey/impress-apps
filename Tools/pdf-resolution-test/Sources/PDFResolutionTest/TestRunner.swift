//
//  TestRunner.swift
//  PDFResolutionTest
//
//  Orchestrates PDF resolution testing.
//

import Foundation

// MARK: - Test Runner

/// Orchestrates PDF resolution testing against known fixtures.
public actor TestRunner {

    private let validator: URLValidator
    private let openAlexClient: OpenAlexClient
    private let proxyURL: String?
    private var metrics = TestMetrics()

    public init(proxyURL: String? = nil, email: String? = nil) {
        self.validator = URLValidator()
        self.openAlexClient = OpenAlexClient(email: email)
        self.proxyURL = proxyURL
    }

    // MARK: - Test Execution

    /// Run all fixtures
    public func runAll() async -> [TestResult] {
        await run(fixtures: TestFixtures.all)
    }

    /// Run fixtures for a specific DOI prefix
    public func run(doiPrefix: String) async -> [TestResult] {
        await run(fixtures: TestFixtures.fixtures(forDOIPrefix: doiPrefix))
    }

    /// Run fixtures for a specific publisher
    public func run(publisher: String) async -> [TestResult] {
        await run(fixtures: TestFixtures.fixtures(forPublisher: publisher))
    }

    /// Run a custom set of fixtures
    public func run(fixtures: [TestFixture]) async -> [TestResult] {
        var results: [TestResult] = []

        for fixture in fixtures {
            let result = await runSingle(fixture)
            metrics.record(result)
            results.append(result)
        }

        return results
    }

    /// Run a single fixture
    public func runSingle(_ fixture: TestFixture) async -> TestResult {
        let startTime = Date()
        var notes: [String] = []

        // 1. Lookup OpenAlex OA locations
        var openAlexResult: OpenAlexLookupResult?
        do {
            openAlexResult = try await openAlexClient.fetchOALocations(doi: fixture.doi)
            if let best = openAlexResult?.bestPDFURL {
                notes.append("OpenAlex: Found OA URL: \(best.absoluteString)")
            } else {
                notes.append("OpenAlex: No OA PDF found")
            }
        } catch {
            notes.append("OpenAlex: Error - \(error.localizedDescription)")
        }

        // 2. Construct publisher PDF URL
        var directResult: URLValidationResult?
        var proxiedResult: URLValidationResult?

        if let constructedURL = DefaultPublisherRules.constructPDFURL(forDOI: fixture.doi) {
            notes.append("Publisher: Constructed URL: \(constructedURL.absoluteString)")

            // 3. Validate with/without proxy
            if let proxyURL = proxyURL {
                let (direct, proxied) = await validator.validateWithProxyRace(
                    url: constructedURL,
                    proxyURL: proxyURL
                )
                directResult = direct
                proxiedResult = proxied
                notes.append("Direct: \(direct)")
                notes.append("Proxied: \(proxied)")
            } else {
                directResult = await validator.validate(url: constructedURL)
                notes.append("Direct: \(directResult!)")
            }
        } else {
            notes.append("Publisher: No URL pattern for DOI prefix")
        }

        // 4. Check arXiv if applicable
        var arxivResult: URLValidationResult?
        if fixture.hasArxiv {
            if let arxivID = extractArXivID(fromDOI: fixture.doi) {
                let arxivURL = URL(string: "https://arxiv.org/pdf/\(arxivID).pdf")!
                arxivResult = await validator.validate(url: arxivURL)
                notes.append("arXiv: \(arxivResult!)")
            }
        }

        // 5. Determine actual source
        let actualSource = determineActualSource(
            directResult: directResult,
            proxiedResult: proxiedResult,
            openAlexResult: openAlexResult,
            arxivResult: arxivResult,
            fixture: fixture
        )

        let endTime = Date()

        return TestResult(
            fixture: fixture,
            startTime: startTime,
            endTime: endTime,
            directResult: directResult,
            proxiedResult: proxiedResult,
            openAlexResult: openAlexResult,
            arxivResult: arxivResult,
            actualSource: actualSource,
            notes: notes
        )
    }

    // MARK: - Source Determination

    private func determineActualSource(
        directResult: URLValidationResult?,
        proxiedResult: URLValidationResult?,
        openAlexResult: OpenAlexLookupResult?,
        arxivResult: URLValidationResult?,
        fixture: TestFixture
    ) -> ExpectedSource? {
        // Check arXiv first (if it's the primary source)
        if case .validPDF = arxivResult {
            if fixture.expectedSource == .arxiv {
                return .arxiv
            }
        }

        // Check OpenAlex OA
        if let openAlex = openAlexResult, openAlex.bestPDFURL != nil {
            // If OpenAlex has OA and we expect it, that's the source
            if fixture.expectedSource == .openAlex {
                return .openAlex
            }
            // OpenAlex OA might be preferred even if we expected proxy
            return .openAlex
        }

        // Check direct publisher
        if case .validPDF = directResult {
            return .publisherDirect
        }

        // Check proxied
        if case .validPDF = proxiedResult {
            return .publisherProxy
        }

        // Fall back to arXiv if available
        if case .validPDF = arxivResult {
            return .arxiv
        }

        return .unavailable
    }

    // MARK: - Helpers

    private func extractArXivID(fromDOI doi: String) -> String? {
        let prefix = "10.48550/arXiv."
        guard doi.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(doi.dropFirst(prefix.count))
    }

    // MARK: - Metrics

    public func getMetrics() -> TestMetrics {
        metrics
    }

    public func resetMetrics() {
        metrics = TestMetrics()
    }
}
