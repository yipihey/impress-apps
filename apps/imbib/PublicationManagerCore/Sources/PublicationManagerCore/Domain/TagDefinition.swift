//
//  TagDefinition.swift
//  PublicationManagerCore
//
//  Domain struct for tag management (replaces CDTag for settings/management use).
//

import Foundation
import ImbibRustCore

/// A tag definition with usage count — used in tag management settings.
public struct TagDefinition: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let leafName: String
    public let colorLight: String?
    public let colorDark: String?
    public let publicationCount: Int

    public init(from row: TagWithCountRow) {
        self.path = row.path
        self.leafName = row.leafName
        self.colorLight = row.colorLight
        self.colorDark = row.colorDark
        self.publicationCount = Int(row.publicationCount)
    }
}
