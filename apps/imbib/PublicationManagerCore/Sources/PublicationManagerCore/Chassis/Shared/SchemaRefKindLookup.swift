// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). Pure Foundation
// lookup over the (now cross-platform) descriptor registry.
//
//  SchemaRefKindLookup.swift
//  PublicationManagerCore
//
//  WP G5 (ADR-0022 D8): store schema ref → `RecordKindID` → an SF Symbol,
//  for surfaces that receive rows they did not query and must label by kind.
//
//  Deliberately NOT in `RecordKindDescriptor.swift`: descriptors declare the
//  schema refs, but the store hands out VERSIONED refs (`figure@1.0.0`,
//  `manuscript@1.2.0`) while several descriptors declare the bare form
//  (`figure`, `manuscript`) and others the versioned one (`task@1.0.0`).
//  `RecordKindRegistry.descriptor(forSchemaRef:)` is exact-match by design —
//  it backs parity tests against the Rust schema registry and must stay
//  strict. This is the tolerant lookup display code wants, kept in one
//  neutral place so the Related section (D8) and grouped global search (D6)
//  share one answer instead of each growing its own `hasPrefix` check.
//
//  Version tolerance is base-name equality on BOTH sides, never `hasPrefix`:
//  `figure-collection` must not resolve to the `figure` kind.
//

import Foundation

extension RecordKindRegistry {

    /// The kind owning a store schema ref, ignoring the `@version` suffix on
    /// either side. `nil` for a schema no shipped descriptor claims (a
    /// collection row, an operation row, a kind this build doesn't know).
    public func kind(forStoreSchemaRef schemaRef: String) -> RecordKindID? {
        if let exact = descriptor(forSchemaRef: schemaRef) { return exact.id }
        let base = RecordKindSchemaRef.baseName(schemaRef)
        guard !base.isEmpty else { return nil }
        return descriptors.first { descriptor in
            descriptor.schemaRefs.contains { RecordKindSchemaRef.baseName($0) == base }
        }?.id
    }
}

public enum RecordKindSchemaRef {
    /// `"figure@1.0.0"` → `"figure"`; an unversioned ref is returned as-is.
    public static func baseName(_ schemaRef: String) -> String {
        String(schemaRef.prefix { $0 != "@" })
    }
}

/// SF Symbols for record kinds, for mixed-kind rows that have no per-kind
/// row struct to ask. Matches the symbols the per-kind surfaces already use
/// (`MessageListWrapper`'s envelope, `AgentRecordDetailPane`'s checklist/bolt,
/// `FigureDetailPane`'s photo) so one record looks the same everywhere.
public enum RecordKindIconography {

    public static func symbolName(for kind: RecordKindID?) -> String {
        guard let kind else { return unknownSymbolName }
        switch kind {
        case .publication: return "doc.text"
        case .manuscript: return "doc.richtext"
        case .figure: return "photo"
        case .message: return "envelope"
        case .task: return "checklist"
        case .agentRun: return "bolt"
        case .artifact: return "archivebox"
        default: return unknownSymbolName
        }
    }

    /// Shown for a schema no descriptor claims — honest about not knowing,
    /// rather than mislabelling the row as some other kind.
    public static let unknownSymbolName = "questionmark.square.dashed"

    public static func symbolName(forStoreSchemaRef schemaRef: String) -> String {
        symbolName(for: BuiltinRecordKinds.registry.kind(forStoreSchemaRef: schemaRef))
    }
}
