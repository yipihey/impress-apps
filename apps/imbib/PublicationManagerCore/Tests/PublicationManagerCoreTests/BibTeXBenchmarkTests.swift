//
//  BibTeXBenchmarkTests.swift
//  PublicationManagerCoreTests
//
//  Benchmark tests for BibTeX parsing performance.
//

import Testing
import Foundation
@testable import PublicationManagerCore

// MARK: - Benchmark Tests

@Suite("BibTeX Parser Benchmarks")
struct BibTeXBenchmarkTests {

    static func generateEntries(count: Int) -> String {
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

    static let simpleEntry = """
    @article{Smith2024,
        author = {John Smith},
        title = {A Great Paper},
        year = {2024},
        journal = {Nature}
    }
    """

    static let complexEntry = """
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

    static func measure(content: String, iterations: Int, parser: BibTeXParser) -> (min: Double, median: Double, max: Double) {
        var times: [Double] = []

        // Warmup
        for _ in 0..<min(10, iterations / 10) {
            _ = try? parser.parseEntries(content)
        }

        // Measure
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try? parser.parseEntries(content)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            times.append(elapsed)
        }

        times.sort()
        let mid = times.count / 2
        let median = times.count % 2 == 0 ? (times[mid-1] + times[mid]) / 2 : times[mid]

        return (times.first!, median, times.last!)
    }

    static func formatTime(_ seconds: Double) -> String {
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

    @Test("Swift parser single entry performance")
    func swiftSingleEntry() throws {
        let parser = BibTeXParser()

        let simpleResult = Self.measure(content: Self.simpleEntry, iterations: 1000, parser: parser)
        let complexResult = Self.measure(content: Self.complexEntry, iterations: 1000, parser: parser)

        print("")
        print("Swift Parser - Single Entry Performance:")
        print("  Simple:  \(Self.formatTime(simpleResult.median))")
        print("  Complex: \(Self.formatTime(complexResult.median))")

        // Just verify parsing works
        let entries = try parser.parseEntries(Self.simpleEntry)
        #expect(entries.count == 1)
    }

    @Test("Swift parser multiple entries performance")
    func swiftMultipleEntries() throws {
        let parser = BibTeXParser()

        print("")
        print("Swift Parser - Multiple Entries Performance:")

        for count in [10, 100, 1000] {
            let content = Self.generateEntries(count: count)
            let iterations = count >= 1000 ? 10 : (count >= 100 ? 50 : 100)
            let result = Self.measure(content: content, iterations: iterations, parser: parser)
            print("  \(count) entries: \(Self.formatTime(result.median))")
        }

        // Verify parsing works
        let content = Self.generateEntries(count: 10)
        let entries = try parser.parseEntries(content)
        #expect(entries.count == 10)
    }

    @Test("Print benchmark comparison")
    func printComparison() {
        print("")
        print(String(repeating: "=", count: 70))
        print("BENCHMARK COMPARISON: Rust vs Swift BibTeX Parser")
        print(String(repeating: "=", count: 70))
        print("")
        print("Rust results (from cargo bench):")
        print("  single_simple:  484.67 ns")
        print("  single_complex: 1.18 µs")
        print("  10 entries:     7.87 µs")
        print("  100 entries:    77.0 µs")
        print("  1000 entries:   803.9 µs")
        print("")
        print("Run swift test --filter Benchmark to see Swift results")
        print(String(repeating: "=", count: 70))
    }
}
