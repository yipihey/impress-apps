import AppIntents
import Foundation

// MARK: - Navigation Target AppEnum

@available(macOS 14.0, iOS 17.0, *)
public enum ImpartNavigationTarget: String, AppEnum, Sendable {
    case inbox
    case sent
    case drafts
    case conversations

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Navigation Target"
    }

    public static var caseDisplayRepresentations: [ImpartNavigationTarget: DisplayRepresentation] {
        [
            .inbox: "Inbox",
            .sent: "Sent",
            .drafts: "Drafts",
            .conversations: "Conversations"
        ]
    }
}

// MARK: - Intent Errors

@available(macOS 14.0, iOS 17.0, *)
public enum ImpartIntentError: Error, CustomLocalizedStringResourceConvertible {
    case automationDisabled
    case messageNotFound(String)
    case conversationNotFound(String)
    case sendFailed(String)
    case executionFailed(String)

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .automationDisabled:
            return "Automation API is disabled. Enable it in Settings."
        case .messageNotFound(let id):
            return "Message not found: \(id)"
        case .conversationNotFound(let id):
            return "Conversation not found: \(id)"
        case .sendFailed(let reason):
            return "Send failed: \(reason)"
        case .executionFailed(let reason):
            return "Command failed: \(reason)"
        }
    }
}

// MARK: - Shortcuts Provider

@available(macOS 14.0, iOS 17.0, *)
public struct ImpartShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchMessagesIntent(),
            phrases: [
                "Search \(.applicationName) messages",
                "Find messages in \(.applicationName)"
            ],
            shortTitle: "Search Messages",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: ComposeMessageIntent(),
            phrases: [
                "Compose message in \(.applicationName)",
                "Send email with \(.applicationName)"
            ],
            shortTitle: "Compose Message",
            systemImageName: "square.and.pencil"
        )

        AppShortcut(
            intent: ListConversationsIntent(),
            phrases: [
                "List \(.applicationName) conversations",
                "Show my \(.applicationName) conversations"
            ],
            shortTitle: "List Conversations",
            systemImageName: "bubble.left.and.bubble.right"
        )

        AppShortcut(
            intent: NavigateImpartIntent(),
            phrases: [
                "Go to \(.applicationName) inbox",
                "Show my \(.applicationName) inbox"
            ],
            shortTitle: "Go to Inbox",
            systemImageName: "tray"
        )
    }
}
