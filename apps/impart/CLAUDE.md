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
│                    Core Data (local only)                   │
└─────────────────────────────────────────────────────────────┘
```

## Key Design Decisions

| Area | Decision | Details |
|------|----------|---------|
| Data | Core Data (local only) | Repository pattern, offline-first; CloudKit wiring is commented out |
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
- **MCP**: Tools exposed via `crates/impress-mcp`, generated from the
  `#[impress_service]` traits in `crates/impart-service`

## HTTP API (Port 23122)

```
GET  /api/status               # Server health
GET  /api/accounts             # List accounts
GET  /api/mailboxes            # List mailboxes
GET  /api/messages?mailbox={id} # List messages
GET  /api/messages/{id}        # Get message detail
GET  /api/logs                 # Query in-app log entries
POST /api/messages/send        # Send message (future)
```

### Live Log Access

When the HTTP server is enabled, logs are accessible for debugging:

```bash
curl 'http://localhost:23122/api/logs?limit=20&level=info,warning,error'
curl 'http://localhost:23122/api/logs?category=imap&limit=20'
```

The MCP tool `impart_get_logs` provides the same access for AI agents. **Always verify new features by checking logs after testing.**

## Watched archive folders (ADR-0023 W4)

impart's Mail section can watch a folder of `.mbox` / `.eml` archives (macOS;
"Watch Folder for .mbox / .eml Files…" in the section menu). **It indexes them
and offers them. It does not import mail.**

- Selecting the row opens `WatchedFilesPane` — the archives, their sizes, their
  missing state, and `Count Messages`, which runs the REAL parser
  (`imbib_core::mbox::parse_content`) **under a 64 MB ceiling** and refuses
  above it in a sentence the row renders.
- **There is no mbox → messages fan-out, and that is the decision, not a TODO.**
  Three reasons, recorded in the ADR's W4 section: impart has no mbox importer
  to hand off to (`MessageManagerCore/Mbox/MboxConversationStore` is a
  *research-conversation* store; PMC's `MboxImporter` imports **imbib library
  exports** that merely use mbox as a container); mail's lifecycle is IMAP-owned
  so minted rows would have read state nothing reconciles; and a 2 GB archive
  fanning out the moment a folder is picked is D7's burst hazard exactly.
- If a real archive importer is ever built, it belongs behind
  `WatchedFolderImportHooks.produceRows` for the `message` kind — that closure
  is the only thing the coordinator needs, and nothing else changes.

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
