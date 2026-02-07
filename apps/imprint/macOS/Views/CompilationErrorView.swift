import SwiftUI

/// Displays Typst compilation errors and warnings below the PDF preview.
struct CompilationErrorView: View {
    let errors: String?
    let warnings: [String]
    let onNavigateToLine: ((Int) -> Void)?

    var body: some View {
        if let errors = errors, !errors.isEmpty {
            errorPanel(errors)
        } else if !warnings.isEmpty {
            warningPanel
        }
    }

    private func errorPanel(_ errorText: String) -> some View {
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
                        errorLineView(line)
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

    private var warningPanel: some View {
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
                        errorLineView(warning)
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

    private func errorLineView(_ line: String) -> some View {
        let parsed = parseLineNumber(from: line)

        return HStack(alignment: .top, spacing: 4) {
            if let lineNum = parsed.lineNumber {
                Button {
                    onNavigateToLine?(lineNum)
                } label: {
                    Text("line \(lineNum)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            Text(parsed.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Parsing

    private func parseErrorLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private struct ParsedLine: Hashable {
        let lineNumber: Int?
        let message: String
    }

    /// Extract line number from Typst error messages like "error: file.typ:12:5: unexpected token"
    private func parseLineNumber(from line: String) -> ParsedLine {
        // Pattern: something:LINE:COL: message  or  line LINE: message
        let patterns = [
            #":(\d+):\d+:"#,       // file.typ:12:5: ...
            #"line (\d+)"#,        // line 12: ...
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

#Preview {
    VStack {
        CompilationErrorView(
            errors: "error: main.typ:12:5: unexpected token\nerror: main.typ:25:1: unknown variable 'foo'",
            warnings: [],
            onNavigateToLine: { print("Navigate to line \($0)") }
        )

        CompilationErrorView(
            errors: nil,
            warnings: ["warning: unused import at line 3"],
            onNavigateToLine: nil
        )
    }
    .frame(width: 500)
}
