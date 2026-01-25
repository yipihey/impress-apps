# ADR-006: iOS File Handling Strategy

## Status

Accepted

## Date

2026-01-04

## Context

iOS has fundamentally different file access constraints than macOS:

- **Sandboxing**: Apps can only access files in their container by default
- **Security-scoped bookmarks**: Required for persistent access to user-selected files
- **No arbitrary filesystem access**: Can't browse `~/Documents` like macOS
- **Files.app integration**: Users expect to see documents in the Files app
- **iCloud Drive**: Different from CloudKit—user-visible folder sync

The macOS model assumes a library folder (e.g., `~/Documents/Papers/`) containing `.bib` files and PDFs. This doesn't translate directly to iOS.

## Decision

Use a **hybrid approach** with different primary workflows per platform:

### macOS: User-Managed Library Folder

- User selects library folder (with security-scoped bookmark)
- `.bib` file and PDFs live in this folder
- Full BibDesk compatibility
- Folder can be in iCloud Drive, Dropbox, etc.

### iOS: App Container with Export

- Primary storage in app's Documents container
- Automatic CloudKit sync for cross-device access
- Export `.bib` to Files.app on demand
- Import PDFs from Files.app or share sheet
- Optional: Open `.bib` from Files.app (read/import only)

### Shared: CloudKit as Cross-Platform Bridge

- Core Data entities sync via CloudKit
- PDFs sync as CKAssets
- iOS users don't need to manage `.bib` files directly
- macOS users get both: local `.bib` AND CloudKit sync

## Rationale

### Why Not the Same Model?

Attempting to replicate macOS file management on iOS creates friction:

| macOS Pattern | iOS Reality |
|---------------|-------------|
| Browse to folder | Must use document picker each time |
| Edit `.bib` externally | Files.app doesn't have BibTeX editors |
| Relative PDF paths | Security-scoped bookmarks are fragile |
| Folder monitoring | Limited background execution |

### iOS Users Have Different Expectations

- Mobile use cases: reading PDFs, quick searches, adding papers on-the-go
- Heavy bibliography editing happens on Mac
- CloudKit sync means iOS doesn't need local `.bib` mastery

### Export Covers Edge Cases

iOS users who need `.bib` files (e.g., for Overleaf) can:
1. Export selected entries or full library
2. Save to Files.app / iCloud Drive
3. Share to other apps

## Implementation

### iOS Document Container Structure

```
App Container/
└── Documents/
    └── PDFs/
        ├── Einstein_1905_Electrodynamics.pdf
        ├── Feynman_1948_SpaceTimeApproach.pdf
        └── ...
```

No `.bib` file stored locally on iOS—Core Data + CloudKit is the source of truth.

### Security-Scoped Bookmarks (macOS)

```swift
#if os(macOS)
actor LibraryLocationManager {
    private let bookmarkKey = "libraryFolderBookmark"

    func setLibraryFolder(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    func resolveLibraryFolder() throws -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard url.startAccessingSecurityScopedResource() else {
            throw FileError.permissionDenied
        }

        if isStale {
            // Re-save bookmark
            try setLibraryFolder(url)
        }

        return url
    }
}
#endif
```

### iOS PDF Import

```swift
#if os(iOS)
struct PDFImporter {
    func importPDF(from url: URL, for publication: Publication) async throws -> LinkedFile {
        // Start accessing security-scoped resource (from document picker)
        guard url.startAccessingSecurityScopedResource() else {
            throw FileError.permissionDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        // Copy to app container
        let filename = PDFManager.generateFilename(for: publication)
        let destination = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFs")
            .appendingPathComponent(filename)

        try FileManager.default.copyItem(at: url, to: destination)

        // Create LinkedFile entity
        let file = LinkedFile(context: viewContext)
        file.uuid = UUID()
        file.relativePath = "PDFs/\(filename)"
        file.publication = publication

        return file
    }
}
#endif
```

### iOS BibTeX Export

```swift
#if os(iOS)
struct BibTeXExportView: View {
    let publications: [Publication]
    @State private var exportURL: URL?
    @State private var showShareSheet = false

    var body: some View {
        Button("Export BibTeX") {
            exportURL = generateExport()
            showShareSheet = true
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
    }

    private func generateExport() -> URL {
        let bibtex = BibTeXExporter.export(publications)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("library.bib")
        try? bibtex.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }
}
#endif
```

### Platform-Specific Path Resolution

```swift
public struct PathResolver {

    #if os(macOS)
    /// macOS: Paths are relative to user-selected library folder
    public static func resolve(_ relativePath: String, in library: URL) -> URL {
        library.appendingPathComponent(relativePath)
    }
    #endif

    #if os(iOS)
    /// iOS: Paths are relative to app's Documents directory
    public static func resolve(_ relativePath: String) -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(relativePath)
    }
    #endif
}
```

## Consequences

### Positive

- iOS UX feels native (no file management gymnastics)
- macOS users keep full BibDesk compatibility
- CloudKit bridges the platforms seamlessly
- Export handles edge cases for iOS power users

### Negative

- Two different file handling codepaths to maintain
- iOS users can't directly edit `.bib` files
- PDFs stored twice (app container + CloudKit) on iOS

### Mitigations

- Abstract file operations behind `PDFManager` protocol
- CloudKit lazy download prevents double storage cost
- Clear UI messaging about export workflow on iOS

## Alternatives Considered

### Same Model on Both Platforms

Would require iOS users to repeatedly use document picker. Poor UX.

### iOS-Only CloudKit (No macOS File Support)

Would break BibDesk compatibility and alienate target users.

### Files.app as Primary iOS Storage

Technically possible with File Provider extension, but:
- Complex to implement
- Users might accidentally delete/move files
- Security-scoped bookmarks expire

### iCloud Drive Folder Sync

Different from CloudKit. Would require monitoring a folder, which has background execution limits on iOS. Also conflicts with CloudKit approach.
