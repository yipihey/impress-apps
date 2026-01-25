# ADR-011: In-App Console Window

## Status

Accepted

## Date

2026-01-04

## Context

During development and troubleshooting, users and developers need visibility into what the app is doing:
- BibTeX parsing can fail in subtle ways (malformed entries, encoding issues)
- Import operations process hundreds of entries with potential warnings
- External API calls may fail due to network issues, rate limits, or invalid credentials
- Users report bugs but can't easily provide diagnostic information

Currently, the app uses OSLog via custom `Logger` extensions with 10 categories and 110+ logging points. These logs are only visible in Xcode's console or macOS Console.app, which are not accessible to end users.

## Decision

Add an **in-app Console Window** that:
1. Captures log messages in a ring buffer
2. Displays them in a filterable, searchable window
3. Allows export for bug reports

## Design

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        LogStore                              │
│  (Actor - thread-safe, @Observable for SwiftUI binding)     │
│                                                              │
│  - entries: [LogEntry]  (ring buffer, max 1000)             │
│  - add(_ entry: LogEntry)                                    │
│  - clear()                                                   │
│  - export() -> String                                        │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ observed by
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     ConsoleWindow                            │
│  (SwiftUI Window, opened via ⌘⇧C)                           │
│                                                              │
│  ┌─ Toolbar ──────────────────────────────────────────────┐ │
│  │ ☑ Debug  ☑ Info  ☑ Warning  ☑ Error   [🔍 Filter]     │ │
│  │ [Clear]  [Export...]                                   │ │
│  └────────────────────────────────────────────────────────┘ │
│  ┌─ Log List ─────────────────────────────────────────────┐ │
│  │ 12:45:01  INFO   bibtex      Parsed 377 entries        │ │
│  │ 12:45:01  WARN   bibtex      Entry 'Doe2020' no title  │ │
│  │ 12:45:02  INFO   persistence Saved context             │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ captures from
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   Logger+Extensions                          │
│                                                              │
│  Modified to call LogStore.shared.add() alongside OSLog     │
└─────────────────────────────────────────────────────────────┘
```

### LogEntry Model

```swift
public struct LogEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
}

public enum LogLevel: String, CaseIterable, Sendable {
    case debug, info, warning, error

    var icon: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
}
```

### LogStore

```swift
@MainActor
@Observable
public final class LogStore {
    public static let shared = LogStore()

    private(set) var entries: [LogEntry] = []
    private let maxEntries = 1000

    func add(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() { entries.removeAll() }

    func export() -> String {
        entries.map { entry in
            let time = entry.timestamp.formatted(date: .omitted, time: .standard)
            return "[\(time)] [\(entry.level.rawValue.uppercased())] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")
    }
}
```

### Logger Integration

Modify `Logger+Extensions.swift` to add a capture function:

```swift
extension Logger {
    func log(_ level: LogLevel, category: String, _ message: String) {
        // Original OSLog call
        switch level {
        case .debug: self.debug("\(message)")
        case .info: self.info("\(message)")
        case .warning: self.warning("\(message)")
        case .error: self.error("\(message)")
        }

        // Capture to LogStore
        Task { @MainActor in
            LogStore.shared.add(LogEntry(
                id: UUID(),
                timestamp: Date(),
                level: level,
                category: category,
                message: message
            ))
        }
    }
}
```

### Console Window Features

| Feature | Implementation |
|---------|---------------|
| **Filter by level** | Toggle buttons for debug/info/warning/error |
| **Search** | Text field filters message content |
| **Category filter** | Optional dropdown for specific categories |
| **Clear** | Button to clear all entries |
| **Export** | Save to file or copy to clipboard |
| **Auto-scroll** | Scroll to bottom on new entries (toggleable) |
| **Keyboard shortcut** | ⌘⇧C to toggle window |

### Window Lifecycle

- Opened via menu `Window → Console` or `⌘⇧C`
- Separate window (not a panel) for proper window management
- Log capture happens regardless of window visibility
- Window state persisted (position, size, filter settings)

## Consequences

### Positive

- Users can see what's happening during imports and operations
- Easier debugging without Xcode
- Export logs for bug reports
- Consistent with professional apps (BBEdit, Xcode, etc.)

### Negative

- Memory overhead (~1000 entries × ~200 bytes = ~200KB)
- Slight performance overhead from dual logging
- Additional UI to maintain

### Mitigations

- Ring buffer limits memory usage
- Async dispatch to LogStore minimizes main thread impact
- Simple, focused UI with minimal maintenance burden

## Alternatives Considered

### OSLogStore Reading

Could read from OSLog directly using `OSLogStore`, but:
- Requires additional entitlements
- More complex implementation
- Can't capture logs before window opens

### Notification-Based Capture

Could use NotificationCenter to broadcast logs, but:
- More boilerplate than direct function call
- Performance overhead of notification system

### File-Based Logging

Could write logs to a file, but:
- More I/O overhead
- File management complexity
- Still need UI to display

## Implementation Plan

1. Create `LogEntry` model and `LogLevel` enum
2. Create `LogStore` actor with ring buffer
3. Modify `Logger+Extensions` to capture logs
4. Create `ConsoleWindow` SwiftUI view
5. Add `ConsoleRowView` for individual log entries
6. Add menu item and keyboard shortcut in app
7. Test with BibTeX import to verify capture
