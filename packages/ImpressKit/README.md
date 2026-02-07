# ImpressKit

Cross-app interop foundation for the Impress research suite. Provides shared types, discovery, notifications, URL schemes, and UTIs that all five apps (imbib, imprint, implore, impel, impart) use to communicate.

## Components

- **SiblingApp** - Enum of all suite apps with bundle IDs, URL schemes, HTTP ports
- **SiblingDiscovery** - Detect installed/running sibling apps
- **SharedContainer** - App Group file exchange (`group.com.impress.suite`)
- **SharedDefaults** - Cross-app UserDefaults suite
- **ImpressNotification** - Darwin notification posting/observing with file-based payloads
- **ImpressURL** - Deep-link URL builder/parser (`{app}://{action}/{resource}`)
- **ImpressURLRouter** - Protocol for per-app URL routing
- **ImpressUTTypes** - Custom UTType declarations for drag-and-drop
- **DataModels** - `ImpressPaperRef`, `ImpressDocumentRef`, `ImpressFigureRef`, `ImpressArtifact`
- **IntentTypes** - Shared `AppEnum` types: `ExportFormat`, `FigureFormat`, `ThreadStatus`

## Usage

```swift
import ImpressKit

// Discover siblings
let installed = SiblingDiscovery.shared.installedSiblings()

// Build a deep link
let url = ImpressURL.searchPapers(query: "black holes").url!

// Post a Darwin notification
ImpressNotification.post("library-changed", from: .imbib, resourceIDs: ["Einstein2005"])

// Observe notifications
let token = ImpressNotification.observe("library-changed", from: .imbib) {
    // refresh citation cache
}
```
