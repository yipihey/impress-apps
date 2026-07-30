//
//  PMCManuscriptReexports.swift
//  imprint
//
//  GUI-meld Phase 3: the manuscript compile + edit stack physically moved out of
//  the imprint app target into imbib's PublicationManagerCore ("PMC") so there is
//  ONE compile implementation shared by both GUIs. This file re-exports the moved
//  PMC types under their original imprint names via `typealias`, so the ~30
//  existing imprint call sites keep referring to `DocumentFormat`,
//  `LaTeXDiagnostic`, `ManuscriptCompileController`, etc. unchanged and need no
//  `import PublicationManagerCore` of their own.
//
//  Keeping the PMC import confined to this one file is deliberate: PMC also adds
//  `Logger` category extensions (e.g. `Logger.compilation`) that would otherwise
//  collide with imprint's own `Logger+Imprint.swift` extensions in any file that
//  imported PMC directly. Because Swift `import` visibility is per-file, the
//  collision is avoided everywhere except here — and this file references no
//  `Logger` category, so there is no ambiguity.
//

import PublicationManagerCore

// MARK: - Document format + diagnostics (pure model types)

typealias DocumentFormat = PublicationManagerCore.DocumentFormat
typealias LaTeXDiagnostic = PublicationManagerCore.LaTeXDiagnostic

// MARK: - Compile core

typealias ManuscriptCompileController = PublicationManagerCore.ManuscriptCompileController
typealias CompileInputs = PublicationManagerCore.CompileInputs

// MARK: - LaTeX compile capability (SystemLaTeXCompiler stays in imprint and
// conforms to this protocol; iOS uses the UnsupportedLaTeXCompiler default)

typealias LaTeXCompiling = PublicationManagerCore.LaTeXCompiling
typealias UnsupportedLaTeXCompiler = PublicationManagerCore.UnsupportedLaTeXCompiler
typealias LaTeXCompileRequest = PublicationManagerCore.LaTeXCompileRequest
typealias LaTeXCompileResult = PublicationManagerCore.LaTeXCompileResult
typealias LaTeXCompileOutcome = PublicationManagerCore.LaTeXCompileOutcome
typealias LaTeXPostCompileResult = PublicationManagerCore.LaTeXPostCompileResult

// MARK: - Compiled-artifact cache seam (DocumentRegistry conforms below)

typealias CompiledArtifactStoring = PublicationManagerCore.CompiledArtifactStoring
typealias NoopCompiledArtifactStore = PublicationManagerCore.NoopCompiledArtifactStore

// MARK: - Section extraction (moved with the editor; used by ContentView,
// ImprintHTTPRouter, PromptContextBuilder, ThroughlineCoordinator)

typealias SectionExtractor = PublicationManagerCore.SectionExtractor
typealias SectionFormat = PublicationManagerCore.SectionFormat
typealias ExtractedSection = PublicationManagerCore.ExtractedSection

// MARK: - Schema-ref base-name helper
//
// `ManuscriptStoreAdapter` had its own copy of this one-liner, with a comment
// explaining it was "kept local so this file needs no PMC import" — but the
// adapter already imports PMC (it reads `ManuscriptRecordKind.descriptor` for
// its schema ref and status lifecycle), so the justification had expired. Two
// implementations of "strip the @version" is one more than the number of
// version-tolerance rules the suite is allowed to have: schema-refs.json
// exists because readers and writers disagreeing about a ref's spelling has
// shipped five times.

typealias RecordKindSchemaRef = PublicationManagerCore.RecordKindSchemaRef

// MARK: - Source editor (macOS only) — consumed by ContentView + FocusModeView

#if os(macOS)
typealias SourceEditorView = PublicationManagerCore.SourceEditorView
#endif

// MARK: - Record-kind descriptors (ADR-0021) — the chassis contract as DATA
//
// De-gated to iOS in the foundation pass, which is the whole point: the
// manuscript kind's status lifecycle ("dismissed" / "draft" / "archived"),
// its deletion semantics and its collection binding are DECLARED once, in
// `BuiltinRecordKinds.swift`, and `ManuscriptStoreAdapter` READS them rather
// than re-typing the strings. A second literal is a second source of truth.

typealias RecordKindID = PublicationManagerCore.RecordKindID
typealias RecordKindDescriptor = PublicationManagerCore.RecordKindDescriptor
typealias ManuscriptRecordKind = PublicationManagerCore.ManuscriptRecordKind
typealias BuiltinRecordKinds = PublicationManagerCore.BuiltinRecordKinds
typealias TriageCapabilities = PublicationManagerCore.TriageCapabilities
typealias DismissalSemantics = PublicationManagerCore.DismissalSemantics
typealias DeletionSemantics = PublicationManagerCore.DeletionSemantics
typealias CollectionCapability = PublicationManagerCore.CollectionCapability
typealias CollectionBindingID = PublicationManagerCore.CollectionBindingID

// MARK: - Generic store kernels (Stage 4b) — the collection + triage verbs, once
//
// `ManuscriptStoreAdapter` used to carry a hand-rolled twin of both of these
// (~540 lines), for one reason: the PMC originals named imbib's singletons for
// their mutation fan-out (`RustStoreAdapter.shared`) and their undo
// (`UndoCoordinator.shared`, macOS-only). `StoreKernelScope` injects those, so
// imprint runs the SHARED verbs on ITS store handle, ITS `postMutation` and a
// caller-supplied `UndoManager` — on macOS and iOS alike.

typealias StoreKernelScope = PublicationManagerCore.StoreKernelScope
typealias StoreUndoScope = PublicationManagerCore.StoreUndoScope
typealias StoreKernelUndoAction = PublicationManagerCore.StoreKernelUndoAction
typealias StoreMutationNotice = PublicationManagerCore.StoreMutationNotice
typealias CollectionStoreAdapter = PublicationManagerCore.CollectionStoreAdapter
typealias CollectionKernelRow = PublicationManagerCore.CollectionKernelRow
typealias RecordTriageStoreKernel = PublicationManagerCore.RecordTriageStoreKernel
