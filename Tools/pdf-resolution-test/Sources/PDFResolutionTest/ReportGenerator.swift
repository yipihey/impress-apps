//
//  ReportGenerator.swift
//  PDFResolutionTest
//
//  Generates reports from test results.
//

import Foundation

// MARK: - Report Generator

/// Generates reports from PDF resolution test results.
public struct ReportGenerator {

    // MARK: - Console Report

    /// Generate a console-friendly report
    public static func generateConsoleReport(results: [TestResult], metrics: TestMetrics) -> String {
        var output = ""

        output += "═══════════════════════════════════════════════════════════════\n"
        output += "                    PDF RESOLUTION TEST REPORT                  \n"
        output += "═══════════════════════════════════════════════════════════════\n\n"

        // Summary
        output += "SUMMARY\n"
        output += "───────────────────────────────────────────────────────────────\n"
        output += String(format: "Total tests:      %d\n", metrics.totalTests)
        output += String(format: "Successes:        %d (%.1f%%)\n", metrics.successCount, metrics.successRate * 100)
        output += String(format: "Failures:         %d\n", metrics.failureCount)
        output += String(format: "Total duration:   %.2fs\n", metrics.totalDuration)
        output += "\n"

        // OpenAlex stats
        output += "OPENALEX\n"
        output += "───────────────────────────────────────────────────────────────\n"
        output += String(format: "OA hits:          %d\n", metrics.openAlexHits)
        output += String(format: "OA misses:        %d\n", metrics.openAlexMisses)
        output += String(format: "Hit rate:         %.1f%%\n", metrics.openAlexHitRate * 100)
        output += "\n"

        // Access stats
        output += "ACCESS METHODS\n"
        output += "───────────────────────────────────────────────────────────────\n"
        output += String(format: "Direct successes: %d\n", metrics.directSuccesses)
        output += String(format: "Direct failures:  %d\n", metrics.directFailures)
        output += String(format: "Proxy successes:  %d\n", metrics.proxySuccesses)
        output += String(format: "Proxy failures:   %d\n", metrics.proxyFailures)
        output += String(format: "CAPTCHA blocks:   %d\n", metrics.captchaEncounters)
        output += "\n"

        // By publisher
        if !metrics.resultsByPublisher.isEmpty {
            output += "BY PUBLISHER\n"
            output += "───────────────────────────────────────────────────────────────\n"
            for (publisher, pubMetrics) in metrics.resultsByPublisher.sorted(by: { $0.key < $1.key }) {
                output += String(format: "%-15s %d/%d (%.0f%%)\n",
                               publisher,
                               pubMetrics.successCount,
                               pubMetrics.totalTests,
                               pubMetrics.successRate * 100)
            }
            output += "\n"
        }

        // Individual results
        output += "DETAILED RESULTS\n"
        output += "═══════════════════════════════════════════════════════════════\n\n"

        for result in results {
            let statusIcon = result.success ? "✓" : "✗"
            output += "\(statusIcon) \(result.fixture.doi)\n"
            output += "  Publisher: \(result.fixture.publisher)\n"
            output += "  Expected:  \(result.fixture.expectedSource.rawValue)\n"
            output += "  Actual:    \(result.actualSource?.rawValue ?? "unknown")\n"
            output += "  Duration:  \(String(format: "%.2fs", result.duration))\n"

            if !result.notes.isEmpty {
                output += "  Notes:\n"
                for note in result.notes {
                    output += "    - \(note)\n"
                }
            }
            output += "\n"
        }

        return output
    }

    // MARK: - JSON Report

    /// Generate a JSON report
    public static func generateJSONReport(results: [TestResult], metrics: TestMetrics) throws -> Data {
        let report = JSONReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            summary: JSONSummary(
                totalTests: metrics.totalTests,
                successes: metrics.successCount,
                failures: metrics.failureCount,
                successRate: metrics.successRate,
                totalDuration: metrics.totalDuration
            ),
            openAlex: JSONOpenAlexStats(
                hits: metrics.openAlexHits,
                misses: metrics.openAlexMisses,
                hitRate: metrics.openAlexHitRate
            ),
            access: JSONAccessStats(
                directSuccesses: metrics.directSuccesses,
                directFailures: metrics.directFailures,
                proxySuccesses: metrics.proxySuccesses,
                proxyFailures: metrics.proxyFailures,
                captchaEncounters: metrics.captchaEncounters
            ),
            byPublisher: metrics.resultsByPublisher.mapValues { pubMetrics in
                JSONPublisherStats(
                    total: pubMetrics.totalTests,
                    successes: pubMetrics.successCount,
                    successRate: pubMetrics.successRate
                )
            },
            results: results.map { result in
                JSONTestResult(
                    doi: result.fixture.doi,
                    publisher: result.fixture.publisher,
                    expected: result.fixture.expectedSource.rawValue,
                    actual: result.actualSource?.rawValue ?? "unknown",
                    success: result.success,
                    duration: result.duration,
                    directResult: result.directResult?.description,
                    proxiedResult: result.proxiedResult?.description,
                    openAlexURL: result.openAlexResult?.bestPDFURL?.absoluteString,
                    notes: result.notes
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
}

// MARK: - JSON Types

private struct JSONReport: Encodable {
    let timestamp: String
    let summary: JSONSummary
    let openAlex: JSONOpenAlexStats
    let access: JSONAccessStats
    let byPublisher: [String: JSONPublisherStats]
    let results: [JSONTestResult]
}

private struct JSONSummary: Encodable {
    let totalTests: Int
    let successes: Int
    let failures: Int
    let successRate: Double
    let totalDuration: TimeInterval
}

private struct JSONOpenAlexStats: Encodable {
    let hits: Int
    let misses: Int
    let hitRate: Double
}

private struct JSONAccessStats: Encodable {
    let directSuccesses: Int
    let directFailures: Int
    let proxySuccesses: Int
    let proxyFailures: Int
    let captchaEncounters: Int
}

private struct JSONPublisherStats: Encodable {
    let total: Int
    let successes: Int
    let successRate: Double
}

private struct JSONTestResult: Encodable {
    let doi: String
    let publisher: String
    let expected: String
    let actual: String
    let success: Bool
    let duration: TimeInterval
    let directResult: String?
    let proxiedResult: String?
    let openAlexURL: String?
    let notes: [String]
}
