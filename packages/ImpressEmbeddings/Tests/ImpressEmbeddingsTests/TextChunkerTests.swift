import Testing
@testable import ImpressEmbeddings
import Foundation

@Suite("TextChunker")
struct TextChunkerTests {

    let testPubId = UUID()

    @Test("Empty text produces no chunks")
    func emptyText() {
        let chunks = TextChunker.chunk(text: "", publicationId: testPubId)
        #expect(chunks.isEmpty)
    }

    @Test("Short text produces single chunk")
    func shortText() {
        let text = "This is a short piece of text that fits in one chunk."
        let chunks = TextChunker.chunk(text: text, publicationId: testPubId)
        #expect(chunks.count == 1)
        #expect(chunks[0].chunkIndex == 0)
        #expect(chunks[0].publicationId == testPubId)
    }

    @Test("Long text produces multiple chunks")
    func longText() {
        // Generate text with 1000 words
        let words = (0..<1000).map { "word\($0)" }
        let text = words.joined(separator: " ")

        let config = TextChunker.Config(chunkSize: 200, overlap: 20, respectParagraphs: false)
        let chunks = TextChunker.chunk(text: text, publicationId: testPubId, config: config)

        #expect(chunks.count > 1)

        // Verify sequential chunk indices
        for (i, chunk) in chunks.enumerated() {
            #expect(chunk.chunkIndex == i)
        }
    }

    @Test("Chunks respect overlap")
    func overlap() {
        let words = (0..<100).map { "word\($0)" }
        let text = words.joined(separator: " ")

        let config = TextChunker.Config(chunkSize: 30, overlap: 10, respectParagraphs: false)
        let chunks = TextChunker.chunk(text: text, publicationId: testPubId, config: config)

        #expect(chunks.count >= 3)

        // Check that consecutive chunks share some words (overlap)
        if chunks.count >= 2 {
            let firstWords = Set(chunks[0].text.split(separator: " ").map(String.init))
            let secondWords = Set(chunks[1].text.split(separator: " ").map(String.init))
            let intersection = firstWords.intersection(secondWords)
            #expect(!intersection.isEmpty, "Consecutive chunks should share overlapping words")
        }
    }

    @Test("Page-aware chunking preserves page numbers")
    func pageChunking() {
        let pages = [
            (page: 0, text: "Content of the first page with several words."),
            (page: 1, text: "Content of the second page with different words."),
        ]

        let chunks = TextChunker.chunkPages(pages, publicationId: testPubId)
        #expect(!chunks.isEmpty)

        // All chunks should have page numbers
        for chunk in chunks {
            #expect(chunk.pageNumber != nil)
        }
    }

    @Test("Paragraph boundaries respected")
    func paragraphBoundaries() {
        let text = """
        This is the first paragraph with enough words to be meaningful.

        This is the second paragraph which is also reasonably sized.

        And here is a third paragraph to round things out nicely.
        """

        let config = TextChunker.Config(chunkSize: 500, overlap: 10, respectParagraphs: true)
        let chunks = TextChunker.chunk(text: text, publicationId: testPubId, config: config)

        // With a large chunk size, all paragraphs should fit in one chunk
        #expect(chunks.count == 1)
    }
}
