//
//  ImpressIOSApp.swift
//  impress-iOS
//
//  The iOS entry point. One scene, one host view, the suite's appearance key —
//  byte-identical in shape to `ImpartIOSApp`, deliberately (the
//  `appearanceMode` / `system|light|dark` triple is what the chassis settings
//  pane writes, and a fork of it would be a fourth spelling of one preference).
//

import PublicationManagerCore
import SwiftUI

@main
struct ImpressIOSApp: App {

    @AppStorage("appearanceMode") private var appearanceMode = "system"

    init() {
        // Synchronous, before any view reads the store.
        ImpressIOSUITestSeed.seedIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            IOSImpressHostView().preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
