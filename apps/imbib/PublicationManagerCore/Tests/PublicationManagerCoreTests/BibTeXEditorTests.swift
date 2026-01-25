//
//  BibTeXEditorTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class BibTeXValidatorTests: XCTestCase {

    // MARK: - Valid BibTeX Tests

    func testValidate_validArticle_noErrors() {
        // Given
        let bibtex = """
        @article{Einstein1905,
            author = {Albert Einstein},
            title = {On the Electrodynamics of Moving Bodies},
            journal = {Annalen der Physik},
            year = {1905}
        }
        """

        // When
        let errors = BibTeXValidator.validate(bibtex)

        // Then
        XCTAssertTrue(errors.isEmpty, "Valid BibTeX should have no errors")
    }

    func testValidate_multipleEntries_noErrors() {
        // Given
        let bibtex = """
        @article{Entry1,
            author = {Author One},
            title = {First Paper}
        }

        @book{Entry2,
            author = {Author Two},
            title = {A Book}
        }
        """

        // When
        let errors = BibTeXValidator.validate(bibtex)

        // Then
        XCTAssertTrue(errors.isEmpty)
    }

    func testValidate_withComments_noErrors() {
        // Given
        let bibtex = """
        % This is a comment
        @article{Test,
            author = {Test}
        }
        % Another comment
        """

        // When
        let errors = BibTeXValidator.validate(bibtex)

        // Then
        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: - Invalid BibTeX Tests

    func testValidate_unclosedBrace_hasError() {
        // Given
        let bibtex = """
        @article{Test,
            author = {Test Author
        """

        // When
        let errors = BibTeXValidator.validate(bibtex)

        // Then
        XCTAssertFalse(errors.isEmpty)
        XCTAssertTrue(errors.first?.message.contains("Unclosed") == true)
    }

    func testValidate_extraClosingBrace_hasError() {
        // Given
        let bibtex = """
        @article{Test,
            author = {Test}
        }}
        """

        // When
        let errors = BibTeXValidator.validate(bibtex)

        // Then
        XCTAssertFalse(errors.isEmpty)
        XCTAssertTrue(errors.first?.message.contains("Unexpected") == true)
    }

    func testValidate_unknownEntryType_hasError() {
        // Given
        let bibtex = """
        @unknowntype{Test,
            author = {Test}
        }
        """

        // When
        let errors = BibTeXValidator.validate(bibtex)

        // Then
        XCTAssertFalse(errors.isEmpty)
        XCTAssertTrue(errors.first?.message.contains("Unknown entry type") == true)
    }

    func testValidate_nestedEntry_hasError() {
        // Given
        let bibtex = """
        @article{Outer,
            author = {Test},
            @article{Inner,
                title = {Nested}
            }
        }
        """

        // When
        let errors = BibTeXValidator.validate(bibtex)

        // Then
        XCTAssertFalse(errors.isEmpty)
        XCTAssertTrue(errors.first?.message.contains("New entry started") == true)
    }

    // MARK: - Line Number Tests

    func testValidate_errorHasCorrectLineNumber() {
        // Given - Error on line 3
        let bibtex = """
        @article{Test,
            author = {Test},
            title = {Missing close
        """

        // When
        let errors = BibTeXValidator.validate(bibtex)

        // Then
        XCTAssertFalse(errors.isEmpty)
        // The error should reference line 1 where the entry starts
        XCTAssertEqual(errors.first?.line, 1)
    }
}

// MARK: - BibTeX Highlighter Tests

final class BibTeXHighlighterTests: XCTestCase {

    func testHighlight_returnsAttributedString() {
        // Given
        let bibtex = "@article{Test, author = {Name}}"

        // When
        let result = BibTeXHighlighter.highlight(bibtex)

        // Then
        XCTAssertFalse(result.description.isEmpty)
    }

    func testHighlight_preservesContent() {
        // Given
        let bibtex = """
        @article{Einstein1905,
            author = {Albert Einstein}
        }
        """

        // When
        let result = BibTeXHighlighter.highlight(bibtex)

        // Then
        // The plain string content should match
        XCTAssertTrue(String(result.characters).contains("Einstein1905"))
        XCTAssertTrue(String(result.characters).contains("Albert Einstein"))
    }

    func testHighlight_handlesEmptyString() {
        // Given
        let bibtex = ""

        // When
        let result = BibTeXHighlighter.highlight(bibtex)

        // Then
        XCTAssertTrue(result.description.isEmpty || result.characters.count == 0)
    }

    func testHighlight_handlesCommentsOnly() {
        // Given
        let bibtex = """
        % This is a comment
        % Another comment
        """

        // When
        let result = BibTeXHighlighter.highlight(bibtex)

        // Then
        XCTAssertTrue(String(result.characters).contains("This is a comment"))
    }
}

// MARK: - BibTeX Validation Error Tests

final class BibTeXValidationErrorTests: XCTestCase {

    func testValidationError_hasLineAndMessage() {
        // Given
        let error = BibTeXValidationError(line: 5, message: "Test error")

        // Then
        XCTAssertEqual(error.line, 5)
        XCTAssertEqual(error.message, "Test error")
    }

    func testValidationError_hasUniqueID() {
        // Given
        let error1 = BibTeXValidationError(line: 1, message: "Error 1")
        let error2 = BibTeXValidationError(line: 1, message: "Error 1")

        // Then - Each error should have a unique ID
        XCTAssertNotEqual(error1.id, error2.id)
    }
}
