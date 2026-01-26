//
//  ImprintTestDataFactory.swift
//  imprintUITests
//
//  Factory for creating test data for imprint UI tests.
//

import Foundation

/// Factory for creating test content for imprint UI tests
enum ImprintTestDataFactory {

    /// Sample Typst document source
    static let sampleTypstSource = """
    = My Research Paper

    #set text(font: "New Computer Modern")

    == Introduction

    This is a sample document for testing imprint.

    We can include citations like @einstein1905 and @feynman1965.

    === Background

    Some background information goes here.

    == Methods

    The methods section describes our approach.

    $ E = m c^2 $

    == Results

    Our results show significant findings.

    == Discussion

    We discuss the implications of our work.

    == Conclusion

    In conclusion, we have demonstrated the effectiveness of our approach.

    #bibliography("refs.bib")
    """

    /// Sample BibTeX content
    static let sampleBibTeX = """
    @article{einstein1905,
        author = {Einstein, Albert},
        title = {On the Electrodynamics of Moving Bodies},
        journal = {Annalen der Physik},
        year = {1905},
        volume = {17},
        pages = {891--921}
    }

    @book{feynman1965,
        author = {Feynman, Richard P.},
        title = {The Feynman Lectures on Physics},
        publisher = {Addison-Wesley},
        year = {1965}
    }
    """

    /// Sample citation keys for testing
    static let sampleCiteKeys = [
        "einstein1905",
        "feynman1965",
        "dirac1930",
        "hawking1974"
    ]

    /// Sample document titles
    static let sampleDocumentTitles = [
        "My Research Paper",
        "Quantum Computing Review",
        "Machine Learning in Physics"
    ]

    /// Generate a document with specified number of sections
    static func generateDocument(sectionCount: Int) -> String {
        var sections: [String] = ["= Generated Test Document\n"]

        for i in 1...sectionCount {
            sections.append("""

            == Section \(i)

            This is the content for section \(i). It contains some text to make the document longer.

            Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.

            """)
        }

        return sections.joined()
    }

    /// Generate a document with citations
    static func generateDocumentWithCitations(citationCount: Int) -> String {
        let citations = sampleCiteKeys.prefix(min(citationCount, sampleCiteKeys.count))
        let citationRefs = citations.map { "@\($0)" }.joined(separator: ", ")

        return """
        = Document with Citations

        == Introduction

        This document references several important works: \(citationRefs).

        == Discussion

        The works cited above demonstrate key concepts.

        """
    }
}
