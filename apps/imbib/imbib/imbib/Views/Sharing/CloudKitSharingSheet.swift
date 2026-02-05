//
//  CloudKitSharingSheet.swift
//  imbib
//
//  Created by Claude on 2026-02-03.
//

#if os(macOS)
import SwiftUI
import CloudKit
import CoreData
import PublicationManagerCore

/// Wraps NSCloudSharingServiceDelegate to present the macOS CloudKit sharing UI.
///
/// This presents the standard system sharing interface where users can invite
/// participants, set permissions, and manage access to shared libraries.
struct CloudKitSharingSheet: NSViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let library: CDLibrary
    @Environment(\.dismiss) private var dismiss

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = NSViewController()
        controller.title = "Share \(library.displayName)"

        // Present the cloud sharing controller after the view is loaded
        DispatchQueue.main.async {
            let sharingService = NSSharingService(named: .cloudSharing)
            let itemProvider = NSItemProvider()
            itemProvider.registerCloudKitShare(share, container: container)

            guard let picker = sharingService else { return }
            picker.delegate = context.coordinator

            if let view = controller.view.window?.contentView {
                picker.perform(withItems: [itemProvider])
            }
        }

        return controller
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    class Coordinator: NSObject, NSSharingServiceDelegate, NSCloudSharingServiceDelegate {
        let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func sharingService(_ sharingService: NSSharingService, didCompleteForItems items: [Any], error: Error?) {
            dismiss()
        }

        func options(for sharingService: NSSharingService, shareProvider provider: NSItemProvider) -> NSSharingService.CloudKitOptions {
            [.allowPublic, .allowPrivate, .allowReadOnly, .allowReadWrite]
        }
    }
}

/// Presents the CloudKit sharing UI using UICloudSharingController wrapped for macOS.
///
/// Alternative approach using the persistent container's built-in sharing UI.
struct CloudKitSharingView: View {
    let share: CKShare
    let container: CKContainer
    let library: CDLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Share \"\(library.displayName)\"")
                .font(.headline)

            Text("Use the system sharing sheet to invite collaborators.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Open Sharing...") {
                    openSystemSharingSheet()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 300)
    }

    private func openSystemSharingSheet() {
        let sharingService = NSSharingService(named: .cloudSharing)
        let itemProvider = NSItemProvider()
        itemProvider.registerCloudKitShare(share, container: container)
        sharingService?.perform(withItems: [itemProvider])
    }
}
#endif
