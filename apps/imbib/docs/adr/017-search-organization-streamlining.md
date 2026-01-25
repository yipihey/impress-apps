# ADR-017: Search Organization Streamlining

## Status

Accepted

## Date

2026-01-19

## Context

imbib supports multiple search interfaces (arXiv Category, arXiv Author Group, arXiv Advanced, ADS Modern, ADS Classic, Paper Lookup) and allows users to save searches as "Smart Searches" that can be re-executed. However, the original implementation had architectural issues causing confusion:

1. **Duplication problem:** Feed forms created smart searches in the active/exploration library but set `feedsToInbox = true`, creating a confusing split where the search entity lived in one place but results flowed to another.

2. **Unclear UI:** Smart searches in regular libraries could have a "Feed to Inbox" toggle, making it unclear what the search would actually do.

3. **Inconsistent swipe actions:** The same swipe gestures had different meanings depending on context, and "Keep" was shown even for papers already in a library.

### User Mental Model

Users think about searches in three distinct ways:

| Mental Model | Use Case | Expected Behavior |
|--------------|----------|-------------------|
| **Library Smart Search** | "Show me papers matching X in my library" | Stored in library, manual refresh |
| **Inbox Feed** | "Notify me of new papers matching X" | Auto-refreshes, results flow to Inbox |
| **Exploration Search** | "Let me browse papers matching X" | One-off search, no persistence |

The previous architecture didn't cleanly map to these mental models.

## Decision

### Three Distinct Search Types

Introduce explicit separation between search types with clear ownership and behavior:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Search Creation Points                             │
├─────────────────────┬─────────────────────┬─────────────────────────────────┤
│  Library + Button   │   Inbox + Button    │   Search Section               │
│  (in sidebar)       │   (in sidebar)      │   (main content)               │
├─────────────────────┼─────────────────────┼─────────────────────────────────┤
│  Creates:           │  Creates:           │  Creates:                       │
│  Library Smart      │  Inbox Feed         │  Exploration Search            │
│  Search             │                     │                                 │
├─────────────────────┼─────────────────────┼─────────────────────────────────┤
│  feedsToInbox=false │  feedsToInbox=true  │  feedsToInbox=false            │
│  autoRefresh=false  │  autoRefresh=true   │  autoRefresh=false             │
│  Stored in: Library │  Stored in: Inbox   │  Stored in: Exploration        │
└─────────────────────┴─────────────────────┴─────────────────────────────────┘
```

### SearchFormMode Enum

Forms receive a mode that determines their behavior:

```swift
public enum SearchFormMode: Equatable {
    case librarySmartSearch(CDLibrary)  // From library + button
    case inboxFeed                       // From Inbox + button
    case explorationSearch               // From Search section

    public var createButtonTitle: String {
        switch self {
        case .librarySmartSearch: return "Create Smart Search"
        case .inboxFeed: return "Create Feed"
        case .explorationSearch: return "Search"
        }
    }
}
```

### Factory Methods in SmartSearchRepository

Explicit factory methods enforce correct attribute combinations:

```swift
/// For library smart searches (from + button in library)
@discardableResult
public func createLibrarySmartSearch(
    name: String,
    query: String,
    sourceIDs: [String],
    library: CDLibrary,
    maxResults: Int16? = nil
) -> CDSmartSearch
// feedsToInbox = false, autoRefreshEnabled = false

/// For inbox feeds (from + button in Inbox)
@discardableResult
public func createInboxFeed(
    name: String,
    query: String,
    sourceIDs: [String],
    maxResults: Int16? = nil,
    refreshIntervalSeconds: Int32 = 3600,
    isGroupFeed: Bool = false
) -> CDSmartSearch
// feedsToInbox = true, autoRefreshEnabled = true
// library = InboxManager.shared.getOrCreateInbox()

/// For exploration searches (ad-hoc from Search section)
@discardableResult
public func createExplorationSearch(
    name: String,
    query: String,
    sourceIDs: [String],
    maxResults: Int16? = nil
) -> CDSmartSearch
// feedsToInbox = false, autoRefreshEnabled = false
// library = LibraryManager.getOrCreateExplorationLibrary()
```

### Sidebar UI Changes

#### Inbox Section Header
Add + menu to Inbox section header for creating feeds:

```
┌─────────────────────────────────────┐
│ ▼ Inbox                        [+] │  ← + menu with feed options
│   ├─ Unread (42)                    │
│   ├─ All Items                      │
│   └─ Feeds                          │
│       ├─ astro-ph.CO Daily          │
│       └─ Favorite Authors           │
└─────────────────────────────────────┘
```

#### Library Section Headers
Add + menu to each library header for creating smart searches and collections:

```
┌─────────────────────────────────────┐
│ ▼ My Papers                    [+] │  ← + menu
│   ├─ All Publications               │
│   ├─ Smart Searches                 │
│   │   └─ Recent Cosmology           │
│   └─ Collections                    │
│       └─ Thesis References          │
└─────────────────────────────────────┘
```

The + menu contains:
- **New Smart Search** (submenu with all search interfaces)
- **New Smart Collection** (local predicate-based filtering)
- **New Collection** (static collection)

### Removal of "Feed to Inbox" Toggle

The "Feed to Inbox" toggle is removed from all search forms. The mode (determined by where the form was opened) controls behavior:

- Opened from **Library + button** → Creates library smart search
- Opened from **Inbox + button** → Creates inbox feed
- Opened from **Search section** → Creates exploration search

### Context-Aware Swipe Actions

Swipe actions now differ based on context:

| Context | Left Swipe (Trailing) | Right Swipe (Leading) |
|---------|----------------------|----------------------|
| **Inbox/Exploration** | Dismiss | Keep + Toggle Read |
| **Library** | Dismiss | Toggle Read only |

Rationale: In libraries, "Keep" is implied—the paper is already kept. Only Dismiss and Toggle Read are relevant actions.

## Consequences

### Benefits

- **Clear mental model:** Three distinct search types match user expectations
- **No duplication:** Each search lives in exactly one place
- **Discoverable UI:** + buttons in section headers follow platform conventions
- **Consistent actions:** Swipe actions match context appropriately
- **Reduced confusion:** No "Feed to Inbox" toggle to misunderstand

### Costs

- **Migration:** Existing smart searches with `feedsToInbox=true` in non-Inbox libraries need handling
- **Code changes:** Forms need mode parameter threaded through
- **Platform parity:** iOS and macOS implementations must stay synchronized

### Risks

- **User retraining:** Users familiar with old toggle need to learn new model
- **Edge cases:** What if user wants a feed that doesn't go to Inbox? (Not supported—use exploration search and manually check)

## Alternatives Considered

### 1. Keep "Feed to Inbox" Toggle

Maintain the toggle but fix the storage location issue.

**Rejected:** The toggle was confusing. Users didn't understand when to use it. Removing it and using context-based creation is clearer.

### 2. Single + Button in Sidebar Header

One + button for all creation actions.

**Rejected:** Doesn't provide locality. Users expect to create things near where they'll appear.

### 3. Separate "Feeds" App Section

Create a top-level "Feeds" section separate from Inbox.

**Rejected:** Feeds are conceptually tied to Inbox (they populate it). Separating them adds complexity.

## Implementation Summary

### Files Modified

| File | Changes |
|------|---------|
| `SmartSearchProvider.swift` | Added 3 factory methods |
| `ArXivFeedFormView.swift` | Added `SearchFormMode` enum, removed toggle |
| `GroupArXivFeedFormView.swift` | Added mode support |
| `ADSModernSearchFormView.swift` | Removed "Add to Inbox" |
| `ADSClassicSearchView.swift` | Removed "Add to Inbox" |
| `ADSPaperSearchView.swift` | Removed "Add to Inbox" |
| `ArXivAdvancedSearchView.swift` | Removed "Add to Inbox" |
| `SidebarView.swift` (macOS) | Added Inbox + menu, library + menus |
| `IOSSidebarView.swift` (iOS) | Added Inbox + menu, library + menus |
| `UnifiedPublicationListWrapper.swift` | Context-aware swipe actions |
| `IOSUnifiedPublicationListWrapper.swift` | Context-aware swipe actions |
| `MailStylePublicationRow.swift` | Swipe action callbacks |

### Verification

1. **Library Smart Search:** Click + in library → New Smart Search → Select interface → Create → Appears under library, no auto-refresh
2. **Inbox Feed:** Click + in Inbox → Select feed type → Create → Appears under Inbox Feeds, auto-refreshes
3. **Exploration Search:** Go to Search section → Execute search → Results in Exploration, no persistence
4. **Swipe in Library:** Left = Dismiss, Right = Toggle Read only
5. **Swipe in Inbox:** Left = Dismiss, Right = Keep + Toggle Read

## Addendum: Local-Only Exploration Library (2026-01-19)

### Context

The Exploration library stores ad-hoc search results, paper references, and citation explorations. Unlike user libraries which sync via CloudKit, exploration data is inherently transient and device-specific:

1. **Ephemeral nature:** Exploration results are for immediate browsing, not long-term storage
2. **Device context:** What you explore on your Mac may not be relevant on your iPhone
3. **Storage efficiency:** Exploration can generate large amounts of data (e.g., exploring 50 references × 10 papers)
4. **Sync conflicts:** Exploration creates many short-lived collections that would cause unnecessary sync churn

### Decision

**The Exploration library is local-only and does not sync via CloudKit.**

Implementation details:

1. **Device identifier:** Each device has a unique identifier (iOS: `identifierForVendor`, macOS: hardware UUID)
2. **Local-only flag:** `CDLibrary.isLocalOnly = true` for exploration libraries
3. **Device binding:** `CDLibrary.deviceIdentifier` stores the creating device's identifier
4. **Cleanup:** On app launch, any exploration libraries that synced from other devices are automatically deleted

```swift
// LibraryManager.swift
public func getOrCreateExplorationLibrary() -> CDLibrary {
    // Returns exploration library only for THIS device
    // Creates new one if none exists for this device
    library.isLocalOnly = true
    library.deviceIdentifier = Self.currentDeviceIdentifier
}

public func cleanupForeignLocalOnlyLibraries() {
    // Deletes local-only libraries from other devices
    // (May sync via CloudKit before we mark them as local)
}
```

### Consequences

- **No cross-device exploration:** Users cannot continue exploring on another device
- **Reduced sync traffic:** Exploration data never syncs, reducing CloudKit usage
- **Cleaner data model:** Each device maintains independent exploration state
- **Automatic cleanup:** Foreign exploration data is removed on app launch

### User Expectation

Users should not expect exploration results to appear on other devices. If they find something interesting during exploration, they should:
1. **Keep the paper:** Move it to a synced library
2. **Save the search:** Convert exploration search to a library smart search

## References

- ADR-012: Unified Library and Online Search Experience
- Apple Human Interface Guidelines: Contextual Menus
- Mail.app: Swipe action patterns
