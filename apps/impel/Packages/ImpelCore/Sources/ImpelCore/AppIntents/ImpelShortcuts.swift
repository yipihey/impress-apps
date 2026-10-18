import AppIntents
import Foundation

// MARK: - Thread Status AppEnum

@available(macOS 14.0, *)
public enum ImpelThreadStatus: String, AppEnum, Sendable {
    case active
    case blocked
    case completed

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Thread Status"
    }

    public static var caseDisplayRepresentations: [ImpelThreadStatus: DisplayRepresentation] {
        [
            .active: "Active",
            .blocked: "Blocked",
            .completed: "Completed"
        ]
    }
}

// MARK: - Intent Errors

@available(macOS 14.0, *)
public enum ImpelIntentError: Error, CustomLocalizedStringResourceConvertible {
    case automationDisabled
    case threadNotFound(String)
    case personaNotFound(String)
    case counselUnavailable
    case executionFailed(String)

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .automationDisabled:
            return "Automation API is disabled. Enable it in Settings."
        case .threadNotFound(let id):
            return "Thread not found: \(id)"
        case .personaNotFound(let name):
            return "Persona not found: \(name)"
        case .counselUnavailable:
            return "Counsel engine is not available. Check API key configuration."
        case .executionFailed(let reason):
            return "Command failed: \(reason)"
        }
    }
}
