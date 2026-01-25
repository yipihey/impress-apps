# ADR-001: Core Data over SwiftData

## Status

Accepted

## Date

2026-01-04

## Context

We need a persistence layer for the publication database that:
- Supports CloudKit sync for cross-device access
- Handles complex relationships (publications ↔ authors, tags, collections)
- Works on both macOS and iOS
- Can be effectively developed using Claude Code

The primary options are:
1. **SwiftData** - Apple's new Swift-native persistence (iOS 17+/macOS 14+)
2. **Core Data** - Apple's mature ORM framework
3. **SQLite** (via GRDB or SQLite.swift) - Direct SQL database
4. **Realm** - Third-party object database

## Decision

We will use **Core Data with CloudKit** (`NSPersistentCloudKitContainer`).

## Rationale

### Claude Code Proficiency

SwiftData was released in 2023 and has limited representation in training data. Core Data has been available since 2009 with extensive documentation, tutorials, Stack Overflow answers, and open-source examples. Claude Code generates more reliable Core Data code.

### CloudKit Integration

`NSPersistentCloudKitContainer` provides automatic CloudKit sync with:
- Transparent conflict resolution
- Lazy asset downloading (PDFs)
- No server-side code required

SwiftData's CloudKit support is still maturing and has documented issues.

### Stability

Core Data is battle-tested in thousands of production apps. SwiftData has had several bugs in its initial releases that affected data integrity.

### Migration Path

We can migrate to SwiftData in the future if it stabilizes. Core Data models can be incrementally converted.

## Consequences

### Positive

- Reliable CloudKit sync out of the box
- Extensive documentation and examples
- Claude Code generates correct code consistently
- Mature migration tooling

### Negative

- More verbose than SwiftData (manual `NSManagedObject` subclasses)
- Requires understanding of managed object contexts
- `.xcdatamodeld` files less readable than SwiftData's Swift declarations

### Mitigations

- Use code generation for `NSManagedObject` subclasses
- Wrap Core Data in repository pattern to simplify ViewModels
- Create helper extensions for common patterns

## Alternatives Considered

### SwiftData

Rejected due to limited Claude Code training data and immature CloudKit support. Will reconsider for v2.0.

### SQLite (GRDB)

Excellent for local-only apps but would require implementing sync ourselves. CloudKit asset sync for PDFs would be particularly complex.

### Realm (Atlas Device Sync)

Good DX but introduces vendor lock-in and requires MongoDB Atlas subscription for sync. Not ideal for an app targeting academics who value data portability.
