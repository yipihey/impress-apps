//
//  IOSSettingsViewStub.swift
//  imbib-iOS
//
//  Temporary working replacement for IOSSettingsView.swift, which
//  references deleted Core Data types (CDMutedItem, CDLibrary). The
//  original 1100-line settings screen covered import/export, muted
//  items, notes, recommendations, appearance, and keyboard shortcuts.
//  This stub keeps the iOS app launchable while deferring the full
//  rewrite to migration debt.
//
//  The individual setting panels that already use value types
//  (IOSAppearanceSettingsView, IOSNotesSettingsView,
//  IOSImportExportSettingsView, IOSRecommendationSettingsView,
//  IOSKeyboardShortcutsSettingsView) are still in the tree and can be
//  re-linked once the mute-rules and library-picker surfaces are
//  migrated off Core Data.
//

import SwiftUI

struct IOSSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Appearance") { IOSAppearanceSettingsView() }
                    NavigationLink("Notes") { IOSNotesSettingsView() }
                    NavigationLink("Recommendations") { IOSRecommendationSettingsView() }
                    NavigationLink("Keyboard Shortcuts") { IOSKeyboardShortcutsSettingsView() }
                    NavigationLink("Import / Export") { IOSImportExportSettingsView() }
                }
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("iOS rebuild in progress")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("Muted items, automation, and library-level settings are temporarily hidden while the iOS settings screen is migrated off Core Data.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
