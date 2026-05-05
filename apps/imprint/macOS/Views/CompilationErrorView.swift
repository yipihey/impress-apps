import SwiftUI

/// Displays Typst/LaTeX compilation errors and warnings below the PDF preview.
///
/// LaTeX errors and warnings come through `latexDiagnostics` as structured
/// `LaTeXDiagnostic` values — every item has a parsed line number and is
/// individually clickable to navigate to that line.
///
/// Typst (and any non-LaTeX format) still uses the legacy string paths.
struct CompilationErrorView: View {
    /// Structured LaTeX diagnostics (errors + warnings). Used when present.
    let diagnostics: [LaTeXDiagnostic]
    /// Fallback string error message (Typst, generic compile failures).
    let errors: String?
    /// Fallback string warnings (Typst).
    let warnings: [String]
    let onNavigateToLine: ((Int) -> Void)?

    private var hasStructuredDiagnostics: Bool {
        !diagnostics.isEmpty
    }

    private var structuredErrors: [LaTeXDiagnostic] {
        diagnostics.filter { $0.severity == .error }
    }

    private var structuredWarnings: [LaTeXDiagnostic] {
        diagnostics.filter { $0.severity != .error }
    }

    var body: some View {
        if hasStructuredDiagnostics {
            structuredView
        } else if let errors = errors, !errors.isEmpty {
            legacyErrorPanel(errors)
        } else if !warnings.isEmpty {
            legacyWarningPanel
        }
    }

    // MARK: - Structured (LaTeX)

    @ViewBuilder
    private var structuredView: some View {
        let errs = structuredErrors
        let warns = structuredWarnings
        if !errs.isEmpty {
            diagnosticPanel(
                title: "\(errs.count) Error\(errs.count == 1 ? "" : "s")",
                icon: "xmark.circle.fill",
                accent: .red,
                items: errs,
                maxHeight: 140
            )
        } else if !warns.isEmpty {
            diagnosticPanel(
                title: "\(warns.count) Warning\(warns.count == 1 ? "" : "s")",
                icon: "exclamationmark.triangle.fill",
                accent: .orange,
                items: warns,
                maxHeight: 100
            )
        }
    }

    private func diagnosticPanel(
        title: String,
        icon: String,
        accent: Color,
        items: [LaTeXDiagnostic],
        maxHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(accent)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(accent)
                Spacer()
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { diag in
                        diagnosticRow(diag, accent: accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)
        }
        .padding(8)
        .background(accent.opacity(0.08))
        .accessibilityIdentifier("compilation.diagnostics.panel")
    }

    private func diagnosticRow(_ diag: LaTeXDiagnostic, accent: Color) -> some View {
        Button {
            if diag.line > 0 {
                onNavigateToLine?(diag.line)
            }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                if diag.line > 0 {
                    Text("\(fileLabel(for: diag)):\(diag.line)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.blue)
                        .underline()
                } else {
                    Text(fileLabel(for: diag))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(diag.message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(diag.context ?? diag.message)
    }

    private func fileLabel(for diag: LaTeXDiagnostic) -> String {
        // Strip path components for compactness; show just basename
        if diag.file.isEmpty { return "?" }
        return (diag.file as NSString).lastPathComponent
    }

    // MARK: - Legacy string-based panels (Typst, generic)

    private func legacyErrorPanel(_ errorText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Compilation Error")
                    .font(.headline)
                    .foregroundStyle(.red)
                Spacer()
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(parseErrorLines(errorText), id: \.self) { line in
                        legacyLineView(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
        .padding(8)
        .background(Color.red.opacity(0.08))
        .accessibilityIdentifier("compilationError.panel")
    }

    private var legacyWarningPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(warnings.count) Warning\(warnings.count == 1 ? "" : "s")")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(warnings, id: \.self) { warning in
                        legacyLineView(warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 80)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
        .accessibilityIdentifier("compilationWarning.panel")
    }

    private func legacyLineView(_ line: String) -> some View {
        let parsed = parseLineNumber(from: line)
        return Button {
            if let n = parsed.lineNumber { onNavigateToLine?(n) }
        } label: {
            HStack(alignment: .top, spacing: 4) {
                if let lineNum = parsed.lineNumber {
                    Text("line \(lineNum)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.blue)
                        .underline()
                }
                Text(parsed.message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func parseErrorLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private struct ParsedLine {
        let lineNumber: Int?
        let message: String
    }

    private func parseLineNumber(from line: String) -> ParsedLine {
        let patterns = [
            #":(\d+):\d+:"#,
            #"^l\.(\d+)"#,
            #"on input line (\d+)"#,
            #"line (\d+)"#,
            #"\.tex:(\d+):"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line),
               let lineNum = Int(line[range]) {
                return ParsedLine(lineNumber: lineNum, message: line)
            }
        }
        return ParsedLine(lineNumber: nil, message: line)
    }
}
