//
//  BibTeXBenchmark.swift
//  PublicationManagerCore
//
//  Benchmark utilities for comparing parser performance.
//

import Foundation

// MARK: - Benchmark Utilities

/// Utilities for benchmarking BibTeX parsing performance
public enum BibTeXBenchmark {

    /// Generate test BibTeX content with specified number of entries
    public static func generateEntries(count: Int) -> String {
        var result = ""
        for i in 0..<count {
            result += """
            @article{Entry\(i),
                author = {Author \(i)},
                title = {Title of Paper Number \(i)},
                year = {2024},
                journal = {Journal \(i % 10)},
                volume = {\(i % 50)},
                pages = {1--10},
                doi = {10.1234/test.\(i)}
            }

            """
        }
        return result
    }

    /// Simple test entry
    public static let simpleEntry = """
    @article{Smith2024,
        author = {John Smith},
        title = {A Great Paper},
        year = {2024},
        journal = {Nature}
    }
    """

    /// Complex test entry
    public static let complexEntry = """
    @article{Einstein1905,
        author = {Albert Einstein},
        title = {Zur Elektrodynamik bewegter K{\\"o}rper},
        journal = {Annalen der Physik},
        volume = {322},
        number = {10},
        pages = {891--921},
        year = {1905},
        doi = {10.1002/andp.19053221004},
        abstract = {The paper that introduced special relativity.}
    }
    """

    /// Measure parsing time for given content
    public static func measureParsing(
        content: String,
        iterations: Int = 100,
        using parser: any BibTeXParsing
    ) -> BenchmarkResult {
        var times: [Double] = []

        // Warmup
        for _ in 0..<10 {
            _ = try? parser.parseEntries(content)
        }

        // Measure
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try? parser.parseEntries(content)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            times.append(elapsed)
        }

        return BenchmarkResult(times: times)
    }

    /// Run a complete benchmark suite
    public static func runSuite(parser: any BibTeXParsing, label: String) -> [String: BenchmarkResult] {
        var results: [String: BenchmarkResult] = [:]

        print("Running \(label) benchmarks...")

        // Single entries
        print("  - Single simple entry...")
        results["single_simple"] = measureParsing(content: simpleEntry, iterations: 1000, using: parser)

        print("  - Single complex entry...")
        results["single_complex"] = measureParsing(content: complexEntry, iterations: 1000, using: parser)

        // Multiple entries
        for count in [10, 100, 1000] {
            print("  - \(count) entries...")
            let content = generateEntries(count: count)
            let iterations = count >= 1000 ? 10 : (count >= 100 ? 50 : 100)
            results["many_\(count)"] = measureParsing(content: content, iterations: iterations, using: parser)
        }

        return results
    }

    /// Compare two parsers
    public static func compare(
        swift swiftParser: any BibTeXParsing,
        rust rustParser: any BibTeXParsing
    ) {
        let swiftResults = runSuite(parser: swiftParser, label: "Swift")
        let rustResults = runSuite(parser: rustParser, label: "Rust")

        print("\n" + String(repeating: "=", count: 70))
        print("BENCHMARK RESULTS")
        print(String(repeating: "=", count: 70))
        print(String(format: "%-20s %15s %15s %10s", "Test", "Swift", "Rust", "Speedup"))
        print(String(repeating: "-", count: 70))

        let tests = ["single_simple", "single_complex", "many_10", "many_100", "many_1000"]
        for test in tests {
            if let swift = swiftResults[test], let rust = rustResults[test] {
                let speedup = swift.median / rust.median
                print(String(format: "%-20s %15s %15s %9.2fx",
                    test,
                    swift.formatted,
                    rust.formatted,
                    speedup
                ))
            }
        }
        print(String(repeating: "=", count: 70))
    }
}

// MARK: - Benchmark Result

/// Result of a benchmark run
public struct BenchmarkResult {
    public let times: [Double]

    public var min: Double { times.min() ?? 0 }
    public var max: Double { times.max() ?? 0 }
    public var mean: Double { times.reduce(0, +) / Double(times.count) }
    public var median: Double {
        let sorted = times.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    public var formatted: String {
        formatTime(median)
    }

    private func formatTime(_ seconds: Double) -> String {
        if seconds < 0.000001 {
            return String(format: "%.2f ns", seconds * 1_000_000_000)
        } else if seconds < 0.001 {
            return String(format: "%.2f µs", seconds * 1_000_000)
        } else if seconds < 1 {
            return String(format: "%.2f ms", seconds * 1000)
        } else {
            return String(format: "%.2f s", seconds)
        }
    }
}
