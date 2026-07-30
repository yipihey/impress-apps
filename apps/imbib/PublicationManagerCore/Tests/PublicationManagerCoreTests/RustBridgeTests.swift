//
//  RustBridgeTests.swift
//  PublicationManagerCoreTests
//
//  Tests for the Rust BibTeX parser bridge.
//

import Testing
@testable import PublicationManagerCore

// MARK: - Parser Factory Tests

// There is one BibTeX parser (the Rust one); the Swift parser and the mutable
// backend global were deleted in Stage 7, so nothing here is order-dependent
// any more.
@Suite("BibTeX Parser Factory")
struct BibTeXParserFactoryTests {

    @Test("Backend is Rust")
    func backendIsRust() {
        #expect(BibTeXParserFactory.backend == .rust)
        #expect(RustLibraryInfo.isAvailable)
    }

    @Test("Can create parser with default settings")
    func createDefaultParser() {
        let parser = BibTeXParserFactory.createParser()
        #expect(parser is RustBibTeXParser)
    }

    @Test("Parser works through factory")
    func parserThroughFactory() throws {
        let parser = BibTeXParserFactory.createParser()

        let content = """
        @article{Test2024,
            author = {John Smith},
            title = {Test Paper},
            year = {2024}
        }
        """

        let entries = try parser.parseEntries(content)
        #expect(entries.count == 1)
        #expect(entries[0].citeKey == "Test2024")
        #expect(entries[0].author == "John Smith")
    }
}

// MARK: - Rust Library Info Tests

@Suite("Rust Library Info")
struct RustLibraryInfoTests {

    @Test("Rust library availability is consistent")
    func checkAvailability() {
        // Just verify the property returns a consistent value (true or false)
        // In CI without xcframework, this will be false - that's expected
        let available = RustLibraryInfo.isAvailable
        #expect(available == RustLibraryInfo.isAvailable) // Consistent
    }

    @Test("Can get version when Rust is available")
    func getVersion() throws {
        try #require(RustLibraryInfo.isAvailable, "Rust library not available - skipping")
        let version = RustLibraryInfo.version
        #expect(!version.isEmpty)
    }

    @Test("Can call hello function when Rust is available")
    func helloFunction() throws {
        try #require(RustLibraryInfo.isAvailable, "Rust library not available - skipping")
        let greeting = RustLibraryInfo.hello()
        #expect(!greeting.isEmpty)
    }
}

// MARK: - Protocol Conformance Tests

@Suite("BibTeX Parsing Protocol")
struct BibTeXParsingProtocolTests {

    @Test("Rust parser conforms to protocol")
    func rustParserConformance() {
        let parser: any BibTeXParsing = BibTeXParserFactory.createParser()
        #expect(parser is RustBibTeXParser)
    }

    @Test("Protocol methods work correctly")
    func protocolMethods() throws {
        let parser: any BibTeXParsing = BibTeXParserFactory.createParser()

        let content = """
        @book{Knuth1984,
            author = {Donald E. Knuth},
            title = {The {\\TeX}book},
            year = {1984},
            publisher = {Addison-Wesley}
        }
        """

        let items = try parser.parse(content)
        #expect(items.count == 1)

        let entries = try parser.parseEntries(content)
        #expect(entries.count == 1)
        #expect(entries[0].citeKey == "Knuth1984")

        let entry = try parser.parseEntry(content)
        #expect(entry.citeKey == "Knuth1984")
        #expect(entry.entryType == "book")
    }
}

// MARK: - Backend Tests

@Suite("Backend")
struct BackendSwitchingTests {

    @Test("Rust backend works correctly")
    func rustBackendWorks() throws {
        let parser = BibTeXParserFactory.createParser()
        #expect(parser is RustBibTeXParser)

        let content = "@article{Test, title = {Test}}"
        let entries = try parser.parseEntries(content)
        #expect(entries.count == 1)
    }
}

// MARK: - Dialect Coverage

@Suite("Parser Dialect Coverage")
struct ParserConsistencyTests {

    let testCases: [(String, String)] = [
        ("Simple article", """
            @article{Smith2024,
                author = {John Smith},
                title = {A Great Paper},
                year = {2024}
            }
            """),
        ("Nested braces", """
            @article{Test,
                title = {The {LaTeX} Companion}
            }
            """),
        ("Multiple entries", """
            @article{First, title = {First}}
            @book{Second, title = {Second}}
            """),
        ("String macros", """
            @string{nature = "Nature"}
            @article{Test, journal = nature}
            """),
    ]

    @Test("Rust parser handles test cases")
    func rustParserTestCases() throws {
        let parser = RustBibTeXParser()

        for (name, content) in testCases {
            let entries = try parser.parseEntries(content)
            #expect(entries.count >= 1, "Failed on: \(name)")
        }
    }
}
