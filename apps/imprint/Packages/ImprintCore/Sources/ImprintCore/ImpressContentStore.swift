//
//  ImpressContentStore.swift
//  ImprintCore
//
//  Single source of truth for the content-addressed blob store location.
//  ImprintStoreAdapter (writer) and ImprintImpressStore (reader) must agree
//  on this path; on macOS it also matches the Rust side's convention
//  (see crates/impress-core manuscript_section docs).
//

import Foundation

/// Location of the content-addressed store for large section bodies.
enum ImpressContentStore {
    /// Root directory for content-addressed section bodies.
    ///
    /// macOS: `~/.local/share/impress/content` (shared desktop convention,
    /// readable by the Rust services and CLI tools).
    /// iOS: the app's Application Support — there is no home-directory
    /// convention, and no external process needs to read it.
    static var directory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/impress/content", isDirectory: true)
        #else
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("impress/content", isDirectory: true)
        #endif
    }
}
