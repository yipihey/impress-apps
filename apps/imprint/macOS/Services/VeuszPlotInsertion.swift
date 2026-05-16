import Foundation

/// Builds the format-appropriate manuscript snippet that embeds a Veusz plot's
/// rendered output. Two formats are produced today:
///   - Typst: `#figure(image("figures/plot.svg", width: 80%), caption: [Plot])`
///   - LaTeX: `\begin{figure}\centering\includegraphics[width=0.8\textwidth]{figures/plot.svg}\caption{Plot}\end{figure}`
///
/// The snippet uses the plot's `renderedRelativePath` so the manuscript points
/// at the rendered output (svg/png/pdf), not the .vsz source.
enum VeuszPlotInsertion {

    /// Block-level insertion (a complete figure environment).
    static func block(for plot: VeuszPlotRef, format: DocumentFormat) -> String {
        switch format {
        case .typst:
            return """
            #figure(
                image("\(plot.renderedRelativePath)", width: 80%),
                caption: [\(escapedCaption(plot.displayName, for: .typst))],
            )
            """
        case .latex:
            return """
            \\begin{figure}
                \\centering
                \\includegraphics[width=0.8\\textwidth]{\(plot.renderedRelativePath)}
                \\caption{\(escapedCaption(plot.displayName, for: .latex))}
            \\end{figure}
            """
        }
    }

    /// Notification name used to ask the editor to insert a plot at the cursor.
    /// userInfo:
    ///   - "plotID": UUID
    ///   - "snippet": String (pre-rendered insertion text)
    static let notificationName = Notification.Name("com.imprint.insertVeuszPlot")

    // MARK: - Escape helpers

    private static func escapedCaption(_ text: String, for format: DocumentFormat) -> String {
        switch format {
        case .typst:
            // Typst content blocks use [ ] — escape `]` and backslashes.
            return text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "]", with: "\\]")
        case .latex:
            // Escape the canonical LaTeX special characters that would otherwise
            // break the document or render incorrectly inside \caption{}.
            var out = ""
            out.reserveCapacity(text.count)
            for ch in text {
                switch ch {
                case "\\": out += "\\textbackslash{}"
                case "{": out += "\\{"
                case "}": out += "\\}"
                case "$": out += "\\$"
                case "&": out += "\\&"
                case "%": out += "\\%"
                case "#": out += "\\#"
                case "_": out += "\\_"
                case "^": out += "\\^{}"
                case "~": out += "\\~{}"
                default: out.append(ch)
                }
            }
            return out
        }
    }
}
