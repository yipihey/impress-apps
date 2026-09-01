#if os(macOS)
//
//  ManuscriptCompileErrorCard.swift
//  PublicationManagerCore
//
//  What the Preview tab shows when the last compile FAILED. Before this
//  view existed, a failed compile left the Preview tab on the "Nothing
//  compiled yet" placeholder — the error was computed, stored on the
//  compile controller, shown in the Source tab's strip, and silently
//  withheld from the pane the user was actually looking at. The card
//  states the failure, shows the compiler's own message and hints
//  (selectable), and puts Copy one click away — a compile error's most
//  common next stop is a search box or an agent prompt.
//

import AppKit
import SwiftUI

/// Full-pane state for the Preview tab when there is no PDF to show and the
/// last compile failed.
struct ManuscriptCompileErrorCard: View {
    let errorText: String
    let diagnostics: [CompileDiagnostic]
    let onOpenSource: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Compile failed")
                .font(.headline)
            if let located = firstLocatedError {
                Text(locationLabel(for: located))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(displayText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxWidth: 560, maxHeight: 220)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Button {
                    ManuscriptCompileErrorClipboard.copy(errorText: errorText, diagnostics: diagnostics)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy Error", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button("Open Source", action: onOpenSource)
            }
            Text("The full diagnostic list, with jump-to-line, is in the Source tab's compile strip.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The error text plus each diagnostic's hints — the compiler's "did you
    /// mean …" lines are frequently the actual fix and must not be dropped.
    private var displayText: String {
        var lines = [errorText]
        for d in diagnostics where d.severity == .error {
            for hint in d.hints {
                lines.append("hint: \(hint)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private var firstLocatedError: CompileDiagnostic? {
        diagnostics.first { $0.severity == .error && $0.line != nil }
    }

    private func locationLabel(for d: CompileDiagnostic) -> String {
        if let line = d.line, let column = d.column {
            return "First error at line \(line), column \(column)"
        }
        if let line = d.line {
            return "First error at line \(line)"
        }
        return ""
    }
}

/// Compact banner for the Preview tab when a PREVIOUS successful PDF is still
/// on screen but the LATEST compile failed. Without it, the stale preview
/// silently impersonates the current state of the manuscript.
struct ManuscriptCompileErrorBanner: View {
    let errorText: String
    let diagnostics: [CompileDiagnostic]

    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Latest compile failed — showing the last successful preview.")
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                ManuscriptCompileErrorClipboard.copy(errorText: errorText, diagnostics: diagnostics)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy Error", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Copy the compile error to the clipboard")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
        )
        .padding(12)
    }
}

/// One clipboard shape for every copy affordance: the raw error text, then
/// each diagnostic with its location and hints — paste-ready for a search,
/// an issue, or an agent.
enum ManuscriptCompileErrorClipboard {
    static func copy(errorText: String, diagnostics: [CompileDiagnostic]) {
        var lines = [errorText]
        for d in diagnostics {
            lines.append(lineDescription(d))
        }
        let payload = lines.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    static func copy(diagnostic: CompileDiagnostic) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lineDescription(diagnostic), forType: .string)
    }

    private static func lineDescription(_ d: CompileDiagnostic) -> String {
        var parts: [String] = ["\(d.severity.rawValue):"]
        if let line = d.line {
            parts.append(d.column.map { "line \(line):\($0):" } ?? "line \(line):")
        }
        parts.append(d.message)
        var text = parts.joined(separator: " ")
        for hint in d.hints {
            text += "\n  hint: \(hint)"
        }
        return text
    }
}
#endif
