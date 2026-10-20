//
//  ImbibAppIntents.swift
//  ImbibAppIntents
//
//  imbib's App Intents: its hand-written intents (AppIntents/) and the ones
//  generated from the verb inventory (VerbIntents/, written by
//  `cargo run -p impress-capabilities --bin gen-app-intents`). Only the imbib
//  apps link this module. They used to live in PublicationManagerCore, which
//  every suite app links as the chassis, so all six apps exported imbib's
//  intents and carried its AppShortcutsProvider beside their own.
//

import AppIntents
import Foundation
import PublicationManagerCore

/// Wiring the imbib app does at launch.
public enum ImbibAppIntents {
    /// Name the publication a Handoff activity is about as the generated
    /// `PublicationEntity`, so Siri, Shortcuts and Apple Intelligence can act
    /// on what the person is looking at (`HandoffService.entityPointer`).
    @MainActor
    public static func install() {
        HandoffService.entityPointer = { activity, publicationID in
            activity.appEntityIdentifier = EntityIdentifier(
                for: PublicationEntity.self,
                identifier: publicationID.uuidString.lowercased()
            )
        }
    }
}
