//
//  CloudKitSharingSheet.swift
//  imbib-iOS
//
//  Created by Claude on 2026-02-03.
//

#if os(iOS)
import SwiftUI
import UIKit
import CloudKit
import CoreData
import PublicationManagerCore

/// Wraps UICloudSharingController for presenting the iOS CloudKit sharing UI.
///
/// Presents the standard iOS sharing interface where users can invite
/// participants via Messages, Mail, or link, and set read/write permissions.
struct CloudKitSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let library: CDLibrary
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UICloudSharingController {
        share[CKShare.SystemFieldKey.title] = library.displayName as CKRecordValue

        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowPublic, .allowPrivate, .allowReadOnly, .allowReadWrite]
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: Error
        ) {
            Logger.sync.error("CloudKit sharing failed: \(error.localizedDescription)")
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            return csc.share?.title
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            Logger.sync.info("CloudKit share saved successfully")
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            Logger.sync.info("CloudKit sharing stopped")
            dismiss()
        }
    }
}
#endif
