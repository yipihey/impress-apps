//
//  FeedSaveTargetPicker.swift
//  PublicationManagerCore
//
//  Picker for selecting which library a feed saves papers to.
//

import SwiftUI

#if os(macOS)

/// Picker that lets users choose which library papers from a feed are saved to.
///
/// Shows "Default (global save library)" as the first option, followed by all user libraries.
/// When nil is selected, the global save library is used. When a specific library UUID is selected,
/// papers triage to that library instead.
public struct FeedSaveTargetPicker: View {

    @Binding var saveTargetID: UUID?

    private let store = RustStoreAdapter.shared

    public init(saveTargetID: Binding<UUID?>) {
        self._saveTargetID = saveTargetID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Save Papers To")
                .font(.subheadline)
                .fontWeight(.medium)

            Picker("", selection: $saveTargetID) {
                Text("Default (global save library)")
                    .tag(nil as UUID?)

                Divider()

                ForEach(userLibraries, id: \.id) { library in
                    Text(library.name)
                        .tag(library.id as UUID?)
                }
            }
            .labelsHidden()

            Text("Where papers go when you press S to save from this feed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var userLibraries: [LibraryModel] {
        store.listLibraries().filter { !$0.isInbox }
    }
}

#endif
