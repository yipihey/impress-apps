import Foundation

/// Provides auto-completion suggestions for LaTeX editing.
///
/// Supports:
/// - `\` → common LaTeX commands
/// - `\begin{` → environment names
/// - `\cite{` → citation keys from .bib files (via LaTeXProjectService)
/// - `\ref{` → labels from project files (via LaTeXProjectService)
/// - `\usepackage{` → common package names
@MainActor
final class LaTeXCompletionProvider {
    static let shared = LaTeXCompletionProvider()

    /// Get completions for the given prefix at the cursor position.
    func completions(for prefix: String, in source: String, at cursorOffset: Int) async -> [LaTeXCompletion] {
        // Determine what kind of completion to provide
        if prefix.hasSuffix("\\cite{") || prefix.hasSuffix("\\citep{") || prefix.hasSuffix("\\citet{") ||
           prefix.hasSuffix("\\textcite{") || prefix.hasSuffix("\\parencite{") {
            return await citationCompletions(partial: extractPartial(prefix, delimiter: "{"))
        }

        if prefix.hasSuffix("\\ref{") || prefix.hasSuffix("\\eqref{") || prefix.hasSuffix("\\autoref{") ||
           prefix.hasSuffix("\\cref{") || prefix.hasSuffix("\\pageref{") {
            return await labelCompletions(partial: extractPartial(prefix, delimiter: "{"))
        }

        if prefix.hasSuffix("\\begin{") {
            return environmentCompletions(partial: extractPartial(prefix, delimiter: "{"))
        }

        if prefix.hasSuffix("\\usepackage{") || prefix.hasSuffix("\\usepackage[]{") {
            return packageCompletions(partial: extractPartial(prefix, delimiter: "{"))
        }

        // General command completion after `\`
        if let backslashIdx = prefix.lastIndex(of: "\\") {
            let partial = String(prefix[prefix.index(after: backslashIdx)...])
            return commandCompletions(partial: partial)
        }

        return []
    }

    private func extractPartial(_ text: String, delimiter: Character) -> String {
        if let idx = text.lastIndex(of: delimiter) {
            return String(text[text.index(after: idx)...])
        }
        return ""
    }

    // MARK: - Citation Completions

    private func citationCompletions(partial: String) async -> [LaTeXCompletion] {
        let keys = await LaTeXProjectService.shared.citationKeys
        return keys
            .filter { partial.isEmpty || $0.localizedCaseInsensitiveContains(partial) }
            .prefix(20)
            .map { LaTeXCompletion(text: $0, displayText: $0, kind: .citation) }
    }

    // MARK: - Label Completions

    private func labelCompletions(partial: String) async -> [LaTeXCompletion] {
        let labels = await LaTeXProjectService.shared.labels
        return labels
            .filter { partial.isEmpty || $0.localizedCaseInsensitiveContains(partial) }
            .prefix(20)
            .map { LaTeXCompletion(text: $0, displayText: $0, kind: .label) }
    }

    // MARK: - Environment Completions

    private func environmentCompletions(partial: String) -> [LaTeXCompletion] {
        let environments = [
            "document", "abstract", "figure", "table", "equation", "equation*",
            "align", "align*", "gather", "gather*", "multline", "multline*",
            "itemize", "enumerate", "description",
            "tabular", "tabularx", "array",
            "minipage", "center", "flushleft", "flushright",
            "theorem", "lemma", "proof", "definition", "proposition", "corollary",
            "verbatim", "lstlisting", "minted",
            "tikzpicture", "scope",
            "thebibliography", "appendix",
            "frame", // beamer
        ]

        return environments
            .filter { partial.isEmpty || $0.hasPrefix(partial) }
            .map { env in
                // Snippet: inserts \begin{env}...\end{env}
                LaTeXCompletion(
                    text: "\(env)}\n\n\\end{\(env)}",
                    displayText: env,
                    kind: .environment
                )
            }
    }

    // MARK: - Package Completions

    private func packageCompletions(partial: String) -> [LaTeXCompletion] {
        let packages = [
            "amsmath", "amssymb", "amsthm", "amsfonts",
            "graphicx", "xcolor", "hyperref", "geometry",
            "biblatex", "natbib", "cite",
            "booktabs", "multirow", "longtable", "tabularx",
            "listings", "minted", "algorithm2e", "algorithmicx",
            "tikz", "pgfplots", "pgfplotstable",
            "caption", "subcaption", "float", "wrapfig",
            "microtype", "fontspec", "unicode-math",
            "cleveref", "varioref",
            "siunitx", "chemformula",
            "inputenc", "babel", "polyglossia",
            "fancyhdr", "titlesec", "titling",
            "tcolorbox", "enumitem", "todonotes",
            "lipsum", "blindtext",
        ]

        return packages
            .filter { partial.isEmpty || $0.hasPrefix(partial) }
            .map { LaTeXCompletion(text: "\($0)}", displayText: $0, kind: .package) }
    }

    // MARK: - Command Completions

    private func commandCompletions(partial: String) -> [LaTeXCompletion] {
        let commands: [(String, String)] = [
            // Sectioning
            ("section{}", "section"),
            ("subsection{}", "subsection"),
            ("subsubsection{}", "subsubsection"),
            ("chapter{}", "chapter"),
            ("part{}", "part"),
            ("paragraph{}", "paragraph"),
            // Text formatting
            ("textbf{}", "textbf (bold)"),
            ("textit{}", "textit (italic)"),
            ("underline{}", "underline"),
            ("emph{}", "emph"),
            ("texttt{}", "texttt (monospace)"),
            ("textsc{}", "textsc (small caps)"),
            // References
            ("cite{}", "cite"),
            ("ref{}", "ref"),
            ("label{}", "label"),
            ("eqref{}", "eqref"),
            ("autoref{}", "autoref"),
            ("pageref{}", "pageref"),
            // Math
            ("frac{}{}", "frac"),
            ("sqrt{}", "sqrt"),
            ("sum", "sum"),
            ("prod", "prod"),
            ("int", "int"),
            ("partial", "partial"),
            ("nabla", "nabla"),
            ("infty", "infty"),
            ("alpha", "alpha"), ("beta", "beta"), ("gamma", "gamma"), ("delta", "delta"),
            ("epsilon", "epsilon"), ("theta", "theta"), ("lambda", "lambda"), ("mu", "mu"),
            ("pi", "pi"), ("sigma", "sigma"), ("omega", "omega"),
            // Environments
            ("begin{}", "begin"),
            ("end{}", "end"),
            // Structure
            ("usepackage{}", "usepackage"),
            ("documentclass{}", "documentclass"),
            ("input{}", "input"),
            ("include{}", "include"),
            ("bibliography{}", "bibliography"),
            ("title{}", "title"),
            ("author{}", "author"),
            ("date{}", "date"),
            ("maketitle", "maketitle"),
            ("tableofcontents", "tableofcontents"),
            // Floats
            ("caption{}", "caption"),
            ("includegraphics{}", "includegraphics"),
            ("centering", "centering"),
            // Lists
            ("item", "item"),
            // Spacing
            ("vspace{}", "vspace"),
            ("hspace{}", "hspace"),
            ("newline", "newline"),
            ("newpage", "newpage"),
            ("clearpage", "clearpage"),
            // Footnotes
            ("footnote{}", "footnote"),
            ("marginpar{}", "marginpar"),
        ]

        return commands
            .filter { partial.isEmpty || $0.0.hasPrefix(partial) }
            .prefix(20)
            .map { LaTeXCompletion(text: $0.0, displayText: $0.1, kind: .command) }
    }
}

/// A single auto-completion suggestion.
struct LaTeXCompletion: Identifiable {
    let id = UUID()
    var text: String          // Text to insert
    var displayText: String   // Text to show in completion list
    var kind: Kind

    enum Kind {
        case command, environment, citation, label, package
    }
}
