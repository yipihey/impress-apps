# ADR-007: Conflict Resolution Strategy

## Status

Accepted

## Date

2026-01-04

## Context

CloudKit sync enables editing on multiple devices. Conflicts occur when:

1. **Same field edited** on Mac and iOS before sync completes
2. **Same paper added** on both devices (cite key collision)
3. **PDF modified** (annotations) on both devices
4. **Relationship changes** (tags, collections) overlap

CloudKit's default behavior is "last writer wins" which can silently lose data. We need explicit strategies for different conflict types.

## Decision

Use a **tiered conflict resolution strategy**:

| Data Type | Strategy | Rationale |
|-----------|----------|-----------|
| Scalar fields (title, year, doi) | Last-writer-wins with history | Low conflict frequency, easily re-editable |
| Multi-value fields (authors, keywords) | Merge with dedup | Additions from both sides preserved |
| Relationships (tags, collections) | Union merge | Non-destructive, matches user intent |
| Cite keys | Detect + prompt user | Critical identifier, needs human decision |
| PDFs | Version both, prompt user | Can't auto-merge annotations |
| BibTeX (rawBibTeX) | Regenerate from merged fields | Derivative data |

## Rationale

### Why Not Pure Last-Writer-Wins?

Silent data loss erodes trust. A user who adds an author on their Mac while adding a keyword on iOS expects both changes to persist.

### Why Not Full CRDT?

CRDTs (Conflict-free Replicated Data Types) are powerful but:
- Complex to implement correctly
- Overkill for most reference manager edits
- CloudKit doesn't natively support them

Our hybrid approach handles 95% of cases automatically while surfacing the 5% that need human judgment.

### Field-Level Timestamps

Track modification time per field, not just per record:

```swift
extension Publication {
    @NSManaged public var fieldTimestamps: String?  // JSON: {"title": "2026-01-04T12:00:00Z", ...}
}
```

This enables field-level last-writer-wins without losing unrelated changes.

## Implementation

### Scalar Field Merge

```swift
struct FieldMerger {
    /// Merge scalar fields using field-level timestamps
    static func merge(
        local: Publication,
        remote: Publication,
        ancestor: Publication?
    ) -> Publication {
        let localTimestamps = local.decodedFieldTimestamps
        let remoteTimestamps = remote.decodedFieldTimestamps

        var merged = local

        for field in Publication.scalarFields {
            let localTime = localTimestamps[field] ?? .distantPast
            let remoteTime = remoteTimestamps[field] ?? .distantPast

            if remoteTime > localTime {
                merged.setValue(remote.value(forKey: field), forKey: field)
                merged.updateFieldTimestamp(field, to: remoteTime)
            }
        }

        return merged
    }
}
```

### Multi-Value Field Merge (Authors, Keywords)

```swift
extension FieldMerger {
    /// Merge arrays by union with deduplication
    static func mergeAuthors(
        local: [Author],
        remote: [Author],
        ancestor: [Author]?
    ) -> [Author] {
        // If we have an ancestor, use 3-way merge
        if let ancestor = ancestor {
            let localAdded = Set(local).subtracting(ancestor)
            let remoteAdded = Set(remote).subtracting(ancestor)
            let localRemoved = Set(ancestor).subtracting(local)
            let remoteRemoved = Set(ancestor).subtracting(remote)

            var result = Set(ancestor)
            result.formUnion(localAdded)
            result.formUnion(remoteAdded)
            result.subtract(localRemoved)
            result.subtract(remoteRemoved)

            return Array(result).sorted { $0.order < $1.order }
        }

        // Without ancestor, union merge
        return Array(Set(local).union(remote)).sorted { $0.order < $1.order }
    }
}
```

### Relationship Merge (Tags, Collections)

```swift
extension FieldMerger {
    /// Tags and collections use union merge (non-destructive)
    static func mergeTags(
        local: Set<Tag>,
        remote: Set<Tag>
    ) -> Set<Tag> {
        // Simple union - if either device has the tag, keep it
        // Explicit removal requires a "removed tags" tombstone set
        local.union(remote)
    }
}
```

### Cite Key Conflict Detection

```swift
actor ConflictDetector {
    /// Check for cite key collision during sync
    func detectCiteKeyConflict(
        incoming: Publication,
        existing: [Publication]
    ) -> CiteKeyConflict? {
        guard let collision = existing.first(where: {
            $0.citeKey == incoming.citeKey && $0.id != incoming.id
        }) else {
            return nil
        }

        return CiteKeyConflict(
            incomingPublication: incoming,
            existingPublication: collision,
            suggestedResolutions: [
                .rename(incoming, to: generateUniqueCiteKey(incoming)),
                .rename(collision, to: generateUniqueCiteKey(collision)),
                .merge(into: collision)
            ]
        )
    }
}
```

### Cite Key Conflict UI

```swift
struct CiteKeyConflictAlert: View {
    let conflict: CiteKeyConflict
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Cite Key Conflict")
                .font(.headline)

            Text("Two publications have the same cite key: \(conflict.incomingPublication.citeKey)")

            GroupBox("Incoming") {
                PublicationSummary(conflict.incomingPublication)
            }

            GroupBox("Existing") {
                PublicationSummary(conflict.existingPublication)
            }

            ForEach(conflict.suggestedResolutions) { resolution in
                Button(resolution.description) {
                    Task {
                        await resolution.apply()
                        dismiss()
                    }
                }
            }
        }
        .padding()
    }
}
```

### PDF Conflict Handling

```swift
enum PDFConflictResolution {
    case keepLocal
    case keepRemote
    case keepBoth  // Rename remote to _conflict_<date>.pdf
}

actor PDFConflictResolver {
    func resolve(
        local: LinkedFile,
        remote: LinkedFile,
        resolution: PDFConflictResolution
    ) async throws {
        switch resolution {
        case .keepLocal:
            // Discard remote, keep local annotations
            break

        case .keepRemote:
            // Replace local with remote
            let localURL = PathResolver.resolve(local.relativePath)
            let remoteURL = try await downloadRemotePDF(remote)
            try FileManager.default.removeItem(at: localURL)
            try FileManager.default.moveItem(at: remoteURL, to: localURL)

        case .keepBoth:
            // Keep both versions
            let conflictName = generateConflictFilename(remote)
            let remoteURL = try await downloadRemotePDF(remote)
            let conflictURL = PathResolver.resolve(conflictName)
            try FileManager.default.moveItem(at: remoteURL, to: conflictURL)

            // Create new LinkedFile for conflict version
            let conflictFile = LinkedFile(context: viewContext)
            conflictFile.uuid = UUID()
            conflictFile.relativePath = conflictName
            conflictFile.publication = local.publication
        }
    }

    private func generateConflictFilename(_ file: LinkedFile) -> String {
        let base = file.relativePath.dropLast(4)  // Remove .pdf
        let date = ISO8601DateFormatter().string(from: Date())
        return "\(base)_conflict_\(date).pdf"
    }
}
```

### Sync Conflict Queue

```swift
@Observable
final class SyncConflictQueue {
    private(set) var pendingConflicts: [SyncConflict] = []

    enum SyncConflict: Identifiable {
        case citeKey(CiteKeyConflict)
        case pdf(PDFConflict)

        var id: String {
            switch self {
            case .citeKey(let c): return "citekey-\(c.id)"
            case .pdf(let c): return "pdf-\(c.id)"
            }
        }
    }

    func enqueue(_ conflict: SyncConflict) {
        pendingConflicts.append(conflict)
    }

    func resolve(_ conflict: SyncConflict) {
        pendingConflicts.removeAll { $0.id == conflict.id }
    }
}
```

## CloudKit Integration

### Custom Merge Policy

```swift
extension PersistenceController {
    func configureCloudKitMerging() {
        // Use custom merge policy instead of default
        viewContext.mergePolicy = PublicationMergePolicy()
    }
}

final class PublicationMergePolicy: NSMergePolicy {
    override func resolve(constraintConflicts list: [NSConstraintConflict]) throws {
        for conflict in list {
            guard let publication = conflict.databaseObject as? Publication else {
                continue
            }

            // Apply our field-level merge logic
            if let conflicting = conflict.conflictingObjects.first as? Publication {
                let merged = FieldMerger.merge(
                    local: publication,
                    remote: conflicting,
                    ancestor: nil
                )
                // Apply merged values...
            }
        }

        try super.resolve(constraintConflicts: list)
    }
}
```

## Consequences

### Positive

- Most conflicts resolve automatically without data loss
- Critical conflicts (cite keys, PDFs) get user attention
- Field-level timestamps prevent unnecessary overwrites
- Union merge for relationships matches user expectations

### Negative

- Additional complexity in sync layer
- Field timestamps increase storage slightly
- Some conflicts require user interaction (can't be fully automatic)

### Mitigations

- Conflict UI is non-blocking (queued for later resolution)
- Clear UX explains what happened and why
- Sensible defaults if user ignores conflicts

## Alternatives Considered

### Pure Last-Writer-Wins

Simple but loses data silently. Rejected.

### Full CRDT Implementation

Theoretically optimal but:
- Complex to implement and test
- CloudKit doesn't support CRDT sync natively
- Overkill for reference manager use case

### Server-Side Merge

Would require our own backend. Against offline-first design goals.

### Git-Style Manual Merge

Too technical for non-developer users. Academics want to manage papers, not resolve merge conflicts.
