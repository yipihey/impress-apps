import Foundation

/// A unified artifact type representing any cross-app reference in the Impress suite.
public enum ImpressArtifact: Codable, Sendable, Hashable {
    case paper(ImpressPaperRef)
    case document(ImpressDocumentRef)
    case figure(ImpressFigureRef)
    case conversationRef(id: UUID, subject: String?)

    /// The unique identifier regardless of artifact type.
    public var id: UUID {
        switch self {
        case .paper(let ref): return ref.id
        case .document(let ref): return ref.id
        case .figure(let ref): return ref.id
        case .conversationRef(let id, _): return id
        }
    }

    /// The source app that owns this artifact type.
    public var sourceApp: SiblingApp {
        switch self {
        case .paper: return .imbib
        case .document: return .imprint
        case .figure: return .implore
        case .conversationRef: return .impart
        }
    }

    /// A human-readable display string.
    public var displayName: String {
        switch self {
        case .paper(let ref): return ref.title ?? ref.citeKey
        case .document(let ref): return ref.title
        case .figure(let ref): return ref.title ?? "Figure"
        case .conversationRef(_, let subject): return subject ?? "Conversation"
        }
    }
}
