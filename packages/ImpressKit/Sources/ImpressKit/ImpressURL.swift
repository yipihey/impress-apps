import Foundation

/// Builds and parses Impress suite deep-link URLs.
///
/// URL grammar: `{app}://{action}/{resource-type}[/{id}][?params]`
///
/// Examples:
/// - `imbib://open/paper/Einstein2005`
/// - `imbib://search?query=gravity`
/// - `imprint://open/document/550e8400-e29b-41d4-a716-446655440000`
/// - `impart://compose?to=alice@example.com&subject=Hello`
public struct ImpressURL: Sendable {

    public let app: SiblingApp
    public let action: String
    public let resourceType: String?
    public let resourceID: String?
    public let parameters: [String: String]

    public init(app: SiblingApp, action: String, resourceType: String? = nil, resourceID: String? = nil, parameters: [String: String] = [:]) {
        self.app = app
        self.action = action
        self.resourceType = resourceType
        self.resourceID = resourceID
        self.parameters = parameters
    }

    /// Constructs the URL from components.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = app.urlScheme
        components.host = action

        var pathParts: [String] = []
        if let resourceType { pathParts.append(resourceType) }
        if let resourceID { pathParts.append(resourceID) }
        if !pathParts.isEmpty {
            components.path = "/" + pathParts.joined(separator: "/")
        }

        if !parameters.isEmpty {
            components.queryItems = parameters.sorted(by: { $0.key < $1.key }).map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
        }

        return components.url
    }

    /// Parses an Impress deep-link URL.
    /// - Parameter url: The URL to parse.
    /// - Returns: A parsed `ImpressURL`, or nil if the URL doesn't match any suite app scheme.
    public static func parse(_ url: URL) -> ImpressURL? {
        guard let scheme = url.scheme,
              let app = SiblingApp.allCases.first(where: { $0.urlScheme == scheme }) else {
            return nil
        }

        let action = url.host ?? ""
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let resourceType = pathComponents.count > 0 ? pathComponents[0] : nil
        let resourceID = pathComponents.count > 1 ? pathComponents[1...].joined(separator: "/") : nil

        var parameters: [String: String] = [:]
        if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in queryItems {
                parameters[item.name] = item.value
            }
        }

        return ImpressURL(
            app: app,
            action: action,
            resourceType: resourceType,
            resourceID: resourceID,
            parameters: parameters
        )
    }

    // MARK: - Convenience Builders

    /// `imbib://open/paper/{citeKey}`
    public static func openPaper(citeKey: String) -> ImpressURL {
        ImpressURL(app: .imbib, action: "open", resourceType: "paper", resourceID: citeKey)
    }

    /// `imbib://search?query={text}`
    public static func searchPapers(query: String) -> ImpressURL {
        ImpressURL(app: .imbib, action: "search", parameters: ["query": query])
    }

    /// `imbib://add/doi/{doi}`
    public static func addDOI(_ doi: String) -> ImpressURL {
        ImpressURL(app: .imbib, action: "add", resourceType: "doi", resourceID: doi)
    }

    /// `imbib://navigate/{target}` (inbox, library, etc.)
    public static func navigateImbib(_ target: String) -> ImpressURL {
        ImpressURL(app: .imbib, action: "navigate", resourceType: target)
    }

    /// `imbib://export/bibtex?keys={csv}`
    public static func exportBibTeX(keys: [String]) -> ImpressURL {
        ImpressURL(app: .imbib, action: "export", resourceType: "bibtex", parameters: ["keys": keys.joined(separator: ",")])
    }

    /// `imprint://open/document/{uuid}`
    public static func openDocument(id: UUID) -> ImpressURL {
        ImpressURL(app: .imprint, action: "open", resourceType: "document", resourceID: id.uuidString)
    }

    /// `imprint://create/document?title={t}`
    public static func createDocument(title: String) -> ImpressURL {
        ImpressURL(app: .imprint, action: "create", resourceType: "document", parameters: ["title": title])
    }

    /// `imprint://insert/citation/{key}`
    public static func insertCitation(citeKey: String) -> ImpressURL {
        ImpressURL(app: .imprint, action: "insert", resourceType: "citation", resourceID: citeKey)
    }

    /// `impart://open/conversation/{uuid}`
    public static func openConversation(id: UUID) -> ImpressURL {
        ImpressURL(app: .impart, action: "open", resourceType: "conversation", resourceID: id.uuidString)
    }

    /// `impart://compose?to={email}&subject={s}`
    public static func compose(to: String, subject: String? = nil) -> ImpressURL {
        var params: [String: String] = ["to": to]
        if let subject { params["subject"] = subject }
        return ImpressURL(app: .impart, action: "compose", parameters: params)
    }

    /// `implore://open/figure/{uuid}`
    public static func openFigure(id: UUID) -> ImpressURL {
        ImpressURL(app: .implore, action: "open", resourceType: "figure", resourceID: id.uuidString)
    }

    /// `implore://export/figure/{uuid}?format={fmt}`
    public static func exportFigure(id: UUID, format: String) -> ImpressURL {
        ImpressURL(app: .implore, action: "export", resourceType: "figure", resourceID: id.uuidString, parameters: ["format": format])
    }

    /// `impel://open/thread/{uuid}`
    public static func openThread(id: UUID) -> ImpressURL {
        ImpressURL(app: .impel, action: "open", resourceType: "thread", resourceID: id.uuidString)
    }

    /// `impel://ask?question={text}`
    public static func askCounsel(question: String) -> ImpressURL {
        ImpressURL(app: .impel, action: "ask", parameters: ["question": question])
    }

    /// `imbib://open/artifact/{uuid}`
    public static func openArtifact(id: UUID) -> ImpressURL {
        ImpressURL(app: .imbib, action: "open", resourceType: "artifact", resourceID: id.uuidString)
    }

    /// `imbib://open/artifact/{uuid}?type={schema}`
    public static func openArtifact(id: UUID, type: String) -> ImpressURL {
        ImpressURL(app: .imbib, action: "open", resourceType: "artifact", resourceID: id.uuidString, parameters: ["type": type])
    }

    /// `imbib://navigate/artifacts?type={schema}`
    public static func navigateArtifacts(type: String? = nil) -> ImpressURL {
        var params: [String: String] = [:]
        if let type { params["type"] = type }
        return ImpressURL(app: .imbib, action: "navigate", resourceType: "artifacts", parameters: params)
    }
}
