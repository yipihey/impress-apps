//
//  RustTextParser.swift
//  PublicationManagerCore
//
//  Scientific text preprocessing backed by the Rust imbib-core library.
//

import Foundation
import ImbibRustCore

/// Scientific text preprocessing using the Rust imbib-core library.
public enum RustTextParser {

    /// Decode HTML entities to Unicode.
    public static func decodeHTMLEntities(_ text: String) -> String {
        ImbibRustCore.decodeHtmlEntities(text: text)
    }

    /// Replace LaTeX Greek letters with Unicode equivalents.
    public static func replaceGreekLetters(_ text: String) -> String {
        ImbibRustCore.replaceGreekLetters(text: text)
    }

    /// Strip LaTeX font commands.
    public static func stripFontCommands(_ text: String) -> String {
        ImbibRustCore.stripFontCommands(text: text)
    }

    /// Remove standalone braces (not part of ^{} or _{}).
    public static func stripStandaloneBraces(_ text: String) -> String {
        ImbibRustCore.stripStandaloneBraces(text: text)
    }

    /// Apply all preprocessing steps.
    public static func preprocess(_ text: String) -> String {
        ImbibRustCore.preprocessScientificText(text: text)
    }
}

/// Author name parsing using the Rust imbib-core library.
public enum RustAuthorParser {

    /// Extract the first author's last name from a BibTeX author field.
    public static func extractFirstAuthorLastName(_ authorField: String) -> String {
        ImbibRustCore.extractFirstAuthorLastName(authorField: authorField)
    }

    /// Split a BibTeX author field into individual authors.
    public static func splitAuthors(_ authorField: String) -> [String] {
        ImbibRustCore.splitAuthors(authorField: authorField)
    }

    /// Normalize an author name for comparison.
    public static func normalizeAuthorName(_ name: String) -> String {
        ImbibRustCore.normalizeAuthorName(name: name)
    }

    /// Extract surname from an author name.
    public static func extractSurname(_ author: String) -> String {
        ImbibRustCore.extractSurname(author: author)
    }

    /// Extract first meaningful word from a title.
    public static func extractFirstMeaningfulWord(_ title: String) -> String {
        ImbibRustCore.extractFirstMeaningfulWord(title: title)
    }

    /// Sanitize a string for use as a BibTeX cite key.
    public static func sanitizeCiteKey(_ key: String) -> String {
        ImbibRustCore.sanitizeCiteKey(key: key)
    }
}
