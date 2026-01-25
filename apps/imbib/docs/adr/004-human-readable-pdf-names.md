# ADR-004: Human-Readable PDF Filenames

## Status

Accepted

## Date

2026-01-04

## Context

PDFs need to be stored and synced across devices. Options for naming/storing:

1. **Content-Addressed Storage (CAS)**: Name files by content hash (e.g., `a3f2b7c9d8e1.pdf`)
2. **UUID-Based**: Name files by random UUID (e.g., `550e8400-e29b-41d4-a716-446655440000.pdf`)
3. **Human-Readable**: Name files by metadata (e.g., `Einstein_1905_Electrodynamics.pdf`)

## Decision

Use **human-readable filenames** matching BibDesk's auto-file conventions:

```
{FirstAuthorLastName}_{Year}_{TruncatedTitle}.pdf
```

Example: `Einstein_1905_OnTheElectrodynamics.pdf`

Store a stable UUID reference in Core Data for internal linking.

## Rationale

### Against Content-Addressed Storage

CAS (hash-based naming) has theoretical appeal but fails for reference management:

| Issue | Impact |
|-------|--------|
| **PDF annotation** | Highlighting, notes, markup change the hash. Your annotated copy becomes a "different" file, breaking the reference. |
| **BibDesk compatibility** | BibDesk expects human-readable paths in `Bdsk-File-*` fields. CAS breaks round-trip. |
| **Findability** | Users browse PDFs in Finder/Files. `a3f2b7c9d8e1.pdf` is unusable. |
| **Dedup benefit** | Academic libraries rarely have byte-identical duplicates. Even the same paper from different sources often differs. |

### For Human-Readable Names

| Benefit | Explanation |
|---------|-------------|
| **User browsing** | Papers are findable in Finder/Spotlight without opening the app |
| **BibDesk compatible** | Matches BibDesk's auto-file pattern exactly |
| **Annotation-safe** | Modifying the PDF doesn't orphan the database reference |
| **Debugging** | Obviously what each file is |
| **Portability** | Copy the folder anywhere and it's still useful |

### UUID for Internal Reference

Store a stable UUID in Core Data that survives renames:

```swift
@Model
class LinkedFile {
    var uuid: UUID                    // Stable internal reference
    var relativePath: String          // "Papers/Einstein_1905_Electrodynamics.pdf"
    var sha256: String?               // Optional integrity check
}
```

If the user renames the file externally, we can:
1. Detect the change via file coordination
2. Update `relativePath` in the database
3. `uuid` remains stable for CloudKit sync

## Implementation

### Filename Generation

```swift
func generateFilename(for publication: Publication) -> String {
    let author = publication.firstAuthorLastName ?? "Unknown"
    let year = publication.year.map(String.init) ?? "NoYear"
    let title = truncateTitle(publication.title ?? "Untitled", maxLength: 40)
    
    let base = "\(author)_\(year)_\(title)"
    let sanitized = sanitizeFilename(base)
    
    return sanitized + ".pdf"
}

func sanitizeFilename(_ name: String) -> String {
    // Remove invalid characters: / \ : * ? " < > |
    // Replace spaces with nothing (camelCase) or underscores
    // Normalize unicode
}

func truncateTitle(_ title: String, maxLength: Int) -> String {
    // Remove leading articles: "The ", "A ", "An "
    // Truncate to maxLength
    // Don't break mid-word
}
```

### Collision Handling

```swift
func resolveFilename(_ base: String, in directory: URL) -> String {
    var filename = base
    var counter = 1
    
    while FileManager.default.fileExists(atPath: directory.appending(path: filename).path) {
        // Einstein_1905_Electrodynamics.pdf
        // Einstein_1905_Electrodynamics_2.pdf
        // Einstein_1905_Electrodynamics_3.pdf
        let name = base.dropLast(4)  // Remove .pdf
        filename = "\(name)_\(counter).pdf"
        counter += 1
    }
    
    return filename
}
```

### Integrity Checking

Compute SHA-256 on import for optional corruption detection:

```swift
func importPDF(from sourceURL: URL, for publication: Publication) throws -> LinkedFile {
    let filename = generateFilename(for: publication)
    let targetURL = papersDirectory.appending(path: filename)
    
    try FileManager.default.copyItem(at: sourceURL, to: targetURL)
    
    let file = LinkedFile(context: viewContext)
    file.uuid = UUID()
    file.relativePath = "Papers/\(filename)"
    file.sha256 = computeSHA256(targetURL)  // For integrity, not naming
    file.publication = publication
    
    return file
}
```

## Consequences

### Positive

- Users can find and organize PDFs naturally
- Full BibDesk round-trip compatibility
- Annotations don't break references
- Works with Spotlight search
- Portable library folders

### Negative

- Filename collisions possible (handled with suffix)
- Renames require database update
- Non-ASCII characters need sanitization

### Mitigations

- File coordination for external change detection
- Robust filename sanitization
- Fallback to UUID if metadata unavailable
