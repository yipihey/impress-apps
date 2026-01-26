# ADR-006: CloudKit + iCloud Drive Sync Strategy

## Status
Accepted

## Context
imprint needs to sync documents across devices and between collaborators. Options include:

1. **Custom server**: Full control but requires infrastructure
2. **Firebase/Supabase**: Third-party dependency, not Apple-native
3. **iCloud Drive**: File-based sync, simple but no real-time collaboration
4. **CloudKit**: Apple's database service, supports shared zones

Key requirements:
- Zero infrastructure for personal use (single author)
- Real-time collaboration for teams
- Offline capability with automatic merge
- Privacy: data stays in user's iCloud

## Decision
imprint uses a **two-tier sync strategy**:

| Tier | Use Case | Technology | Sync Model |
|------|----------|------------|------------|
| **Personal** | Single author, multi-device | iCloud Drive | File-based |
| **Collaborative** | Multiple authors | CloudKit Shared Zones | Record-based |

### Personal Sync (iCloud Drive)

For single-author documents:
1. Document saved as `.imprint` bundle in iCloud Drive
2. Bundle contains Automerge binary + assets
3. iCloud handles file sync automatically
4. Conflict resolution via Automerge merge on open

```
~/Documents/imprint/
├── paper-draft.imprint/
│   ├── document.automerge  # CRDT binary
│   ├── assets/
│   │   ├── figure1.png
│   │   └── data.csv
│   └── metadata.json
```

### Collaborative Sync (CloudKit)

For multi-author documents:
1. Document registered in CloudKit shared zone
2. Changes pushed as CloudKit records (chunked Automerge ops)
3. Other participants receive push notifications
4. Pull changes and merge locally

```swift
// Simplified CloudKit sync flow
func syncDocument(_ doc: ImprintDocument) async throws {
    // Push local changes
    let changes = doc.generateSyncMessage(since: lastSyncToken)
    let record = CKRecord(recordType: "DocumentChange")
    record["changes"] = changes.data
    try await database.save(record)

    // Pull remote changes
    let query = CKQuery(recordType: "DocumentChange", predicate: sincePredicate)
    let results = try await database.records(matching: query)
    for record in results {
        let message = SyncMessage(data: record["changes"])
        doc.receiveSyncMessage(message)
    }
}
```

### Invitation Flow (Tier 3: Secure Links)

For reviewers without Apple ID:
1. Owner generates secure link with optional password
2. Link contains encrypted document snapshot
3. Reviewer views read-only in browser (WASM)
4. Comments sync back via CloudKit

## Consequences

### Positive
- Zero infrastructure for personal use
- Apple-native: tight OS integration
- Privacy: data in user's iCloud, not third-party servers
- Offline: Automerge enables full offline editing

### Negative
- Apple ecosystem: requires iCloud account for full features
- CloudKit limits: record size limits require chunking
- Web collaboration: requires separate WASM-based viewer
- Debugging: CloudKit harder to debug than custom server

## Implementation
- `imprint-sync` crate provides `SyncManager` trait implementation
- Personal sync via `NSFileCoordinator` for iCloud Drive
- Collaborative sync via CloudKit SDK (Swift side)
- Rust core agnostic to transport—just processes sync messages
