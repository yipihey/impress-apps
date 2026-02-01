//
//  PDFResolutionTestCommand.swift
//  PDFResolutionTest
//
//  CLI entry point for PDF resolution testing.
//

import ArgumentParser
import Foundation

// MARK: - Main Command

@main
struct PDFResolutionTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf-resolution-test",
        abstract: "Test PDF resolution strategies against known fixtures.",
        version: "1.0.0"
    )

    // MARK: - Options

    @Option(name: .long, help: "Run fixtures for a specific DOI prefix (e.g., 10.1038)")
    var doiPrefix: String?

    @Option(name: .long, help: "Run fixtures for a specific publisher (e.g., Nature)")
    var publisher: String?

    @Option(name: .long, help: "Library proxy URL (e.g., https://stanford.idm.oclc.org/login?url=)")
    var proxy: String?

    @Option(name: .long, help: "Email for OpenAlex polite pool (higher rate limits)")
    var email: String?

    @Option(name: [.short, .long], help: "Output JSON report to file")
    var output: String?

    @Flag(name: .long, help: "Run all fixtures")
    var all = false

    @Flag(name: .long, help: "List available fixtures without running tests")
    var list = false

    @Flag(name: .long, help: "Show only summary (no detailed results)")
    var summary = false

    // MARK: - Run

    mutating func run() async throws {
        if list {
            listFixtures()
            return
        }

        // Create test runner
        let runner = TestRunner(proxyURL: proxy, email: email)

        // Determine which fixtures to run
        let results: [TestResult]

        if let prefix = doiPrefix {
            print("Running fixtures for DOI prefix: \(prefix)")
            results = await runner.run(doiPrefix: prefix)
        } else if let pub = publisher {
            print("Running fixtures for publisher: \(pub)")
            results = await runner.run(publisher: pub)
        } else if all {
            print("Running all fixtures...")
            results = await runner.runAll()
        } else {
            // Default: run all
            print("Running all fixtures (use --help for options)...")
            results = await runner.runAll()
        }

        let metrics = await runner.getMetrics()

        // Generate report
        if !summary {
            let consoleReport = ReportGenerator.generateConsoleReport(results: results, metrics: metrics)
            print(consoleReport)
        } else {
            printSummary(metrics: metrics)
        }

        // Write JSON if requested
        if let outputPath = output {
            do {
                let jsonData = try ReportGenerator.generateJSONReport(results: results, metrics: metrics)
                let url = URL(fileURLWithPath: outputPath)
                try jsonData.write(to: url)
                print("JSON report written to: \(outputPath)")
            } catch {
                print("Error writing JSON report: \(error.localizedDescription)")
            }
        }

        // Exit with appropriate code
        if metrics.successRate < 1.0 {
            throw ExitCode(1)
        }
    }

    // MARK: - Helpers

    private func listFixtures() {
        print("Available Test Fixtures")
        print("═══════════════════════════════════════════════════════════════\n")

        let byPublisher = Dictionary(grouping: TestFixtures.all) { $0.publisher }

        for (publisher, fixtures) in byPublisher.sorted(by: { $0.key < $1.key }) {
            print("\(publisher) (\(fixtures.count) fixtures):")
            for fixture in fixtures {
                let hasArxiv = fixture.hasArxiv ? " [arXiv]" : ""
                let hasOA = fixture.hasOpenAlex ? " [OpenAlex]" : ""
                print("  • \(fixture.doi)\(hasArxiv)\(hasOA)")
                print("    Expected: \(fixture.expectedSource.rawValue)")
                if let notes = fixture.notes {
                    print("    Notes: \(notes)")
                }
            }
            print()
        }

        print("───────────────────────────────────────────────────────────────")
        print("Total: \(TestFixtures.all.count) fixtures")
    }

    private func printSummary(metrics: TestMetrics) {
        print("\n═══════════════════════════════════════════════════════════════")
        print("                         SUMMARY                                ")
        print("═══════════════════════════════════════════════════════════════\n")
        print(String(format: "Success rate:     %.1f%% (%d/%d)",
                     metrics.successRate * 100,
                     metrics.successCount,
                     metrics.totalTests))
        print(String(format: "OpenAlex hit rate: %.1f%%", metrics.openAlexHitRate * 100))
        print(String(format: "CAPTCHA blocks:   %d", metrics.captchaEncounters))
        print(String(format: "Total duration:   %.2fs", metrics.totalDuration))
    }
}
