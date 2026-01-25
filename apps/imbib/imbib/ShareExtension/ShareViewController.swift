//
//  ShareViewController.swift
//  imbib-ShareExtension (macOS)
//
//  Created by Claude on 2026-01-07.
//

import Cocoa
import SwiftUI
import UniformTypeIdentifiers
import PublicationManagerCore

/// macOS share extension view controller.
///
/// Hosts the SwiftUI ShareExtensionView and handles NSExtensionItem processing.
/// Uses JavaScript preprocessing to extract the page title from Safari.
class ShareViewController: NSViewController {

    // MARK: - Properties

    private var sharedURL: URL?
    private var pageTitle: String?
    private var hostingView: NSHostingView<ShareExtensionView>?

    // MARK: - Lifecycle

    override func loadView() {
        // Create a placeholder view while we process the extension item
        view = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 300))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Extract the shared URL and page title from the extension context
        extractSharedContent { [weak self] url, title in
            DispatchQueue.main.async {
                if let url = url {
                    self?.pageTitle = title
                    self?.showShareUI(for: url, pageTitle: title)
                } else {
                    self?.showError("No URL found in shared content")
                }
            }
        }
    }

    // MARK: - Content Extraction

    /// Extract URL and page title using shared content extractor
    private func extractSharedContent(completion: @escaping (URL?, String?) -> Void) {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments else {
            completion(nil, nil)
            return
        }

        ShareExtensionContentExtractor.shared.extractContent(from: attachments) { content in
            if let content = content {
                completion(content.url, content.pageTitle)
            } else {
                completion(nil, nil)
            }
        }
    }

    // MARK: - UI

    private func showShareUI(for url: URL, pageTitle: String?) {
        sharedURL = url

        let shareView = ShareExtensionView(
            sharedURL: url,
            pageTitle: pageTitle,
            onConfirm: { [weak self] item in
                self?.handleConfirm(item)
            },
            onCancel: { [weak self] in
                self?.handleCancel()
            }
        )

        let hostingView = NSHostingView(rootView: shareView)
        hostingView.frame = view.bounds
        hostingView.autoresizingMask = [.width, .height]

        // Remove any existing subviews
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(hostingView)

        self.hostingView = hostingView

        // Update preferred content size
        preferredContentSize = NSSize(width: 350, height: 300)
    }

    private func showError(_ message: String) {
        let errorView = VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Close") { [weak self] in
                self?.handleCancel()
            }
        }
        .padding()
        .frame(width: 300, height: 200)

        let hostingView = NSHostingView(rootView: errorView)
        hostingView.frame = view.bounds
        hostingView.autoresizingMask = [.width, .height]

        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(hostingView)

        preferredContentSize = NSSize(width: 300, height: 200)
    }

    // MARK: - Actions

    private func handleConfirm(_ item: ShareExtensionService.SharedItem) {
        // Queue the item for the main app using shared extractor
        ShareExtensionContentExtractor.shared.queueItem(item)

        // Complete the extension
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func handleCancel() {
        let error = NSError(
            domain: "com.imbib.ShareExtension",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "User cancelled"]
        )
        extensionContext?.cancelRequest(withError: error)
    }
}
