//
//  LaTeXDiagnostic.swift
//  PublicationManagerCore
//
//  Pure data type for LaTeX compilation diagnostics. GUI-meld Phase 3: moved
//  from the imprint app target into PMC so the shared compile stack can carry
//  diagnostics even though LaTeX *compilation* is macOS-only — on iOS / TeX-less
//  hosts these arrays are simply always empty.
//

import Foundation

/// A single diagnostic from LaTeX compilation.
public struct LaTeXDiagnostic: Identifiable, Sendable {
    public let id = UUID()
    public var file: String
    public var line: Int
    public var column: Int?
    public var message: String
    public var severity: DiagnosticSeverity
    public var context: String?

    public init(
        file: String,
        line: Int,
        column: Int? = nil,
        message: String,
        severity: DiagnosticSeverity,
        context: String? = nil
    ) {
        self.file = file
        self.line = line
        self.column = column
        self.message = message
        self.severity = severity
        self.context = context
    }

    public enum DiagnosticSeverity: String, Sendable {
        case error, warning, info
    }
}
