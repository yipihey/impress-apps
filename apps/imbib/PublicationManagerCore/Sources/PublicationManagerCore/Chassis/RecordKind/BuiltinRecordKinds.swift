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
        defaultOpenBehavior: .detailPane,
        // ADR-0022 C2. Publication collections were the ONE shipped collection
        // binding with no Swift capability, which is why they stayed on the
        // legacy `.libraryCollection` path while manuscripts and figures moved
        // onto the generic folder block in G2. The three optional axes below
        // are exactly what the wave-3 routing survey found missing:
        //
        //   1. `container` — collections are per-LIBRARY. A node carries
        //      (collectionID, libraryID), a drop must not cross libraries
        //      unless it is a real move, and creation names the library.
        //   2. `organizePolicy: .unlessSmart` — a SMART collection is defined
        //      by its query, so it offers Delete only. Sourced per row from
        //      the kernel's `is_smart`, not from a second legacy read.
        //   3. `tiers` — the same schema and binding appear in three places
        //      with different affordances.
        //
        // `deleteTitleOverride` keeps the frozen menu literal: imbib says
        // "Delete", not "Delete Collection".
        collection: CollectionCapability(
            bindingID: CollectionBindingID.publication,
            canOrganize: true,
            // Publication rows drag as raw UUID JSON on imbib's own
            // pasteboard type, handled by `handlePublicationDrop` rather than
            // the generic `handleRecordDrop` — see the C2 matrix note on why
            // that one site stays app-side (library-membership semantics and
            // the multi-select union feeding `PublicationSource`).
            dragUTTypeIdentifier: nil,
            folderSymbolName: "folder",
            containerNoun: "Collection",
            organizePolicy: .unlessSmart,
            container: CollectionContainerSpec(noun: "Library"),
            tiers: [
                // Matrix row `libraryCollection`: Rename / Subcoll / Delete.
                CollectionTier(
                    id: CollectionTierID.libraries,
                    allowsRename: true, allowsSubcontainers: true),
                // Matrix row `inboxCollection`: rename ✅, delete ✅.
                CollectionTier(
                    id: CollectionTierID.inbox,
                    allowsRename: true, allowsSubcontainers: true),
                // Matrix row `explorationCollection`: "✅ Delete" only —
                // named by the search that produced it, so rename and
                // sub-collections are both meaningless.
                CollectionTier(
                    id: CollectionTierID.exploration,
                    allowsRename: false, allowsSubcontainers: false),
            ],
            deleteTitleOverride: "Delete"
        ),
        // ADR-0023 D1/D3. A watched `.bib` or `.ris` is a CONTAINER: it fans
        // out to publication entries, deduped through the Rust identifier
        // machinery against the whole library. That is BibDesk's model
        // generalized, and it is what imbib ADR-002's "BibTeX is the source of
        // truth" already implies.
        //
        // The extensions and the one UTI are PINNED against
        // `impress_core::bibliography_format`, the authority ADR-0023 had to
        // create: before it, "which extensions are a bibliography?" was
        // answered by twenty-three independent inline literals across the tree
        // and no constant at all. `FileDiscoveryCapabilityParityTests` reads
        // that Rust table and fails if these drift from it.
        //
        // `.ris` carries no UTI because the suite declares none — anywhere.
        // Saying `nil` here is what makes `requiresFilenameFallback` true, and
        // a discovery query that trusted a UTI-only clause would silently never
        // match a RIS file.
        fileDiscovery: FileDiscoveryCapability(
            types: [
                FileTypeSpec(
                    id: "bibtex",
                    fileExtensions: ["bib", "bibtex"],
                    // Exported by imbib (apps/imbib/imbib/project.yml) with
                    // `public.filename-extension: [bib]` — the only `.bib`
                    // claim in the suite.
                    utiIdentifier: "com.impress.bibtex-entry"),
                FileTypeSpec(id: "ris", fileExtensions: ["ris"], utiIdentifier: nil),
            ],
            ingestUnit: .entries)
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
            // `freezesSource` marks the three transitions that write a
            // manuscript-revision snapshot (ADR-0011 D5). It is DECLARED rather
            // than derived because no other facet yields this set: `submitted`
            // is the primary freeze trigger and is deliberately non-terminal,
            // while `dismissed` IS terminal and must not freeze. impel's
            // `JournalPipeline.autoSnapshotStatuses` is the consumer; its
            // parity suite checks the pipeline's literal against THIS.
            statuses: [
                StatusSpec("draft", label: "Drafts", systemImage: "pencil"),
                StatusSpec(
                    "internal-review", label: "Internal Review",
                    systemImage: "person.2"),
                StatusSpec(
                    "submitted", label: "Submitted", systemImage: "paperplane",
                    freezesSource: true),
                StatusSpec(
                    "in-revision", label: "In Revision",
                    systemImage: "arrow.triangle.2.circlepath"),
                StatusSpec(
                    "published", label: "Published",
                    systemImage: "checkmark.seal", isTerminal: true,
                    freezesSource: true),
                StatusSpec(
                    "archived", label: "Archive",
                    systemImage: "archivebox", isTerminal: true,
                    freezesSource: true),
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
        ),
        // ADR-0023 D1/D3. A watched manuscript file IS the record, ingested
        // reference-in-place (D4): the row carries a bookmark, a path, a hash
        // and an mtime, and the file stays the user's. No write-back.
        //
        // The extensions are READ FROM THE AUTHORITY, not restated: this is
        // `DocumentFormatGrammar`, which fetches Rust's
        // `impress_core::manuscript_format::MANUSCRIPT_FORMAT_GRAMMAR` over the
        // FFI once and caches it. Adding a format — or an extension to one —
        // is still exactly one row of Rust, and this capability follows without
        // an edit. That is the pattern ADR-0023 D1 asks for and the reason the
        // `.bib`/`.ris` half needed a Rust table built for it.
        fileDiscovery: FileDiscoveryCapability(
            types: DocumentFormat.allCases.map { format in
                FileTypeSpec(
                    id: format.rawValue,
                    fileExtensions: DocumentFormatGrammar.row(for: format.rawValue).extensions,
                    utiIdentifier: ManuscriptRecordKind.declaredUTIs[format.rawValue])
            },
            ingestUnit: .file)
    )

    /// The UTI each manuscript format is claimed by, where an app claims one.
    ///
    /// Only LaTeX has a narrow declared type — imprint's `CFBundleDocumentTypes`
    /// claims `org.tug.tex` for `.tex`. Typst and Markdown have no UTI in the
    /// suite at all.
    ///
    /// `public.plain-text` is DELIBERATELY absent even though imprint declares
    /// it for `.txt`: it is a conformance every text file on the volume
    /// satisfies, so putting it here would turn a watched manuscript folder's
    /// Spotlight scope into "every text file", which is not a manuscript
    /// folder. A UTI earns its place here by IDENTIFYING the kind, not by
    /// being technically true of it.
    static let declaredUTIs: [String: String] = ["latex": "org.tug.tex"]
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
        ),
        // ADR-0023 D1/D3: a Veusz document IS the figure, reference-in-place.
        // `org.veusz.document` is Veusz's own identifier, IMPORTED (never
        // exported) by imprint's project.yml with
        // `public.filename-extension: [vsz]` — importing another vendor's type
        // is the correct declaration for a file the suite reads but does not
        // own. implore, the app that will consume these, declares nothing for
        // `.vsz` today; the parity test names imprint's declaration as the one
        // that exists, so hoisting it later fails loudly here rather than
        // silently emptying a watched folder.
        fileDiscovery: FileDiscoveryCapability(
            types: [
                FileTypeSpec(
                    id: "veusz",
                    fileExtensions: ["vsz"],
                    utiIdentifier: "org.veusz.document")
            ],
            ingestUnit: .file)
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
        // Stage 4c: compose is DECLARED here and PERFORMED by the host
        // (`RecordHostVerbs.onCreate`, injected by ImpartChassisRoot). The
        // chassis owns the affordances — the `n` key and the empty-state
        // button — and knows nothing about SMTP, drafts or Core Data. Before
        // this, `creation: []` said "mail cannot be created", which was never
        // true; it meant "compose lives in the classic window", and that window
        // is gone.
        creation: [CreationAffordance(label: "New Message")],
        defaultOpenBehavior: .detailPane,
        // ADR-0023 D1/D3, and the one entry in the ingest map the ADR leaves
        // open: "impart | .mbox, .eml | file → messages (phase 3 decision)".
        //
        // Declared `.file` for now, and the reason is not indecision. An
        // `.eml` IS one message, so `file` is simply correct for it; an
        // `.mbox` is an archive of many, which reads like `entries` — but
        // unlike a `.bib`, an mbox has no dedup identifier machinery behind it
        // and impart's message lifecycle is IMAP-owned (see the triage
        // capability above, which declares neither dismissal nor deletion for
        // exactly that reason). Claiming `entries` before that question is
        // answered would put the fan-out on a path with nothing to fan out
        // THROUGH. W4 is where it is decided; until then the file-level
        // bookkeeping — which archives exist, their hashes, their provenance —
        // is real and useful on its own, and is what `file` buys.
        //
        // Neither extension has a UTI anywhere in the suite, so
        // `requiresFilenameFallback` is true and a discovery query must match
        // on the filename.
        fileDiscovery: FileDiscoveryCapability(
            types: [
                FileTypeSpec(id: "mbox", fileExtensions: ["mbox"], utiIdentifier: nil),
                FileTypeSpec(id: "eml", fileExtensions: ["eml"], utiIdentifier: nil),
            ],
            ingestUnit: .file)
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

    /// Descriptors a watched folder can be scoped to (ADR-0023 D1).
    ///
    /// Resolved from `all`, not from a shell's `recordKinds`, for the same
    /// reason `collectionCapable` is: file discovery is kind-INTRINSIC, and a
    /// shell-scoped lookup would make imbib unable to name the manuscript kind
    /// it does not register but does display.
    public static var fileDiscoverable: [RecordKindDescriptor] {
        all.filter { $0.fileDiscovery != nil }
    }

    /// The `kind_scope` values a `watched-folder@1.0.0` row may carry — the
    /// Swift end of the string the Rust schema stores.
    ///
    /// The store keeps the scope as a bare string (it is schema-agnostic and
    /// must stay that way), so this is where a caller finds out which strings
    /// mean anything. A folder whose scope is not in here resolves no
    /// capability and therefore watches nothing, which is the honest outcome
    /// and not a crash.
    public static var fileDiscoveryKindScopes: [String] {
        fileDiscoverable.map(\.id.rawValue)
    }

    /// The capability for a watched folder's `kind_scope`, or nil.
    public static func fileDiscovery(
        forKindScope kindScope: String
    ) -> FileDiscoveryCapability? {
        fileDiscoverable.first { $0.id.rawValue == kindScope }?.fileDiscovery
    }
}
