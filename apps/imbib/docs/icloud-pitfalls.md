# iCloud Sync Pitfalls & Best Practices

This document covers common pitfalls when working with iCloud sync (CloudKit and Core Data) in imbib, along with best practices to avoid data loss.

## Architecture Overview

imbib uses two iCloud sync mechanisms:

1. **NSPersistentCloudKitContainer** - Core Data + CloudKit automatic sync
2. **NSUbiquitousKeyValueStore** - Settings sync across devices

## Known Limitations

### CloudKit Record Limits

| Limit | Value | Impact |
|-------|-------|--------|
| Record size | 1 MB | Large BibTeX entries may fail |
| Asset size | 250 MB | PDF files must be under this limit |
| Records per operation | 400 | Batch imports must be chunked |
| Requests per second | 40 | Rapid edits may be throttled |

### Zone Sharing

- CloudKit zones are all-or-nothing for sharing
- If sharing is implemented, all records in a zone are shared together
- Private vs shared zones have different sync behaviors

### Clock Skew

- Devices with incorrect system time can corrupt timestamps
- Field-level conflict resolution depends on accurate timestamps
- Always use `Date()` from the device, never computed future dates

## Dangerous Operations

### Never Do These in Production

```swift
// DANGEROUS: Removing attributes from Core Data model
// Old data will be orphaned and may cause crashes
- entity.attribute("oldField") // DON'T DELETE

// DANGEROUS: Changing attribute types
// Int -> String conversion will fail silently
- entity.attribute("count", type: .integer)
+ entity.attribute("count", type: .string) // DON'T DO THIS

// DANGEROUS: Removing relationships
// Orphans related records, breaks sync
- publication.library // DON'T REMOVE

// DANGEROUS: Force pushing to CloudKit
// Can overwrite other devices' data
container.purgeObjectsAndRecordsInZone(...) // USE WITH EXTREME CAUTION
```

### Schema Migration Rules

1. **Additive only**: Only add new optional attributes
2. **Never delete**: Mark as deprecated, don't remove
3. **Never rename**: Add new attribute, migrate data, deprecate old
4. **Test with real data**: Mock CloudKit doesn't catch all issues

## Safe Practices

### Adding New Fields

```swift
// SAFE: New optional attribute
extension CDPublication {
    @NSManaged public var newOptionalField: String?
}

// SAFE: Lightweight migration handles this automatically
// No need for custom NSMigrationPolicy
```

### Handling Conflicts

```swift
// SAFE: Let our FieldMerger handle conflicts
let merger = FieldMerger.shared
let resolved = await merger.merge(local: localPub, remote: remotePub, context: context)

// SAFE: Field-level timestamps ensure correct resolution
// Each field tracks its own modification time
```

### PDF Sync Strategy

```swift
// SAFE: Check PDF size before sync
let fileSize = try FileManager.default.attributesOfItem(atPath: pdfPath)[.size] as? Int64
if (fileSize ?? 0) > 250_000_000 { // 250 MB
    // Skip CloudKit upload, use local only
    publication.pdfSyncEnabled = false
}

// SAFE: Handle download failures gracefully
do {
    try await syncPDF(for: publication)
} catch {
    // Mark as not downloaded, don't crash
    publication.hasPDFDownloaded = false
    publication.pdfDownloadError = error.localizedDescription
}
```

## Testing Sync Changes

### Pre-Release Checklist

1. **Unit Tests**: Run full test suite including `FieldMergerTests`, `ConflictDetectorTests`
2. **Integration Tests**: Test with real CloudKit accounts (not mock)
3. **Multi-Device**: Test sync between iOS and macOS
4. **Migration**: Test upgrade path from previous App Store version
5. **Offline/Online**: Test editing while offline, then reconnecting

### Test Scenarios

| Scenario | Test Steps | Expected Result |
|----------|------------|-----------------|
| Concurrent edit | Edit same publication on 2 devices | Field-level merge, no data loss |
| Offline edit | Edit offline, then sync | Local changes sync without conflict |
| Large PDF | Add 100MB PDF | Syncs successfully |
| Rapid edits | 100 edits in 1 minute | All edits sync eventually |
| Schema mismatch | Old app + new data | Graceful error, prompt to update |

### CloudKit Dashboard Monitoring

1. Go to [CloudKit Dashboard](https://icloud.developer.apple.com/dashboard)
2. Select your container
3. Monitor:
   - Error rates by error code
   - Record counts over time
   - Zone sync status

## Recovery Procedures

### If Sync Appears Stuck

1. Check Settings > Sync Health for reported issues
2. Try "Force Sync" button
3. Check iCloud storage isn't full
4. Wait 15 minutes for CloudKit's eventual consistency
5. If still stuck, export library and contact support

### If Data Appears Missing

1. Check other devices (may not have synced yet)
2. Check iCloud storage (Settings > Apple ID > iCloud)
3. Check for conflicts in Sync Health
4. Restore from automatic backup if needed

### Emergency Data Export

Always ensure users can export their data:

```swift
// In LibraryBackupService
let backup = try await LibraryBackupService().exportFullBackup()
// backup contains: library.bib, PDFs/, notes.json, settings.json, manifest.json
```

## Schema Version Management

### Version Registry

```swift
enum SchemaVersion: Int {
    case v1_0 = 100  // Initial release
    case v1_1 = 110  // Added manuscript support
    case v1_2 = 120  // Added annotation fields

    static let current: SchemaVersion = .v1_2
    static let minimumCompatible: SchemaVersion = .v1_0
}
```

### Compatibility Checks

```swift
let checker = SchemaVersionChecker()
let result = checker.check(remoteVersionRaw: remoteVersion)

switch result {
case .current:
    // Safe to sync
case .needsMigration(let from):
    // Run migration before sync
case .newerThanApp(let version):
    // Prompt user to update app
case .incompatible:
    // Show error, offer data export
}
```

## Feature Flags for Safe Rollout

```swift
struct SyncFeatureFlags: Codable {
    var enableNewConflictResolution: Bool = false
    var enableLargePDFSync: Bool = false
    var syncSchemaVersion: Int = 100
}

// Gradually enable features
if featureFlags.enableNewConflictResolution {
    // Use new conflict resolution
} else {
    // Use legacy behavior
}
```

## Related Documentation

- [ADR-007: CloudKit Conflict Resolution](adr/ADR-007-cloudkit-conflict-resolution.md)
- [Data Recovery Guide](data-recovery-guide.md)
- [Schema Migration Tests](../PublicationManagerCore/Tests/PublicationManagerCoreTests/Migration/)

## Changelog

- **2026-01-28**: Initial documentation created
- Covers: CloudKit limits, dangerous operations, safe practices, testing, recovery
