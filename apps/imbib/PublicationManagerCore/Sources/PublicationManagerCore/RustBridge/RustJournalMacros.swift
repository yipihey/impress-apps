//
//  RustJournalMacros.swift
//  PublicationManagerCore
//
//  Journal macro expansion backed by the Rust imbib-core library.
//

import Foundation
import ImbibRustCore

/// Journal macro expansion using the Rust imbib-core library.
public enum RustJournalMacros {

    /// Expand a journal macro to its full name.
    public static func expand(_ value: String) -> String {
        expandJournalMacro(value: value)
    }

    /// Check if a string is a journal macro.
    public static func isMacro(_ value: String) -> Bool {
        isJournalMacro(value: value)
    }

    /// Get all known journal macro names.
    public static func getAllMacroNames() -> [String] {
        getAllJournalMacroNames()
    }
}
