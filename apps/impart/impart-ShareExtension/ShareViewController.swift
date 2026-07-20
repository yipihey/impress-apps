import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: SLComposeServiceViewController {

    override func isContentValid() -> Bool {
        return true
    }

    override func didSelectPost() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                attachment.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, _ in
                    if let text = item as? String {
                        self?.handleSharedText(text)
                    }
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
                return
            }

            if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                    if let url = item as? URL {
                        self?.handleSharedURL(url)
                    }
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
                return
            }

            if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                attachment.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] item, _ in
                    if let url = item as? URL {
                        self?.handleSharedImage(url)
                    }
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
                return
            }
        }

        extensionContext?.completeRequest(returningItems: nil)
    }

    override func configurationItems() -> [Any]! {
        return []
    }

    /// Never hardcode a single app-group id: macOS needs the Team-ID-prefixed
    /// form to avoid the "access data from other apps" TCC prompt; iOS
    /// requires the `group.` prefix. Mirrors ImpressKit's
    /// SiblingDiscovery.suiteGroupID — inlined because this extension target
    /// does not link ImpressKit.
    #if os(macOS)
    private static let suiteGroupID = "QG3MEYVHMS.com.impress.suite"
    #else
    private static let suiteGroupID = "group.com.impress.suite"
    #endif

    private func handleSharedText(_ text: String) {
        let defaults = UserDefaults(suiteName: Self.suiteGroupID)
        defaults?.set(text, forKey: "share.impart.pendingText")
        defaults?.set(Date().timeIntervalSince1970, forKey: "share.impart.pendingTimestamp")

        if let url = URL(string: "impart://compose?shared=true") {
            openURL(url)
        }
    }

    private func handleSharedURL(_ url: URL) {
        let defaults = UserDefaults(suiteName: Self.suiteGroupID)
        defaults?.set(url.absoluteString, forKey: "share.impart.pendingURL")
        defaults?.set(Date().timeIntervalSince1970, forKey: "share.impart.pendingTimestamp")

        if let appURL = URL(string: "impart://compose?shared=true") {
            openURL(appURL)
        }
    }

    private func handleSharedImage(_ imageURL: URL) {
        let defaults = UserDefaults(suiteName: Self.suiteGroupID)
        defaults?.set(imageURL.absoluteString, forKey: "share.impart.pendingImageURL")
        defaults?.set(Date().timeIntervalSince1970, forKey: "share.impart.pendingTimestamp")

        if let appURL = URL(string: "impart://compose?shared=true") {
            openURL(appURL)
        }
    }

    @objc private func openURL(_ url: URL) {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let application = next as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = next
        }
    }
}
