// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). See the de-gating
// note in RecordKindDescriptor.swift: these descriptors are the single
// declaration of each kind's status lifecycle, so iOS code (imprint's
// ManuscriptStoreAdapter) reads "dismissed"/"draft"/"archived" from
// `ManuscriptRecordKind.descriptor.triage` instead of re-typing them.
//
//  BuiltinRecordKinds.swift
//  PublicationManagerCore
//
//  The three shipped record kinds, transcribed EXACTLY from the frozen
//  contract table in docs/chassis-capability-matrix.md ("Record-kind
//  descriptor contract"). RecordKindDescriptorTests asserts these reproduce
//  the legacy DetailTab.ItemKind behavior before the enum is deleted.
//

public enum PublicationRecordKind {
    public static let descriptor = RecordKindDescriptor(
        id: .publication,
        schemaRefs: ["imbib/bibliography-entry"],
        displayName: "Publication",
        symbolName: "doc.text",
        detailTabs: [
            DetailTabSpec(.info),
            DetailTabSpec(.pdf),
            DetailTabSpec(.notes, isAvailable: { $0.isEditable ?? false }),
            DetailTabSpec(.bibtex),
        ],
        fallbackTab: { tab, _ in
            // Legacy coerced(for:): a manuscript's text tab lands on bibtex.
            tab == .source ? .bibtex : .info
        },
        triage: TriageCapabilities(
            dismissal: .libraryMove,
            archiveStatus: nil,
            deletion: .softToDismissed,
            statuses: []
        ),
        creation: [],   // publications arrive by import/search, not `n`
        defaultOpenBehavior: .detailPane
    )
}

public enum ManuscriptRecordKind {
    public static let descriptor = RecordKindDescriptor(
        id: .manuscript,
        schemaRefs: ["manuscript"],
        displayName: "Manuscript",
        symbolName: "doc.richtext",
        detailTabs: [
            DetailTabSpec(.info),
            DetailTabSpec(.source),
            // The Preview tab (DetailTab.pdf relabeled) — hidden for plain
            // text, which has no rendered state.
            DetailTabSpec(.pdf, isAvailable: { ($0.previewKind ?? .compiledPDF) != .none }),
        ],
        fallbackTab: { tab, _ in
            // Legacy coerced(for:): a publication's text tab lands on source.
            tab == .bibtex ? .source : .info
        },
        triage: TriageCapabilities(
            dismissal: .statusChange(dismissed: "dismissed", restoreTo: "draft"),
            archiveStatus: "archived",
            deletion: .confirmHard,
            // The lifecycle AND its presentation, transcribed exactly from the
            // chassis's former private table (`RecordStatusPresentation.known`)
            // and macOS's former sidebar literals — the labels are
            // navigational ("Drafts", "Archive"), which is why they are not
            // `JournalManuscriptStatus.displayName`'s singular badge spellings.
            statuses: [
                StatusSpec("draft", label: "Drafts", systemImage: "pencil"),
                StatusSpec(
                    "internal-review", label: "Internal Review",
                    systemImage: "person.2"),
                StatusSpec("submitted", label: "Submitted", systemImage: "paperplane"),
                StatusSpec(
                    "in-revision", label: "In Revision",
                    systemImage: "arrow.triangle.2.circlepath"),
                StatusSpec(
                    "published", label: "Published",
                    systemImage: "checkmark.seal", isTerminal: true),
                StatusSpec(
                    "archived", label: "Archive",
                    systemImage: "archivebox", isTerminal: true),
                // Owns the Dismissed SECTION, so it is not also a smart child
                // of the primary section.
                StatusSpec(
                    "dismissed", label: "Dismissed", systemImage: "xmark.circle",
                    isTerminal: true, hiddenByDefault: true),
            ]
        ),
        creation: DocumentFormat.allCases.map {
            CreationAffordance(label: $0.displayName, formatValue: $0.rawValue)
        },
        defaultOpenBehavior: .appHandoff,
        // ADR-0022 D3: manuscript folders are `manuscript-collection` items —
        // payload `parent_collection_ref` tree, Contains membership. The
        // literal is `UTType.manuscriptID.identifier` (MailStylePublicationRow);
        // spelled out because this folder must not depend on view types.
        collection: CollectionCapability(
            bindingID: CollectionBindingID.manuscript,
            canOrganize: true,
            dragUTTypeIdentifier: "com.imbib.manuscript-id"
        )
    )
}

public enum FigureRecordKind {
    public static let descriptor = RecordKindDescriptor(
        id: .figure,
        schemaRefs: ["figure"],
        displayName: "Figure",
        symbolName: "photo",
        detailTabs: [
            DetailTabSpec(.info),
            // The View tab (DetailTab.pdf relabeled) renders the CAS artifact.
            // RecordTabContext has no dedicated "has data" field, so hosts
            // encode data presence through previewKind: `.compiledPDF` when
            // the payload carries a `data_hash`, `.none` otherwise (see
            // FigureDetailPane.tabContext). Default nil = hidden.
            DetailTabSpec(.pdf, isAvailable: {
                ($0.previewKind ?? DocumentFormat.PreviewKind.none) != .none
            }),
        ],
        triage: TriageCapabilities(
            canStar: true,
            canFlag: true,
            canTag: true,
            // Figures have no status field today — no dismiss/archive lifecycle.
            dismissal: .none,
            archiveStatus: nil,
            deletion: .confirmHard,
            statuses: []
        ),
        creation: [],   // figures are created by the canvas/generators, not `n`
        defaultOpenBehavior: .window(id: "canvas"),
        // ADR-0022 D3: figure folders are `figure-collection` items and are
        // the odd binding — both nesting AND membership run through the
        // ENVELOPE parent. That asymmetry lives in the Rust kernel; the
        // sidebar only picks the binding.
        collection: CollectionCapability(
            bindingID: CollectionBindingID.figure,
            canOrganize: true,
            dragUTTypeIdentifier: "com.impress.figure-id"
        )
    )
}

public enum MessageRecordKind {
    public static let descriptor = RecordKindDescriptor(
        id: .message,
        schemaRefs: ["email-message", "chat-message"],
        displayName: "Message",
        symbolName: "envelope",
        detailTabs: [
            DetailTabSpec(.info),
            // The raw plain-text body (payload body is text after Stage 0).
            DetailTabSpec(.source),
            // The View tab (DetailTab.pdf relabeled) — the body typeset at a
            // reading measure. Always available: every message has a body
            // surface, even when empty.
            DetailTabSpec(.pdf),
        ],
        triage: TriageCapabilities(
            canStar: true,
            canFlag: true,
            canTag: true,
            // Mail's lifecycle is IMAP-owned (Stage 2-A): messages have NO
            // status field, so `.statusChange` dismissal would be wrong, and
            // deletion/moves must go through impart's IMAP flows — never the
            // store. v1 therefore declares NO dismissal and NO deletion
            // (`d` returns .ignored in the list; archive-to-folder is a
            // Stage-2-A2 follow-up, see docs/chassis-capability-matrix.md).
            dismissal: .none,
            archiveStatus: nil,
            deletion: .none,
            statuses: []
        ),
        creation: [],   // compose stays app-side (impart's classic window)
        defaultOpenBehavior: .detailPane
    )
}

public enum TaskRecordKind {
    public static let descriptor = RecordKindDescriptor(
        id: .task,
        // VERSIONED refs — impel-core's TaskStoreApi writes them with the
        // version suffix (task_store.rs TASK_SCHEMA).
        schemaRefs: ["task@1.0.0"],
        displayName: "Task",
        symbolName: "checklist",
        detailTabs: [
            DetailTabSpec(.info),
            // The task description/prompt text, monospaced.
            DetailTabSpec(.source),
            // The View tab (DetailTab.pdf relabeled) — the latest run's
            // result_summary rendered with MarkdownUI. Always available:
            // the pane shows an honest empty state before any run exists.
            DetailTabSpec(.pdf),
        ],
        triage: TriageCapabilities(
            canStar: true,
            canFlag: true,
            canTag: true,
            // Task state transitions are KERNEL-ONLY: TaskStoreApi.transition
            // is the sole legal mutation (ADR-0015 D1; docs/status-lifecycle.md).
            // A `.statusChange` dismissal would write the chassis's generic
            // "status" field and bypass the kernel's validated lifecycle, so
            // v1 declares NO dismissal and NO deletion (`d` returns .ignored
            // in the list; commands stay on impel's HTTP path).
            dismissal: .none,
            archiveStatus: nil,
            deletion: .none,
            // The kernel lifecycle lives in payload `state`, not the
            // chassis's `status` machinery — declared empty on purpose, and
            // declared for real below as a `lifecycle`.
            statuses: []
        ),
        creation: [],   // tasks are scheduled by impel-taskd/counsel, not `n`
        defaultOpenBehavior: .detailPane,
        // The kernel task lifecycle (ADR-0015 D1): payload `state`, mutated
        // ONLY by `TaskStoreApi.transition`. Declared here — with the labels
        // and icons that used to be a `switch` plus a parallel array in
        // `AgentStoreReader` — so the sidebar's per-state smart children, the
        // list row's header and the detail pane's State row all read one
        // declaration. Order is canonical pipeline order and IS the sidebar
        // order.
        lifecycle: RecordLifecycleSpec(
            payloadField: "state",
            states: [
                StatusSpec("queued", label: "Queued", systemImage: "clock"),
                StatusSpec("running", label: "Running", systemImage: "play.circle"),
                StatusSpec(
                    "waiting_review", label: "Waiting Review",
                    systemImage: "person.crop.circle.badge.questionmark"),
                StatusSpec(
                    "completed", label: "Completed",
                    systemImage: "checkmark.circle", isTerminal: true),
                StatusSpec(
                    "failed", label: "Failed",
                    systemImage: "xmark.circle", isTerminal: true),
                StatusSpec(
                    "cancelled", label: "Cancelled",
                    systemImage: "slash.circle", isTerminal: true),
            ])
    )
}

public enum AgentRunRecordKind {
    public static let descriptor = RecordKindDescriptor(
        id: .agentRun,
        schemaRefs: ["agent-run@1.0.0"],
        displayName: "Agent Run",
        symbolName: "bolt",
        detailTabs: [
            DetailTabSpec(.info),
            // The raw result_summary, monospaced.
            DetailTabSpec(.source),
            // The View tab (DetailTab.pdf relabeled) — result_summary
            // rendered with MarkdownUI.
            DetailTabSpec(.pdf),
        ],
        triage: TriageCapabilities(
            canStar: true,
            canFlag: true,
            canTag: true,
            // Runs are immutable provenance records (ADR-0005 §5) — no
            // lifecycle verbs at all.
            dismissal: .none,
            archiveStatus: nil,
            deletion: .none,
            statuses: []
        ),
        creation: [],   // runs are recorded by the kernel, never by hand
        defaultOpenBehavior: .detailPane
        // No `lifecycle` either: unlike a task, a run has no `state` field.
        // `AgentRunPayload` is model/prompt_hash/result_summary/token_count —
        // a run is a record OF a completed action, not a thing in progress.
    )
}

public enum ArtifactRecordKind {
    /// The artifact DOMAIN, not one schema: impress-core registers eight
    /// sibling schemas under an `impress/artifact/…` namespace (one per
    /// artifact medium) and there is no umbrella `artifact` id.
    ///
    /// This descriptor declared `["artifact"]` from Stage 1 until 2026-07-29.
    /// Nothing has ever written that ref, so the exact-equality lookups in
    /// `RecordKindRegistry.descriptor(forSchemaRef:)` and the tolerant
    /// `kind(forStoreSchemaRef:)` both missed EVERY artifact row: grouped
    /// global search and the Related-items section bucketed all of them as
    /// "unknown kind" with the `questionmark.square.dashed` glyph. The
    /// schema-ref lint (`scripts/check-schema-refs.sh`) surfaced it as the
    /// `artifact-descriptor-ref` divergence; this is the fix, so that
    /// divergence entry is retired in the same change.
    ///
    /// Spellings copied from `schema-refs.json`, never from a sibling call
    /// site (root CLAUDE.md, "Definition of done — schema refs"), and kept on
    /// ONE line because the lint's `schemaRefs:` extraction is line-local — a
    /// wrapped array would silently stop being validated.
    public static let descriptor = RecordKindDescriptor(
        id: .artifact,
        schemaRefs: ["impress/artifact/code", "impress/artifact/dataset", "impress/artifact/general", "impress/artifact/media", "impress/artifact/note", "impress/artifact/poster", "impress/artifact/presentation", "impress/artifact/webpage"],
        displayName: "Artifact",
        symbolName: "archivebox",
        detailTabs: [DetailTabSpec(.info)],
        triage: TriageCapabilities(
            canStar: false,
            canFlag: true,
            canTag: true,
            dismissal: .none,
            deletion: .confirmHard,
            statuses: []
        ),
        defaultOpenBehavior: .detailPane
    )
}

/// Every shipped descriptor, in registration order.
///
/// Kind-INTRINSIC lookups (today: `CollectionCapability`) resolve here, not
/// through `AppShellConfiguration.recordKinds`: imbib's preset shows the
/// Figures section without registering `FigureRecordKind`, so a shell-scoped
/// lookup would silently make imbib's figure folders read-only.
public enum BuiltinRecordKinds {
    public static let all: [RecordKindDescriptor] = [
        PublicationRecordKind.descriptor,
        ManuscriptRecordKind.descriptor,
        ArtifactRecordKind.descriptor,
        FigureRecordKind.descriptor,
        MessageRecordKind.descriptor,
        TaskRecordKind.descriptor,
        AgentRunRecordKind.descriptor,
    ]

    public static let registry = RecordKindRegistry(all)

    /// Descriptors that organise their records into sidebar folders.
    public static var collectionCapable: [RecordKindDescriptor] {
        all.filter { $0.collection != nil }
    }

    /// The kind whose folders a kernel binding organises — the reverse of
    /// `CollectionCapability.bindingID`.
    ///
    /// Stage 3: sidebar folder nodes carry their BINDING (one node case for
    /// every kind) rather than being one case per kind, so the two directions
    /// of that mapping have to be resolvable from the declarations. A binding
    /// no shipped kind claims resolves to nil, which is the honest answer.
    public static func kind(forCollectionBindingID bindingID: String) -> RecordKindID? {
        collectionCapable.first { $0.collection?.bindingID == bindingID }?.id
    }

    /// The capability behind a kernel binding id.
    public static func collectionCapability(
        forBindingID bindingID: String
    ) -> CollectionCapability? {
        collectionCapable.first { $0.collection?.bindingID == bindingID }?.collection
    }
}
