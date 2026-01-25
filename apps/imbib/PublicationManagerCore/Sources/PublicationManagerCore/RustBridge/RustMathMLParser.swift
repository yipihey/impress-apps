//
//  RustMathMLParser.swift
//  PublicationManagerCore
//
//  MathML parser backed by the Rust imbib-core library.
//

import Foundation
import ImbibRustCore

/// MathML parser using the Rust imbib-core library.
public enum RustMathMLParser {

    /// Parse MathML content and convert to Unicode text.
    public static func parse(_ text: String) -> String {
        ImbibRustCore.parseMathml(text: text)
    }
}
