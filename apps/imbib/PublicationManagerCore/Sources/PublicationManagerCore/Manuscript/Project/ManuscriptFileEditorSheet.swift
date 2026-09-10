//
//  ManuscriptFileEditorSheet.swift
//  PublicationManagerCore
//
//  One project file in its own editor (ADR-0030): the shared Source tab
//  over a session bound to the file's document — its own Automerge
//  history, and compiles that build the whole tree with this buffer
//  substituted. The Files and Plots panels present it for any text row.
//

#if os(macOS)
import ImpressKit
import SwiftUI

public struct ManuscriptFileEditorSheet: View {
    public let manuscriptID: UUID
    public let path: String
    @Environment(\.dismiss) private var dismiss

    public init(manuscriptID: UUID, path: String) {
        self.manuscriptID = manuscriptID
        self.path = path
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(path).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            if let session = ManuscriptSessionRegistry.shared.fileSession(manuscriptID: manuscriptID, path: path) {
                ManuscriptSourceTab(session: session)
            } else {
                ContentUnavailableView(
                    "Cannot edit \(path)",
                    systemImage: "doc.questionmark",
                    description: Text("The file is binary, or its text is not in this workspace."))
            }
        }
        .impressResizableSheet(minWidth: 900, minHeight: 600)
    }
}
#endif
