//
//  LaTeXDiagnostic.swift
//  imprint
//
//  Pure data type for LaTeX compilation diagnostics. Lives in Shared so
//  cross-platform code (view model, DocumentRegistry, error views) can
//  carry diagnostics even though LaTeX *compilation* is macOS-only —
//  on iOS these arrays are simply always empty.
//

import Foundation

/// A single diagnostic from LaTeX compilation.
struct LaTeXDiagnostic: Identifiable, Sendable {
    let id = UUID()
    var file: String
    var line: Int
    var column: Int?
    var message: String
    var severity: DiagnosticSeverity
    var context: String?

    enum DiagnosticSeverity: String, Sendable {
        case error, warning, info
    }
}
