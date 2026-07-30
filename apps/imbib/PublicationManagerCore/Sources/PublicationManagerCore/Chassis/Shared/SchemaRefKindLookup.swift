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
//  schema refs, and the suite does not spell them uniformly — most kinds are
//  bare (`figure`, `manuscript`, `manuscript-section`), the impel kernel's are
//  versioned (`task@1.0.0`, `agent-run@1.0.0`), and imbib's are namespaced
//  (`imbib/bibliography-entry`). The canonical spelling per kind is fixed in
//  `schema-refs.json` at the repo root and enforced by
//  `scripts/check-schema-refs.sh`.
//
//  CORRECTION (2026-07-29): this comment used to claim "the store hands out
//  VERSIONED refs (`figure@1.0.0`, `manuscript@1.2.0`)". It does not, and it
//  never did — `schema_ref` is stored verbatim as written, and nothing writes
//  `figure@1.0.0`. That false belief is the direct cause of at least two live
//  bugs (`manuscript-section@1.0.0` and `citation-usage@1.0.0` readers that
//  matched zero rows forever, since the store compares `schema_ref` by EXACT
//  EQUALITY). Do not reintroduce a version suffix on the strength of it.
//
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
///
/// This used to be a seven-arm `switch` over `RecordKindID` — the ONE
/// remaining per-kind chassis edit the ADR-0021 litmus re-run admitted to
/// ("one-line exception: `RecordKindIconography.symbolName(for:)` needs a
/// `case` for the SF Symbol, or the row shows the honest 'unknown kind' glyph
/// rather than a wrong one"). The symbol is now `descriptor.symbolName`, so
/// adding a kind adds no case here, and a kind cannot be registered with a
/// symbol nobody declared: `RecordKindSymbolTests` requires one per
/// descriptor. This enum stays as the RESOLVER (ID or schema ref → symbol),
/// because callers on mixed-kind surfaces hold a ref or an id, not a
/// descriptor.
public enum RecordKindIconography {

    public static func symbolName(for kind: RecordKindID?) -> String {
        guard let kind, let descriptor = BuiltinRecordKinds.registry[kind] else {
            return unknownSymbolName
        }
        return descriptor.symbolName
    }

    /// Shown for a schema no descriptor claims — honest about not knowing,
    /// rather than mislabelling the row as some other kind.
    public static let unknownSymbolName = RecordKindDescriptor.unknownSymbolName

    public static func symbolName(forStoreSchemaRef schemaRef: String) -> String {
        symbolName(for: BuiltinRecordKinds.registry.kind(forStoreSchemaRef: schemaRef))
    }
}
