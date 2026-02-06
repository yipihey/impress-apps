//
//  ImprintCloudKitSharingSheet.swift
//  imprint
//
//  Wraps the native macOS CloudKit sharing UI for imprint folder sharing.
//

#if os(macOS)
import SwiftUI
import CloudKit
import CoreData

/// Presents the system CloudKit sharing interface for a folder.
struct ImprintCloudKitSharingSheet: NSViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let folderName: String
    @Environment(\.dismiss) private var dismiss

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = NSViewController()
        controller.title = "Share \(folderName)"

        DispatchQueue.main.async {
            let sharingService = NSSharingService(named: .cloudSharing)
            let itemProvider = NSItemProvider()
            itemProvider.registerCloudKitShare(share, container: container)

            guard let picker = sharingService else { return }
            picker.delegate = context.coordinator

            if controller.view.window?.contentView != nil {
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

/// Fallback sharing view with manual button for presenting sharing UI.
struct ImprintCloudKitSharingView: View {
    let share: CKShare
    let container: CKContainer
    let folderName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Share \"\(folderName)\"")
                .font(.headline)

            Text("Sharing a folder shares its structure and document references. Actual .imprint files must be in a shared iCloud Drive location for collaborators to access content.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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
        .frame(minWidth: 350)
    }

    private func openSystemSharingSheet() {
        let sharingService = NSSharingService(named: .cloudSharing)
        let itemProvider = NSItemProvider()
        itemProvider.registerCloudKitShare(share, container: container)
        sharingService?.perform(withItems: [itemProvider])
    }
}
#endif
