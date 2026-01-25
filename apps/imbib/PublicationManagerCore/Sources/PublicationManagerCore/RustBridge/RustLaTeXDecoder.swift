//
//  RustLaTeXDecoder.swift
//  PublicationManagerCore
//
//  LaTeX decoder backed by the Rust imbib-core library.
//

import Foundation
import ImbibRustCore

/// LaTeX decoder using the Rust imbib-core library.
public enum RustLaTeXDecoder {

    /// Decode LaTeX commands to Unicode using the Rust implementation.
    public static func decode(_ input: String) -> String {
        decodeLatex(input: input)
    }
}
