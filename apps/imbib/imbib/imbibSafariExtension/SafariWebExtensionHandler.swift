import SafariServices
import os.log

/// Handles messages from the Safari web extension JavaScript
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private let logger = Logger(subsystem: "com.imbib.app.safari-extension", category: "handler")
    private let defaults = UserDefaults(suiteName: "group.com.imbib.app")

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        logger.debug("Received message from extension: \(String(describing: message))")

        guard let action = message?["action"] as? String else {
            logger.warning("No action in message")
            context.completeRequest(returningItems: nil)
            return
        }

        switch action {
        case "getLibraries":
            handleGetLibraries(context: context)
        case "importItem":
            handleImportItem(message: message, context: context)
        case "checkDuplicate":
            handleCheckDuplicate(message: message, context: context)
        case "createSmartSearch":
            handleCreateSmartSearch(message: message, context: context)
        case "ping":
            // Simple connectivity test
            respond(with: ["success": true, "message": "pong"], context: context)
        default:
            logger.warning("Unknown action: \(action)")
            respond(with: ["error": "Unknown action"], context: context)
        }
    }

    // MARK: - Action Handlers

    private func handleGetLibraries(context: NSExtensionContext) {
        // Read libraries from App Group shared data
        // The main app populates this when libraries change
        let libraries = defaults?.array(forKey: "availableLibraries") as? [[String: String]] ?? []

        logger.info("Returning \(libraries.count) libraries")
        respond(with: ["libraries": libraries], context: context)
    }

    private func handleImportItem(message: [String: Any]?, context: NSExtensionContext) {
        guard let itemData = message?["item"] as? [String: Any] else {
            logger.error("No item data in importItem message")
            respond(with: ["error": "No item data"], context: context)
            return
        }

        // Queue item for import via App Group
        queueImportItem(itemData)

        logger.info("Queued item for import: \(itemData["title"] as? String ?? "unknown")")
        respond(with: ["success": true], context: context)
    }

    private func handleCheckDuplicate(message: [String: Any]?, context: NSExtensionContext) {
        let doi = message?["doi"] as? String
        let arxivID = message?["arxivID"] as? String
        let bibcode = message?["bibcode"] as? String

        let exists = checkIfExists(doi: doi, arxivID: arxivID, bibcode: bibcode)

        logger.debug("Duplicate check - DOI: \(doi ?? "nil"), arXiv: \(arxivID ?? "nil"), bibcode: \(bibcode ?? "nil") → \(exists)")
        respond(with: ["exists": exists], context: context)
    }

    private func handleCreateSmartSearch(message: [String: Any]?, context: NSExtensionContext) {
        guard let query = message?["query"] as? String, !query.isEmpty else {
            logger.error("No query in createSmartSearch message")
            respond(with: ["error": "No query provided"], context: context)
            return
        }

        let name = message?["name"] as? String ?? "Search: \(query.prefix(40))"
        let sourceID = message?["sourceID"] as? String ?? "ads"

        // Queue smart search creation via App Group
        queueSmartSearchCreation(query: query, name: name, sourceID: sourceID)

        logger.info("Queued smart search creation: \(name)")
        respond(with: ["success": true], context: context)
    }

    // MARK: - Import Queue

    private func queueImportItem(_ item: [String: Any]) {
        var queue = defaults?.array(forKey: "safariImportQueue") as? [[String: Any]] ?? []

        var mutableItem = item
        mutableItem["id"] = UUID().uuidString
        mutableItem["timestamp"] = Date().timeIntervalSince1970
        queue.append(mutableItem)

        defaults?.set(queue, forKey: "safariImportQueue")
        defaults?.synchronize()

        // Post Darwin notification to wake main app
        postDarwinNotification(name: "com.imbib.safariImportReceived")

        logger.info("Import queue now has \(queue.count) items")
    }

    private func queueSmartSearchCreation(query: String, name: String, sourceID: String) {
        var queue = defaults?.array(forKey: "safariSmartSearchQueue") as? [[String: Any]] ?? []

        let item: [String: Any] = [
            "id": UUID().uuidString,
            "query": query,
            "name": name,
            "sourceID": sourceID,
            "timestamp": Date().timeIntervalSince1970
        ]
        queue.append(item)

        defaults?.set(queue, forKey: "safariSmartSearchQueue")
        defaults?.synchronize()

        // Post Darwin notification to wake main app and process smart search
        postDarwinNotification(name: "com.imbib.safariSmartSearchReceived")

        logger.info("Smart search queue now has \(queue.count) items")
    }

    // MARK: - Duplicate Detection

    private func checkIfExists(doi: String?, arxivID: String?, bibcode: String?) -> Bool {
        // The main app populates this cache with known identifiers
        let existingIDs = defaults?.dictionary(forKey: "knownIdentifiers") as? [String: Bool] ?? [:]

        if let doi = doi, !doi.isEmpty {
            let key = "doi:\(doi.lowercased())"
            if existingIDs[key] == true {
                return true
            }
        }

        if let arxivID = arxivID, !arxivID.isEmpty {
            // Normalize arXiv ID (remove version)
            let normalized = arxivID.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
            let key = "arxiv:\(normalized)"
            if existingIDs[key] == true {
                return true
            }
        }

        if let bibcode = bibcode, !bibcode.isEmpty {
            let key = "bibcode:\(bibcode)"
            if existingIDs[key] == true {
                return true
            }
        }

        return false
    }

    // MARK: - Response Helper

    private func respond(with response: [String: Any], context: NSExtensionContext) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item])
    }

    // MARK: - Darwin Notifications

    private func postDarwinNotification(name: String) {
        let cfName = name as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(cfName),
            nil,
            nil,
            true
        )
    }
}
