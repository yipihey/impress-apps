import SwiftUI

/// Line number gutter with error/warning indicators for the source editor.
/// Works for both Typst and LaTeX modes.
struct EditorGutterView: View {
    let lineCount: Int
    let diagnosticsByLine: [Int: GutterDiagnostic]
    var lineHeight: CGFloat = 17
    let onTapLine: ((Int) -> Void)?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .trailing, spacing: 0) {
                ForEach(1...max(lineCount, 1), id: \.self) { lineNumber in
                    HStack(spacing: 2) {
                        // Diagnostic indicator
                        if let diagnostic = diagnosticsByLine[lineNumber] {
                            Button {
                                onTapLine?(lineNumber)
                            } label: {
                                Circle()
                                    .fill(diagnostic.severity == .error ? .red : .orange)
                                    .frame(width: 6, height: 6)
                            }
                            .buttonStyle(.plain)
                            .help(diagnostic.message)
                        } else {
                            Spacer()
                                .frame(width: 6)
                        }

                        // Line number
                        Text("\(lineNumber)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24, alignment: .trailing)
                    }
                    .frame(height: lineHeight)
                }
            }
        }
        .padding(.horizontal, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

/// A diagnostic marker for the gutter.
struct GutterDiagnostic {
    var message: String
    var severity: Severity

    enum Severity {
        case error, warning
    }
}

/// Build gutter diagnostics from LaTeX compilation results.
extension EditorGutterView {
    static func diagnosticsMap(from latexDiagnostics: [LaTeXDiagnostic]) -> [Int: GutterDiagnostic] {
        var map: [Int: GutterDiagnostic] = [:]
        for diag in latexDiagnostics {
            guard diag.line > 0 else { continue }
            // Errors take priority over warnings on the same line
            if let existing = map[diag.line], existing.severity == .error { continue }
            map[diag.line] = GutterDiagnostic(
                message: diag.message,
                severity: diag.severity == .error ? .error : .warning
            )
        }
        return map
    }
}

#Preview {
    HStack(spacing: 0) {
        EditorGutterView(
            lineCount: 20,
            diagnosticsByLine: [
                5: GutterDiagnostic(message: "Undefined control sequence", severity: .error),
                12: GutterDiagnostic(message: "Overfull hbox", severity: .warning),
            ],
            onTapLine: { print("Tapped line \($0)") }
        )
        .frame(width: 50)

        Rectangle()
            .fill(Color(nsColor: .textBackgroundColor))
    }
    .frame(width: 400, height: 350)
}
