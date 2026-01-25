# ADR-019: Dual Monitor Support

**Status:** Proposed
**Date:** 2026-01-19
**Author:** Tom Abel

## Context

imbib users frequently work with PDFs alongside notes, annotations, and bibliography metadata. A common workflow involves reading a paper on one screen while taking notes or cross-referencing citations on another. Currently, imbib uses a single-window `NavigationSplitView` with the PDF embedded in a detail tab—users cannot view the PDF and notes simultaneously without manual window management.

### Current Architecture

imbib already has multi-window capabilities:
- **PDFBrowserWindowController**: Manages separate browser windows for PDF downloads (one per publication)
- **Console/Keyboard Shortcuts windows**: Additional `Window` scenes in the SwiftUI app
- **AppStateStore**: Actor-based state persistence for sidebar selection, publication, tab, etc.
- **ReadingPositionStore**: Persists PDF page/zoom per publication
- **Notification system**: Rich inter-view coordination via NotificationCenter

The detail view has four tabs (Info, BibTeX, PDF, Notes) that are self-contained components, making them candidates for extraction to separate windows.

## Decision

We will implement dual-monitor support by allowing **any detail tab to be "popped out" to a separate window**, with intelligent placement on secondary displays when available.

### 1. Screen Configuration Observer

A new `ScreenConfigurationObserver` in PublicationManagerCore:

```swift
@MainActor
@Observable
public final class ScreenConfigurationObserver {
    public static let shared = ScreenConfigurationObserver()

    public private(set) var screens: [NSScreen] = []
    public var hasSecondaryScreen: Bool { screens.count > 1 }
    public var secondaryScreen: NSScreen? { screens.count > 1 ? screens[1] : nil }
    public private(set) var configurationHash: String = ""

    private init() {
        updateScreens()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc private func screensChanged(_ notification: Notification) {
        updateScreens()
    }

    private func updateScreens() {
        screens = NSScreen.screens
        configurationHash = screens.map {
            "\($0.localizedName)_\(Int($0.frame.width))x\(Int($0.frame.height))"
        }.joined(separator: "|")
    }
}
```

### 2. Detachable Detail Tabs

Each detail tab gains a "pop out" button (visible only on macOS):

| Tab | Pop-Out Behavior |
|-----|------------------|
| PDF | Opens PDF viewer in new window, maximized on secondary if available |
| Notes | Opens notes editor in new window |
| BibTeX | Opens BibTeX editor in new window |
| Info | Opens info panel in new window |

**UI Placement:**
- Small "open in new window" icon (⧉) in each tab's toolbar
- Only shown on macOS (hidden on iOS via `#if os(macOS)`)
- When secondary display available, icon has badge indicator

### 3. Detached Window Controller

Extend the `PDFBrowserWindowController` pattern to a generalized `DetailWindowController`:

```swift
@MainActor
public final class DetailWindowController {
    public static let shared = DetailWindowController()

    // Track open windows by (publicationID, tabType)
    private var windows: [WindowKey: NSWindow] = [:]

    struct WindowKey: Hashable {
        let publicationID: UUID
        let tab: DetailTab
    }

    public func openTab(_ tab: DetailTab, for publication: CDPublication,
                        onScreen: NSScreen? = nil) {
        let key = WindowKey(publicationID: publication.id, tab: tab)

        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let targetScreen = onScreen
            ?? ScreenConfigurationObserver.shared.secondaryScreen
            ?? NSScreen.main

        let window = createWindow(for: tab, publication: publication)
        positionWindow(window, on: targetScreen, tab: tab)
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
    }

    public func closeWindows(for publicationID: UUID) {
        // Close all detached windows for a publication
    }
}
```

### 4. Window Placement Strategy

```
┌─────────────────────┐    ┌─────────────────────┐
│   Primary Display   │    │  Secondary Display  │
│                     │    │                     │
│  ┌───────────────┐  │    │  ┌───────────────┐  │
│  │  Main Window  │  │    │  │ Detached Tab  │  │
│  │  - Sidebar    │  │    │  │               │  │
│  │  - List       │  │    │  │  PDF / Notes  │  │
│  │  - Detail     │  │    │  │  / BibTeX     │  │
│  │    (remaining │  │    │  │               │  │
│  │     tabs)     │  │    │  │               │  │
│  └───────────────┘  │    │  └───────────────┘  │
└─────────────────────┘    └─────────────────────┘
```

**Placement Rules:**
1. Detached PDF windows → maximize on secondary (or right half of primary)
2. Detached Notes windows → standard size, secondary or floating
3. User moves are persisted per configuration hash
4. On secondary disconnect → migrate to primary with 50% width tile

### 5. Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘⇧P` | Pop out PDF tab to secondary |
| `⌘⇧N` | Pop out Notes tab to secondary |
| `⌘⇧F` | Flip/swap main window and detached window positions |
| `⌘⇧W` | Close all detached windows for current publication |

### 6. State Persistence

Extend `AppStateStore` with window state:

```swift
struct DetachedWindowState: Codable {
    let publicationID: UUID
    let tab: DetailTab
    let frame: CGRect
    let screenIndex: Int
}

// In AppStateStore
@Published var detachedWindows: [String: [DetachedWindowState]] = [:]
// Key = configurationHash
```

On launch, restore detached windows for publications that are still in the library.

### 7. Synchronized State

Detached windows share view models with the main window:
- **PDFKitViewer** uses same `ReadingPositionStore` → page/zoom synced
- **Notes editor** shares `publication.fields["note"]` binding → edits reflected
- **BibTeX editor** shares publication → changes reflected

This works because:
- View models are `@Observable` and `@MainActor`
- Core Data objects (`CDPublication`) are observable
- No duplication of state needed

### 8. Integration Points

**Existing code to leverage:**
- `PDFBrowserWindowController.swift` → Rename/generalize to `DetailWindowController`
- `AppStateStore.swift` → Add `detachedWindows` property
- `ReadingPositionStore.swift` → Already works across windows
- `DetailView.swift` → Extract tab content to reusable views

**New files:**
- `ScreenConfigurationObserver.swift` (PublicationManagerCore)
- `DetailWindowController.swift` (imbib/macOS only)
- `DetachedPDFView.swift`, `DetachedNotesView.swift`, etc. (minimal wrappers)

## Consequences

### Benefits

- **Reduced friction:** One-click tab detachment to secondary display
- **Flexible layouts:** Any combination of tabs can be on either screen
- **Familiar pattern:** Extends existing multi-window architecture
- **Keyboard-driven:** Full keyboard control for power users
- **State preserved:** Reading position, edits sync automatically

### Costs

- **macOS only:** iOS cannot benefit (single-window paradigm)
- **Complexity:** Window lifecycle management across displays
- **Testing:** Need to test display connect/disconnect scenarios

### Risks

- **Fullscreen/Spaces:** May conflict with macOS fullscreen; needs testing
- **Publication deletion:** Must handle closing windows for deleted publications
- **Memory:** Multiple PDF views could use significant memory

## Alternatives Considered

### 1. Split Detail View (Horizontal)

Allow two tabs side-by-side within the existing detail pane.

**Rejected:** Limited space in detail pane; doesn't leverage second monitor.

### 2. Separate PDF Window Only

Only support detaching the PDF tab.

**Rejected:** Users also want notes on secondary; limiting to PDF is arbitrary.

### 3. Automatic Placement

Always place detached windows on secondary when available.

**Rejected:** User may prefer specific placement; offer default but allow override.

## Implementation Plan

| Phase | Scope | Files |
|-------|-------|-------|
| 1 | ScreenConfigurationObserver | `PublicationManagerCore/ScreenConfigurationObserver.swift` |
| 2 | DetailWindowController (based on PDFBrowserWindowController) | `imbib/Views/Windows/DetailWindowController.swift` |
| 3 | Detached tab views (PDF, Notes, BibTeX, Info) | `imbib/Views/Windows/Detached*.swift` |
| 4 | Pop-out buttons in detail tabs | `DetailView.swift` toolbar additions |
| 5 | Keyboard shortcuts | `imbibApp.swift` commands |
| 6 | State persistence | `AppStateStore.swift` extension |
| 7 | Display disconnect handling | `DetailWindowController.swift` |
| 8 | Testing + edge cases | Test files |

**Estimated effort:** 4-5 days

## References

- [NSScreen Documentation](https://developer.apple.com/documentation/appkit/nsscreen)
- [NSWindow Documentation](https://developer.apple.com/documentation/appkit/nswindow)
- Existing: `PDFBrowserWindowController.swift` (pattern to follow)
- Existing: `AppStateStore.swift` (state persistence pattern)
