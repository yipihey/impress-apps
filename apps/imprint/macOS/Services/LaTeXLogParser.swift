import Foundation

/// Parses LaTeX `.log` file output into structured diagnostics.
enum LaTeXLogParser {

    struct ParseResult {
        var errors: [LaTeXDiagnostic]
        var warnings: [LaTeXDiagnostic]
    }

    /// Parse a LaTeX log string into errors and warnings.
    static func parse(_ log: String) -> ParseResult {
        var errors: [LaTeXDiagnostic] = []
        var warnings: [LaTeXDiagnostic] = []

        let lines = log.components(separatedBy: "\n")
        var currentFile = "main.tex"
        var fileStack: [String] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Track file stack via parentheses: (./file.tex and )
            trackFileStack(line: line, fileStack: &fileStack, currentFile: &currentFile)

            // LaTeX errors: "! LaTeX Error: ..." or "! ..."
            if line.hasPrefix("! ") {
                let message = String(line.dropFirst(2))
                let lineNumber = findLineNumber(in: lines, startingAt: i)
                let context = gatherContext(lines: lines, around: i)

                errors.append(LaTeXDiagnostic(
                    file: currentFile,
                    line: lineNumber ?? 0,
                    message: message,
                    severity: .error,
                    context: context
                ))
            }

            // Package/class warnings: "Package <name> Warning: ..."
            if let match = line.range(of: #"^Package \S+ Warning: (.+)$"#, options: .regularExpression) {
                let message = String(line[match])
                let lineNumber = extractLineFromWarning(line)

                warnings.append(LaTeXDiagnostic(
                    file: currentFile,
                    line: lineNumber ?? 0,
                    message: message,
                    severity: .warning
                ))
            }

            // LaTeX warnings: "LaTeX Warning: ..."
            if line.hasPrefix("LaTeX Warning: ") {
                let message = String(line.dropFirst("LaTeX Warning: ".count))
                let lineNumber = extractLineFromWarning(line)

                warnings.append(LaTeXDiagnostic(
                    file: currentFile,
                    line: lineNumber ?? 0,
                    message: message,
                    severity: .warning
                ))
            }

            // Overfull/Underfull box warnings
            if line.hasPrefix("Overfull \\") || line.hasPrefix("Underfull \\") {
                let lineNumber = extractLineFromWarning(line)
                warnings.append(LaTeXDiagnostic(
                    file: currentFile,
                    line: lineNumber ?? 0,
                    message: line,
                    severity: .info
                ))
            }

            i += 1
        }

        return ParseResult(errors: errors, warnings: warnings)
    }

    // MARK: - Helpers

    /// Look ahead for "l.42 ..." line number indicators after an error.
    private static func findLineNumber(in lines: [String], startingAt index: Int) -> Int? {
        // Check the next few lines for "l.N" pattern
        let searchEnd = min(index + 5, lines.count)
        for j in (index + 1)..<searchEnd {
            let candidate = lines[j]
            if let match = candidate.range(of: #"^l\.(\d+)"#, options: .regularExpression) {
                let numStr = candidate[match].dropFirst(2) // drop "l."
                return Int(numStr)
            }
        }
        return nil
    }

    /// Extract line number from "on input line N" or "line N" patterns in warning text.
    private static func extractLineFromWarning(_ text: String) -> Int? {
        let patterns = [
            #"on input line (\d+)"#,
            #"line (\d+)"#,
            #"at line (\d+)"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text),
               let num = Int(text[range]) {
                return num
            }
        }
        return nil
    }

    /// Track nested file opens via parentheses in log output.
    private static func trackFileStack(line: String, fileStack: inout [String], currentFile: inout String) {
        // Match opening: (./path/to/file.tex
        let openPattern = #"\((\./[^\s\)]+\.(?:tex|sty|cls|bbl|bst|aux))"#
        if let regex = try? NSRegularExpression(pattern: openPattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let range = Range(match.range(at: 1), in: line) {
            let file = String(line[range])
            fileStack.append(currentFile)
            currentFile = file
        }

        // Count closing parentheses (simplified — full tracking would need bracket balancing)
        let closeCount = line.filter { $0 == ")" }.count - line.filter { $0 == "(" }.count
        if closeCount > 0 {
            for _ in 0..<closeCount {
                if let prev = fileStack.popLast() {
                    currentFile = prev
                }
            }
        }
    }

    /// Gather a few lines of context around an error for display.
    private static func gatherContext(lines: [String], around index: Int) -> String {
        let start = max(0, index - 1)
        let end = min(lines.count, index + 4)
        return lines[start..<end].joined(separator: "\n")
    }
}
