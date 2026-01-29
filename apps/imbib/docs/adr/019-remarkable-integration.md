# ADR-019: reMarkable Tablet Integration

**Status:** Proposed
**Date:** 2026-01-28
**Authors:** Claude

## Context

reMarkable tablets are popular among researchers for reading and annotating academic papers. Integrating imbib with reMarkable would enable:
- Seamless transfer of PDFs to the device with organized folder structure
- Annotation round-trip: highlights and notes flow back into imbib
- Reading progress tracking across devices
- Downstream use in imprint (citing papers with annotations)

## Decision

Implement reMarkable integration as a **new module** within PublicationManagerCore, following the existing plugin and sync patterns.

---

## 1. Data Model Changes

### 1.1 New Entities

```swift
// MARK: - CDRemarkableDocument

/// Tracks a publication's presence on reMarkable devices.
@objc(CDRemarkableDocument)
public class CDRemarkableDocument: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var remarkableID: String         // reMarkable's document UUID
    @NSManaged public var parentFolderID: String?      // reMarkable folder UUID
    @NSManaged public var version: Int32               // Document version for sync
    @NSManaged public var lastModifiedOnDevice: Date?  // When modified on reMarkable
    @NSManaged public var lastSyncedAt: Date?          // When last synced with imbib
    @NSManaged public var syncState: String            // pending, synced, conflict, error
    @NSManaged public var deviceID: String?            // Which reMarkable device

    // Relationships
    @NSManaged public var publication: CDPublication?
    @NSManaged public var linkedFile: CDLinkedFile?    // The PDF on disk
}

// MARK: - CDRemarkableAnnotation

/// Annotation imported from reMarkable (distinct from CDAnnotation for .rm-specific data).
@objc(CDRemarkableAnnotation)
public class CDRemarkableAnnotation: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var pageNumber: Int32
    @NSManaged public var layerName: String?           // reMarkable layer identifier
    @NSManaged public var strokesData: Data?           // Raw .rm stroke data for fidelity
    @NSManaged public var renderedImage: Data?         // PNG render for quick display
    @NSManaged public var extractedText: String?       // OCR result if available
    @NSManaged public var bounds: String               // JSON-encoded CGRect
    @NSManaged public var dateCreated: Date
    @NSManaged public var dateModified: Date

    // Relationships
    @NSManaged public var remarkableDocument: CDRemarkableDocument?
    @NSManaged public var convertedAnnotation: CDAnnotation?  // If converted to standard annotation
}
```

### 1.2 CDPublication Extensions

```swift
extension CDPublication {
    /// reMarkable sync state
    var remarkableSyncState: RemarkableSyncState {
        get {
            guard let json = fields["imbib:remarkableState"],
                  let data = json.data(using: .utf8),
                  let state = try? JSONDecoder().decode(RemarkableSyncState.self, from: data)
            else { return RemarkableSyncState() }
            return state
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                var mutableFields = fields
                mutableFields["imbib:remarkableState"] = json
                self.fields = mutableFields
            }
        }
    }
}

struct RemarkableSyncState: Codable {
    var isOnDevice: Bool = false
    var lastPushed: Date?
    var lastAnnotationSync: Date?
    var annotationCount: Int = 0
    var readProgress: Double = 0  // 0.0-1.0
    var deviceID: String?
}
```

### 1.3 Annotation Relationship

```
CDPublication
    └── CDRemarkableDocument (1:1)
           ├── CDRemarkableAnnotation (1:N) - raw reMarkable data
           └── CDLinkedFile (reference to PDF)
                  └── CDAnnotation (1:N) - converted annotations
```

---

## 2. Module Structure

### 2.1 Directory Layout

```
PublicationManagerCore/Sources/PublicationManagerCore/
├── ReMarkable/
│   ├── RemarkableService.swift          # Main service actor
│   ├── RemarkableSettingsStore.swift    # User preferences
│   ├── RemarkableDocument.swift         # CDRemarkableDocument helpers
│   ├── RemarkableAnnotation.swift       # CDRemarkableAnnotation helpers
│   │
│   ├── Sync/
│   │   ├── RemarkableSyncManager.swift  # Orchestrates sync operations
│   │   ├── RemarkableConflictResolver.swift
│   │   └── RemarkableSyncScheduler.swift  # Background sync (like InboxScheduler)
│   │
│   ├── API/
│   │   ├── RemarkableAPIClient.swift    # Cloud API (rmapi-style)
│   │   ├── RemarkableAPIModels.swift    # API response types
│   │   └── RemarkableAuthManager.swift  # OAuth/device code flow
│   │
│   ├── Local/
│   │   ├── RemarkableFolderSync.swift   # USB/local folder sync
│   │   └── RemarkableDropboxBridge.swift # Dropbox integration
│   │
│   └── Format/
│       ├── RMFileParser.swift           # Parse .rm annotation files
│       ├── RMStrokeRenderer.swift       # Render strokes to images
│       └── RMTextExtractor.swift        # OCR integration
```

### 2.2 Feature Flag

```swift
// In PublicationManagerCore/Package.swift
.target(
    name: "PublicationManagerCore",
    dependencies: [...],
    swiftSettings: [
        .define("REMARKABLE_ENABLED", .when(configuration: .debug)),
        // Or controlled by build setting
    ]
)

// Usage
#if REMARKABLE_ENABLED
import ReMarkable
#endif
```

### 2.3 Integration Points

The module integrates with existing systems:

| Existing System | Integration |
|-----------------|-------------|
| `SourcePlugin` | Not used (reMarkable isn't a paper source) |
| `SyncService` | Coordinates with CloudKit sync |
| `AttachmentManager` | PDF export/import |
| `AnnotationPersistence` | Converts reMarkable → standard annotations |
| `URLSchemeHandler` | `imbib://remarkable/sync`, `imbib://remarkable/push` |
| `InboxScheduler` | Model for `RemarkableSyncScheduler` |

---

## 3. Sync Abstraction

### 3.1 Backend Protocol

```swift
/// Protocol for different reMarkable sync backends.
public protocol RemarkableSyncBackend: Actor {
    /// Backend identifier
    var backendID: String { get }

    /// Human-readable name
    var displayName: String { get }

    /// Whether this backend is currently available
    func isAvailable() async -> Bool

    /// Authenticate with the backend
    func authenticate() async throws

    /// List all documents on device
    func listDocuments() async throws -> [RemarkableDocumentInfo]

    /// List folders on device
    func listFolders() async throws -> [RemarkableFolderInfo]

    /// Upload a PDF to device
    func uploadDocument(
        _ data: Data,
        filename: String,
        parentFolder: String?
    ) async throws -> String  // Returns document ID

    /// Download annotations for a document
    func downloadAnnotations(documentID: String) async throws -> [RemarkableRawAnnotation]

    /// Download the full document (PDF + annotations)
    func downloadDocument(documentID: String) async throws -> RemarkableDocumentBundle

    /// Create a folder on device
    func createFolder(name: String, parent: String?) async throws -> String

    /// Delete a document from device
    func deleteDocument(documentID: String) async throws

    /// Get device info (name, storage, etc.)
    func getDeviceInfo() async throws -> RemarkableDeviceInfo
}
```

### 3.2 Backend Implementations

```swift
// MARK: - Cloud API Backend (rmapi-style)

public actor RemarkableCloudBackend: RemarkableSyncBackend {
    public let backendID = "cloud"
    public let displayName = "reMarkable Cloud"

    private let apiClient: RemarkableAPIClient
    private var deviceToken: String?

    public func authenticate() async throws {
        // Device code flow: user enters code on my.remarkable.com
        let code = try await apiClient.requestDeviceCode()
        // Poll for completion
        deviceToken = try await apiClient.pollForToken(code: code)
        // Store in Keychain via CredentialManager
    }

    public func listDocuments() async throws -> [RemarkableDocumentInfo] {
        guard let token = deviceToken else { throw RemarkableError.notAuthenticated }
        return try await apiClient.listDocuments(token: token)
    }
    // ... other methods
}

// MARK: - Local Folder Backend

public actor RemarkableLocalBackend: RemarkableSyncBackend {
    public let backendID = "local"
    public let displayName = "Local Folder"

    private let folderURL: URL  // User-selected folder

    public func isAvailable() async -> Bool {
        FileManager.default.fileExists(atPath: folderURL.path)
    }

    public func listDocuments() async throws -> [RemarkableDocumentInfo] {
        // Parse .metadata files in folder
        let contents = try FileManager.default.contentsOfDirectory(at: folderURL, ...)
        return contents.compactMap { parseMetadataFile($0) }
    }
    // ... other methods
}

// MARK: - Dropbox Bridge Backend

public actor RemarkableDropboxBackend: RemarkableSyncBackend {
    public let backendID = "dropbox"
    public let displayName = "Dropbox Integration"

    // Uses reMarkable's native Dropbox integration
    // Watches ~/Dropbox/Apps/remarkable/ or similar
}
```

### 3.3 Backend Manager

```swift
@MainActor @Observable
public final class RemarkableBackendManager {
    public static let shared = RemarkableBackendManager()

    public private(set) var availableBackends: [any RemarkableSyncBackend] = []
    public var activeBackend: (any RemarkableSyncBackend)?

    public func selectBackend(_ backendID: String) async throws {
        guard let backend = availableBackends.first(where: { $0.backendID == backendID }) else {
            throw RemarkableError.backendNotFound(backendID)
        }
        guard await backend.isAvailable() else {
            throw RemarkableError.backendUnavailable(backendID)
        }
        activeBackend = backend
    }
}
```

---

## 4. Annotation Format

### 4.1 Storage Strategy

**Hybrid approach:**

1. **Raw .rm data** → Stored in `CDRemarkableAnnotation.strokesData`
   - Preserves full fidelity for round-trip
   - Can re-render at different resolutions
   - Required for pushing edits back to device

2. **Rendered images** → Stored in `CDRemarkableAnnotation.renderedImage`
   - PNG at 2x resolution for display
   - Quick preview without parsing
   - Used in annotation timeline view

3. **Converted annotations** → `CDAnnotation` records
   - Highlights → `CDAnnotation.annotationType = "highlight"`
   - Text notes → `CDAnnotation.annotationType = "note"`
   - Ink drawings → `CDAnnotation.annotationType = "ink"` with `imageData`
   - Enables standard annotation features (search, filter, CloudKit sync)

### 4.2 Conversion Pipeline

```swift
public actor RemarkableAnnotationConverter {

    /// Convert raw reMarkable annotations to standard format.
    public func convert(
        _ rmAnnotations: [RemarkableRawAnnotation],
        document: CDRemarkableDocument,
        pdfDocument: PDFDocument
    ) async throws -> [CDAnnotation] {
        var results: [CDAnnotation] = []

        for rmAnnotation in rmAnnotations {
            switch rmAnnotation.type {
            case .highlight:
                // Extract highlighted region, find underlying text
                let text = try extractTextUnderHighlight(rmAnnotation, pdf: pdfDocument)
                let cdAnnotation = createHighlightAnnotation(
                    page: rmAnnotation.pageNumber,
                    bounds: rmAnnotation.bounds,
                    text: text,
                    color: rmAnnotation.color ?? "#FFFF00"
                )
                results.append(cdAnnotation)

            case .textNote:
                // Text written in a specific area
                let cdAnnotation = createNoteAnnotation(
                    page: rmAnnotation.pageNumber,
                    bounds: rmAnnotation.bounds,
                    contents: rmAnnotation.extractedText ?? ""
                )
                results.append(cdAnnotation)

            case .ink:
                // Render strokes to image, optionally OCR
                let image = try await renderStrokes(rmAnnotation.strokeData)
                let ocrText = try await performOCR(image)
                let cdAnnotation = createInkAnnotation(
                    page: rmAnnotation.pageNumber,
                    bounds: rmAnnotation.bounds,
                    imageData: image.pngData(),
                    extractedText: ocrText
                )
                results.append(cdAnnotation)
            }
        }

        return results
    }
}
```

### 4.3 OCR Integration

```swift
#if canImport(Vision)
import Vision

extension RemarkableAnnotationConverter {
    func performOCR(_ image: CGImage) async throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]  // Configurable

        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])

        guard let observations = request.results else { return nil }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
#endif
```

---

## 5. User Interaction Points

### 5.1 Settings UI

```swift
// In Settings/RemarkableSettingsView.swift
struct RemarkableSettingsView: View {
    @State private var settings = RemarkableSettingsStore.shared

    var body: some View {
        Form {
            Section("Connection") {
                Picker("Sync Method", selection: $settings.activeBackendID) {
                    Text("reMarkable Cloud").tag("cloud")
                    Text("Local Folder").tag("local")
                    Text("Dropbox").tag("dropbox")
                }

                if settings.activeBackendID == "cloud" {
                    if settings.isAuthenticated {
                        LabeledContent("Device", value: settings.deviceName ?? "Unknown")
                        Button("Sign Out") { ... }
                    } else {
                        Button("Connect to reMarkable Cloud") { ... }
                    }
                }

                if settings.activeBackendID == "local" {
                    PathPicker("Folder", selection: $settings.localFolderPath)
                }
            }

            Section("Sync Options") {
                Toggle("Auto-sync annotations", isOn: $settings.autoSyncAnnotations)

                Picker("Sync interval", selection: $settings.syncInterval) {
                    Text("Every 15 minutes").tag(15 * 60)
                    Text("Every hour").tag(60 * 60)
                    Text("Every 6 hours").tag(6 * 60 * 60)
                    Text("Manual only").tag(0)
                }

                Picker("Conflict resolution", selection: $settings.conflictResolution) {
                    Text("Prefer reMarkable").tag(ConflictResolution.preferRemarkable)
                    Text("Prefer imbib").tag(ConflictResolution.preferLocal)
                    Text("Keep both").tag(ConflictResolution.keepBoth)
                    Text("Ask each time").tag(ConflictResolution.ask)
                }
            }

            Section("Organization") {
                Toggle("Create folders by collection", isOn: $settings.createFoldersByCollection)
                Toggle("Create 'Reading Queue' folder", isOn: $settings.useReadingQueueFolder)
                TextField("Root folder name", text: $settings.rootFolderName)
            }

            Section("Annotations") {
                Toggle("Import highlights", isOn: $settings.importHighlights)
                Toggle("Import handwritten notes", isOn: $settings.importInkNotes)
                Toggle("Run OCR on handwritten notes", isOn: $settings.enableOCR)
            }
        }
    }
}
```

### 5.2 Publication Detail Integration

```swift
// In DetailView, add reMarkable section
struct RemarkableStatusSection: View {
    let publication: CDPublication
    @State private var remarkableDoc: CDRemarkableDocument?

    var body: some View {
        Section("reMarkable") {
            if let doc = remarkableDoc {
                LabeledContent("Status") {
                    SyncStatusBadge(state: doc.syncState)
                }
                LabeledContent("Last synced", value: doc.lastSyncedAt?.formatted() ?? "Never")
                LabeledContent("Annotations", value: "\(doc.annotations?.count ?? 0)")

                Button("Sync Annotations") {
                    Task { await syncAnnotations() }
                }

                Button("Remove from Device", role: .destructive) {
                    Task { await removeFromDevice() }
                }
            } else {
                Button("Send to reMarkable") {
                    Task { await pushToDevice() }
                }
                .disabled(!publication.hasPDFDownloaded)
            }
        }
    }
}
```

### 5.3 URL Scheme Commands

```swift
// Register in URLSchemeHandler
case remarkable(RemarkableCommand)

enum RemarkableCommand {
    case push(citeKey: String)           // imbib://remarkable/push?citeKey=einstein2020
    case sync(citeKey: String?)          // imbib://remarkable/sync or sync?citeKey=...
    case syncAll                          // imbib://remarkable/sync-all
    case openOnDevice(citeKey: String)   // imbib://remarkable/open?citeKey=...
}
```

### 5.4 Menu Bar / Keyboard Shortcuts

```swift
// In Commands/RemarkableCommands.swift
struct RemarkableCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .importExport) {
            Menu("reMarkable") {
                Button("Send to reMarkable") {
                    // Push selected publications
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Sync Annotations") {
                    // Sync selected or all
                }
                .keyboardShortcut("r", modifiers: [.command, .option])

                Divider()

                Button("reMarkable Settings...") {
                    // Open settings
                }
            }
        }
    }
}
```

### 5.5 Background Sync Daemon

```swift
public actor RemarkableSyncScheduler {
    public static let shared = RemarkableSyncScheduler()

    private var isRunning = false
    private let settings = RemarkableSettingsStore.shared

    public func start() async {
        guard !isRunning else { return }
        isRunning = true

        while isRunning {
            let interval = settings.syncInterval
            guard interval > 0 else {
                try? await Task.sleep(for: .seconds(60))
                continue
            }

            // Check if sync is due
            if shouldSync() {
                await performBackgroundSync()
            }

            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func performBackgroundSync() async {
        Logger.remarkable.info("Starting background annotation sync")

        do {
            let backend = RemarkableBackendManager.shared.activeBackend
            guard let backend else { return }

            // Fetch all documents on device that we track
            let tracked = await fetchTrackedDocuments()

            for doc in tracked {
                let annotations = try await backend.downloadAnnotations(documentID: doc.remarkableID)
                await processAnnotations(annotations, for: doc)
            }

            Logger.remarkable.info("Background sync completed")
        } catch {
            Logger.remarkable.error("Background sync failed: \(error)")
        }
    }
}
```

---

## 6. Dependencies

### 6.1 Evaluation of Existing Tools

| Tool | Language | Status | Assessment |
|------|----------|--------|------------|
| **rmapi** | Go | Active | Good CLI reference, unofficial API reverse-engineered |
| **rmapy** | Python | Active | Python wrapper for rmapi, well-documented |
| **rmrl** | Python | Active | Renders .rm files to PDF, good format reference |
| **remarks** | Python | Stale | Extracts annotations, partial .rm support |

### 6.2 Recommendation: Native Swift Implementation

**Rationale:**
- No external process spawning needed
- Full control over authentication flow
- Better integration with SwiftUI/Combine
- Can leverage imbib's existing credential management
- Easier to ship in App Store (no bundled binaries)

**Implementation approach:**
1. Port rmapi's auth flow to Swift (device code → token exchange)
2. Implement .rm file parsing in Swift (or Rust via UniFFI)
3. Use Vision.framework for OCR (no external dependency)
4. Render strokes using Core Graphics

### 6.3 Optional Rust Module

For .rm parsing performance:

```rust
// In crates/remarkable-format/src/lib.rs

#[derive(uniffi::Record)]
pub struct RmStroke {
    pub points: Vec<RmPoint>,
    pub pen_type: String,
    pub color: u32,
    pub thickness: f32,
}

#[derive(uniffi::Record)]
pub struct RmPoint {
    pub x: f32,
    pub y: f32,
    pub pressure: f32,
    pub tilt_x: f32,
    pub tilt_y: f32,
}

#[uniffi::export]
pub fn parse_rm_file(data: &[u8]) -> Result<Vec<RmStroke>, RmError> {
    // Parse binary .rm format
}

#[uniffi::export]
pub fn render_strokes_to_png(strokes: Vec<RmStroke>, width: u32, height: u32) -> Vec<u8> {
    // Render using tiny-skia or similar
}
```

---

## 7. Risks and Mitigations

### 7.1 Unofficial API Risk

**Risk:** reMarkable Cloud API is unofficial and could change/break.

**Mitigations:**
1. Support multiple backends (local folder is stable)
2. Abstract API behind protocol for easy updates
3. Version-gate API calls with feature flags
4. Graceful degradation if API fails
5. Store credentials securely (Keychain) for re-auth

### 7.2 .rm Format Changes

**Risk:** reMarkable's binary format could change between firmware versions.

**Mitigations:**
1. Store raw data alongside parsed data
2. Version detection in parser
3. Fallback to image-only mode if parsing fails
4. Community maintains format documentation

### 7.3 Large File Sync

**Risk:** PDFs with heavy annotations could be large.

**Mitigations:**
1. Incremental annotation sync (only changed pages)
2. Compress rendered images
3. Optional: sync annotations only, not strokes
4. Respect metered network settings

### 7.4 Conflict Resolution Complexity

**Risk:** User edits on both imbib and reMarkable.

**Mitigations:**
1. Clear conflict UI with side-by-side comparison
2. Default to "keep both" with merged result
3. Timestamp-based auto-resolution option
4. Manual resolution queue (like CloudKit conflicts)

---

## 8. Implementation Phases

### Phase 1: Foundation (2-3 weeks)
**Goal:** Basic push to device

- [ ] Data model: `CDRemarkableDocument` entity
- [ ] Settings store: `RemarkableSettingsStore`
- [ ] Cloud API client (auth + upload only)
- [ ] Settings UI: connection setup
- [ ] Detail view: "Send to reMarkable" button
- [ ] URL scheme: `imbib://remarkable/push`

**Deliverable:** User can authenticate and push PDFs to device.

### Phase 2: Annotation Import (2-3 weeks)
**Goal:** Pull annotations back

- [ ] .rm file parser (Swift or Rust)
- [ ] Stroke renderer (Core Graphics)
- [ ] `CDRemarkableAnnotation` entity
- [ ] Annotation converter to `CDAnnotation`
- [ ] Detail view: annotation list from reMarkable
- [ ] OCR integration (Vision.framework)

**Deliverable:** Annotations visible in imbib, converted to standard format.

### Phase 3: Bidirectional Sync (2 weeks)
**Goal:** Automatic synchronization

- [ ] `RemarkableSyncScheduler` background actor
- [ ] Conflict detection and resolution UI
- [ ] Reading progress tracking
- [ ] Sync health monitoring
- [ ] Menu commands and keyboard shortcuts

**Deliverable:** Fully automated sync with conflict handling.

### Phase 4: Alternative Backends (1-2 weeks)
**Goal:** Support local folder and Dropbox

- [ ] `RemarkableLocalBackend` implementation
- [ ] `RemarkableDropboxBackend` implementation
- [ ] Backend selection UI
- [ ] USB sync documentation

**Deliverable:** Users can choose their preferred sync method.

### Phase 5: imprint Integration (1 week)
**Goal:** Use reMarkable annotations when citing

- [ ] Export highlighted quotes with references
- [ ] Annotation timeline in manuscript sidebar
- [ ] Quick insert from reMarkable notes

**Deliverable:** Seamless workflow from reading to writing.

---

## 9. Minimal Viable Approach

If full integration is too ambitious, the **minimal useful feature** is:

### Export-Only Integration

1. **Export PDF to folder** that syncs with reMarkable (Dropbox/Google Drive)
2. **Organized folder structure** matching imbib collections
3. **No annotation import** (user manually transfers notes)

**Implementation:**
- 1 week of work
- No API integration needed
- Uses existing `AttachmentManager` + folder export
- Works with any cloud storage reMarkable supports

```swift
// Minimal implementation
func exportToRemarkableFolder(_ publication: CDPublication) throws {
    guard let pdf = publication.linkedFiles?.first(where: { $0.isPDF }),
          let url = AttachmentManager.shared.resolveURL(for: pdf, in: publication.libraries?.first)
    else { throw RemarkableError.noPDF }

    let settings = RemarkableSettingsStore.shared
    let destFolder = settings.exportFolderURL
        .appendingPathComponent(publication.collections?.first?.name ?? "Uncategorized")

    try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
    let destURL = destFolder.appendingPathComponent(url.lastPathComponent)
    try FileManager.default.copyItem(at: url, to: destURL)
}
```

---

## Consequences

### Positive
- Researchers can read and annotate papers on e-ink device
- Annotations flow back automatically
- Reading progress syncs across devices
- Highlighted quotes available for citation in imprint

### Negative
- Dependency on unofficial API (cloud backend)
- Additional complexity in sync system
- Storage overhead for rendered annotation images
- Potential user confusion with multiple annotation sources

### Neutral
- New Core Data entities require migration
- Settings UI expansion
- Additional background process

---

## References

- [rmapi](https://github.com/juruen/rmapi) - Go implementation of reMarkable Cloud API
- [rmapy](https://github.com/subutux/rmapy) - Python wrapper
- [reMarkable Wiki](https://remarkablewiki.com/) - Community documentation
- [.rm file format](https://remarkablewiki.com/tech/filesystem) - Binary format details
- ADR-007: Conflict Resolution - Existing patterns for sync conflicts
- ADR-014: Enrichment Service - Pattern for background data fetching
