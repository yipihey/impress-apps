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
