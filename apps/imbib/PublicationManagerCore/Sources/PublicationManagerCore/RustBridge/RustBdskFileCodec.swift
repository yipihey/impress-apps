//
//  RustBdskFileCodec.swift
//  PublicationManagerCore
//
//  BibDesk file reference codec backed by the Rust imbib-core library.
//  Handles encoding/decoding of Bdsk-File-* fields in BibTeX entries.
//

import Foundation
import ImbibRustCore

// MARK: - Rust Bdsk-File Codec

/// BibDesk file reference codec using the Rust imbib-core library.
public enum RustBdskFileCodec {

    /// Decode a Bdsk-File-* field value to get the relative path
    /// - Parameter value: The base64-encoded binary plist string
    /// - Returns: The decoded relative path, or nil if decoding fails
    public static func decode(_ value: String) -> String? {
        return bdskFileDecode(value: value)
    }

    /// Encode a relative path as a Bdsk-File-* field value
    /// - Parameter relativePath: The relative path to the file
    /// - Returns: The base64-encoded binary plist string, or nil if encoding fails
    public static func encode(relativePath: String) -> String? {
        return bdskFileEncode(relativePath: relativePath)
    }

    /// Extract all file paths from an entry's Bdsk-File-* fields
    /// - Parameter fields: Dictionary of BibTeX field names to values
    /// - Returns: Sorted list of decoded file paths
    public static func extractFiles(from fields: [String: String]) -> [String] {
        return bdskFileExtractAll(fields: fields)
    }

    /// Create Bdsk-File field entries for a list of paths
    /// - Parameter paths: List of relative file paths
    /// - Returns: Dictionary of field names (Bdsk-File-1, etc.) to encoded values
    public static func createFields(for paths: [String]) -> [String: String] {
        return bdskFileCreateFields(paths: paths)
    }

    /// Add file references to entry fields
    /// - Parameters:
    ///   - paths: List of relative file paths to add
    ///   - fields: Mutable dictionary of fields to update
    public static func addFiles(_ paths: [String], to fields: inout [String: String]) {
        // Remove existing Bdsk-File-* fields
        for key in fields.keys where key.lowercased().hasPrefix("bdsk-file-") {
            fields.removeValue(forKey: key)
        }

        // Add new fields from Rust
        let newFields = createFields(for: paths)
        for (key, value) in newFields {
            fields[key] = value
        }
    }
}

// MARK: - Availability Info

extension RustBdskFileCodec {
    /// Whether the Rust implementation is available
    public static var isAvailable: Bool { true }
}
