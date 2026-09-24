// Chassis file — CROSS-PLATFORM (macOS + iOS). Reads one pure Rust table over
// the FFI; no store, no AppKit.
//
//  ShippedSectionBindings.swift
//  PublicationManagerCore
//
//  Plan wave 6 W5: the record kind each section serves in a SHIPPED shell is
//  preset data, and it lives with the rest of the preset data in Rust —
//  `impress_layout_service::section_bindings`, beside the named queries it
//  must agree with (`bindings_agree_with_the_named_queries`). The six shipped
//  `AppShellConfiguration` presets read it from here instead of each carrying
//  a literal table, so "Flagged is manuscripts in imprint" has one
//  definition.
//
//  `sectionBindings` stays an `AppShellConfiguration` initializer parameter:
//  a shell that is NOT shipped (the Litmus proofs that a new record kind can
//  join the chassis) binds its own kind there, and Rust's table cannot know
//  that kind.
//

import Foundation
import ImpressRustCore

/// The shipped section → record-kind table, read from Rust.
enum ShippedSectionBindings {

    /// `appID`'s bindings. Keys come back as `SidebarSectionType` CASE names
    /// (`manuscripts`, not the raw value `journal`); a name this build has no
    /// case for is skipped, and an app Rust ships nothing for binds nothing.
    static func of(_ appID: String) -> [SidebarSectionType: RecordKindID] {
        let json = sectionBindingsJson(appId: appID)
        guard let data = json.data(using: .utf8),
              let table = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        else { return [:] }
        var out: [SidebarSectionType: RecordKindID] = [:]
        for (name, kind) in table {
            guard let section = SidebarSectionType.allCases.first(where: {
                String(describing: $0) == name
            }) else { continue }
            out[section] = RecordKindID(kind)
        }
        return out
    }
}
