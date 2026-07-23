//
//  ManuscriptFiguresDirectory.swift
//  PublicationManagerCore
//
//  The per-manuscript figures location, shared by imbib AND imprint via the
//  app-group container (user-approved layout):
//
//      <group container>/manuscripts/<manuscript-uuid>/figures/<name>.png
//
//  The MANUSCRIPT dir (not figures/) is what flows into the Typst compile as
//  `figuresRoot`, so source references stay naturally prefixed:
//  `image("figures/plot.png")` → `<manuscriptRoot>/figures/plot.png`.
//
//  Built on SharedContainer.rootDirectory, which already handles the
//  unit-test-process diversion (unentitled xctest workers must never touch
//  group-container paths — see MEMORY: kernel-level open() hang).

import Foundation
import ImpressKit

public enum ManuscriptFiguresDirectory {

    /// The manuscript's root dir in the app group (pass THIS as figuresRoot).
    public static func manuscriptRoot(for id: UUID) -> URL {
        SharedContainer.rootDirectory
            .appendingPathComponent("manuscripts", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// The figures subdirectory, created on demand.
    @discardableResult
    public static func figuresDirectory(for id: UUID) throws -> URL {
        let dir = manuscriptRoot(for: id).appendingPathComponent("figures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
