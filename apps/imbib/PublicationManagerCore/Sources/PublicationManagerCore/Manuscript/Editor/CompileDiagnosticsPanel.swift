#if os(macOS)
//
//  CompileDiagnosticsPanel.swift
//  PublicationManagerCore
//
//  The compile strip's expandable diagnostics list: every error and warning
//  from the last compile, with the compiler's own remediation hints. Clicking
//  a row jumps the editor to the diagnostic's source range (the strip owns
//  the jump via `onJump`).
//

import SwiftUI

struct CompileDiagnosticsPanel: View {
    let diagnostics: [CompileDiagnostic]
    let onJump: (CompileDiagnostic) -> Void

    private var errors: [CompileDiagnostic] {
        diagnostics.filter { $0.severity == .error }
    }
    private var others: [CompileDiagnostic] {
        diagnostics.filter { $0.severity != .error }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Compiler Diagnostics")
                    .font(.headline)
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !diagnostics.isEmpty {
                    Button {
                        ManuscriptCompileErrorClipboard.copy(
                            errorText: summary, diagnostics: errors + others)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy all diagnostics to the clipboard")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if diagnostics.isEmpty {
                Text("No diagnostics")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(errors + others) { diagnostic in
                            row(diagnostic)
                            Divider()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 480)
        .frame(minHeight: 80, maxHeight: 420)
    }

    private var summary: String {
        var parts: [String] = []
        if !errors.isEmpty { parts.append("\(errors.count) error\(errors.count == 1 ? "" : "s")") }
        if !others.isEmpty { parts.append("\(others.count) warning\(others.count == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func row(_ diagnostic: CompileDiagnostic) -> some View {
        HStack(alignment: .top, spacing: 0) {
            jumpButton(diagnostic)
            Button {
                ManuscriptCompileErrorClipboard.copy(diagnostic: diagnostic)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Copy this diagnostic")
            .padding(.top, 7)
            .padding(.trailing, 10)
        }
    }

    @ViewBuilder
    private func jumpButton(_ diagnostic: CompileDiagnostic) -> some View {
        Button {
            onJump(diagnostic)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon(for: diagnostic.severity))
                        .foregroundStyle(color(for: diagnostic.severity))
                        .frame(width: 16)
                    Text(diagnostic.message)
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let line = diagnostic.line {
                        Text("line \(line)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                // The compiler's own suggested fixes.
                ForEach(diagnostic.hints, id: \.self) { hint in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "lightbulb")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .frame(width: 16)
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(diagnostic.line != nil
            ? "Jump to line \(diagnostic.line!) in the source" : diagnostic.message)
    }

    private func icon(for severity: CompileDiagnostic.Severity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    private func color(for severity: CompileDiagnostic.Severity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}
#endif
