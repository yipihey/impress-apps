//
//  TestDataFactory.swift
//  imbibUITests
//
//  Factory for creating deterministic test data.
//

import Foundation
import XCTest

/// Factory for creating test data files and resources.
///
/// Provides access to bundled test resources and generates
/// deterministic test data for UI tests.
struct TestDataFactory {

    // MARK: - Bundle Access

    /// The test bundle containing test resources
    private static var testBundle: Bundle {
        Bundle(for: BundleToken.self)
    }

    /// Dummy class for bundle lookup
    private class BundleToken {}

    // MARK: - BibTeX Test Files

    /// Sample BibTeX file with a few entries
    static var sampleBibTeX: URL? {
        testBundle.url(forResource: "sample", withExtension: "bib")
    }

    /// Large BibTeX file for performance testing
    static var largeBibTeX: URL? {
        testBundle.url(forResource: "thesis_ref", withExtension: "bib")
    }

    // MARK: - RIS Test Files

    /// Sample RIS file with a few entries
    static var sampleRIS: URL? {
        testBundle.url(forResource: "sample", withExtension: "ris")
    }

    // MARK: - BibTeX Generation

    /// Generate a BibTeX file with the specified number of entries.
    ///
    /// Creates deterministic entries based on the count for reproducible tests.
    ///
    /// - Parameter count: Number of entries to generate
    /// - Returns: URL to the generated temporary file
    static func generateBibTeXFile(entries count: Int) throws -> URL {
        var content = ""

        for i in 1...count {
            let entry = generateBibTeXEntry(index: i)
            content += entry + "\n\n"
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(count)_entries.bib")

        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    /// Generate a single BibTeX entry.
    ///
    /// - Parameter index: Index for deterministic key/content generation
    /// - Returns: BibTeX entry string
    static func generateBibTeXEntry(index: Int) -> String {
        let citeKey = "Author\(index)Year\(2020 + (index % 5))"
        let year = 2020 + (index % 5)
        let titleWords = ["Quantum", "Neural", "Distributed", "Scalable", "Efficient"]
        let titleWord = titleWords[index % titleWords.count]

        return """
        @article{\(citeKey),
            title = {\(titleWord) Approaches to Problem \(index)},
            author = {Author, Test\(index) and Coauthor, Sample},
            journal = {Journal of Testing},
            year = {\(year)},
            volume = {\(index)},
            pages = {\(index * 10)--\(index * 10 + 15)},
            doi = {10.1234/test.\(index)},
            abstract = {This is the abstract for test entry \(index). It discusses \(titleWord.lowercased()) methods.}
        }
        """
    }

    // MARK: - RIS Generation

    /// Generate an RIS file with the specified number of entries.
    ///
    /// - Parameter count: Number of entries to generate
    /// - Returns: URL to the generated temporary file
    static func generateRISFile(entries count: Int) throws -> URL {
        var content = ""

        for i in 1...count {
            let entry = generateRISEntry(index: i)
            content += entry + "\n"
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(count)_entries.ris")

        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    /// Generate a single RIS entry.
    ///
    /// - Parameter index: Index for deterministic content generation
    /// - Returns: RIS entry string
    static func generateRISEntry(index: Int) -> String {
        let year = 2020 + (index % 5)
        let titleWords = ["Quantum", "Neural", "Distributed", "Scalable", "Efficient"]
        let titleWord = titleWords[index % titleWords.count]

        return """
        TY  - JOUR
        TI  - \(titleWord) Approaches to Problem \(index)
        AU  - Author, Test\(index)
        AU  - Coauthor, Sample
        PY  - \(year)
        JO  - Journal of Testing
        VL  - \(index)
        SP  - \(index * 10)
        EP  - \(index * 10 + 15)
        DO  - 10.1234/test.\(index)
        AB  - This is the abstract for test entry \(index). It discusses \(titleWord.lowercased()) methods.
        ER  -
        """
    }

    // MARK: - Clipboard Data

    /// Copy BibTeX content to the system clipboard.
    ///
    /// - Parameter content: BibTeX string to copy
    #if os(macOS)
    static func copyBibTeXToClipboard(_ content: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
    }
    #endif

    /// Sample BibTeX for clipboard paste tests.
    static var sampleBibTeXForClipboard: String {
        """
        @article{ClipboardTest2024,
            title = {A Test Article for Clipboard Pasting},
            author = {Clipboard, Test},
            journal = {Journal of Clipboard Testing},
            year = {2024},
            volume = {1},
            pages = {1--10},
            doi = {10.1234/clipboard.test}
        }
        """
    }

    // MARK: - Temporary File Cleanup

    /// Clean up all generated test files.
    static func cleanup() {
        let tempDir = FileManager.default.temporaryDirectory
        let fileManager = FileManager.default

        do {
            let tempFiles = try fileManager.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: nil
            )

            for file in tempFiles where file.lastPathComponent.hasPrefix("test_") {
                try? fileManager.removeItem(at: file)
            }
        } catch {
            // Ignore cleanup errors
        }
    }
}

// MARK: - Test Expectations

/// Common test expectations and predicates.
struct TestExpectations {

    /// Predicate for element existence
    static let exists = NSPredicate(format: "exists == true")

    /// Predicate for element not existing
    static let notExists = NSPredicate(format: "exists == false")

    /// Predicate for element being hittable
    static let hittable = NSPredicate(format: "isHittable == true")

    /// Predicate for count being greater than zero
    static let hasElements = NSPredicate(format: "count > 0")

    /// Create a predicate for specific count
    static func count(_ expected: Int) -> NSPredicate {
        NSPredicate(format: "count == %d", expected)
    }

    /// Create a predicate for count greater than value
    static func countGreaterThan(_ value: Int) -> NSPredicate {
        NSPredicate(format: "count > %d", value)
    }
}
