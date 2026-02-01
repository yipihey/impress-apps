# impart - Claude Code Briefing

Cross-platform (macOS/iOS) communication tool for email, chat, and messaging. Part of the Impress research operating environment.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  macOS App              │           iOS App                 │
├─────────────────────────┴───────────────────────────────────┤
│                    Shared SwiftUI Views                     │
├─────────────────────────────────────────────────────────────┤
│                  MessageManagerCore (Swift)                 │
│   Accounts │ Messages │ Mailboxes │ Services │ ViewModels  │
├─────────────────────────────────────────────────────────────┤
│                  ImpartRustCore (FFI)                       │
│      IMAP │ SMTP │ MIME │ Threading │ Search                │
├─────────────────────────────────────────────────────────────┤
│                    Core Data + CloudKit                     │
└─────────────────────────────────────────────────────────────┘
```

## Key Design Decisions

| Area | Decision | Details |
|------|----------|---------|
| Data | Core Data + CloudKit | Repository pattern, offline-first |
| IMAP/SMTP | Rust core | Performance, cross-platform potential |
| Threading | JWZ algorithm | Standard email threading via Rust |
| MIME | Rust parser | Full RFC 2045 compliance |
| Automation | URL schemes + HTTP API | `impart://...`, port 23122 |
| Credentials | Keychain | Secure account storage |

## Platform Parity

| Component | macOS | iOS |
|-----------|-------|-----|
| Main view | `ContentView.swift` | `IOSContentView.swift` |
| App entry | `ImpartApp.swift` | `ImpartIOSApp.swift` |
| Settings | `SettingsView.swift` | `IOSSettingsView.swift` |

**Shared**: `MessageRow`, `ThreadView`, `ComposeView`, `AccountSetupView`

## Coding Conventions

- Swift 5.9+, strict concurrency
- `actor` for stateful services, `struct` for DTOs, `final class` for view models
- Prefer `async/await` over Combine
- Domain errors conform to `LocalizedError`
- Tests: `*Tests.swift` in `MessageManagerCoreTests/`

**Naming**: Protocols `*ing`/`*able`, implementations no suffix, view models `*ViewModel`, platform-specific `IOS*` or `+platform.swift`

## Key Types

```swift
CDAccount: NSManagedObject   // Email account (IMAP/SMTP settings, credentials ref)
CDMailbox: NSManagedObject   // Folder (INBOX, Sent, custom)
CDMessage: NSManagedObject   // Email message (headers, body ref, thread)
CDThread: NSManagedObject    // Conversation thread (computed via JWZ)

Account: Sendable            // Account configuration DTO
Message: Sendable            // Message DTO for display
Mailbox: Sendable            // Mailbox DTO
Thread: Sendable             // Thread DTO with messages

protocol MailProvider: Sendable {
    func connect() async throws
    func fetchMailboxes() async throws -> [Mailbox]
    func fetchMessages(mailbox: Mailbox, range: MessageRange) async throws -> [Message]
    func send(_ draft: DraftMessage) async throws
}
```

## Integration Points

- **imbib**: Paper extraction from email attachments/links
- **imprint**: Citation links in composed messages
- **impel**: Agent review queue for AI-drafted responses
- **MCP**: Tools exposed via impress-mcp server

## HTTP API (Port 23122)

```
GET  /api/status               # Server health
GET  /api/accounts             # List accounts
GET  /api/mailboxes            # List mailboxes
GET  /api/messages?mailbox={id} # List messages
GET  /api/messages/{id}        # Get message detail
POST /api/messages/send        # Send message (future)
```

## Project Status

**Current Phase**: Scaffolding - directory structure and placeholder types

**Not Yet**: IMAP sync, SMTP send, threading, search, AI draft review

## Commands

```bash
cd MessageManagerCore && swift build    # Build package
swift test                               # Run tests
xcodegen generate                        # Generate Xcode project
xcodebuild -scheme impart -configuration Debug build  # Build macOS app
```

## Session Continuity

When resuming: `git status`, check project.yml for targets, review this briefing.
