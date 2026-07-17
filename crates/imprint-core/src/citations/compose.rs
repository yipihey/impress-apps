//! Section source-text composition — the inverse of [`super::extract`].
//!
//! Format-specific string building for inserting citations and headings into a
//! manuscript. Ported from the Swift `ImprintHTTPRouter` helpers
//! `composeCitation` and `composeHeading` so this logic lives in Rust once and
//! is shared by the app (via UniFFI), MCP, CLI, and the self-test harness —
//! and can no longer drift between Swift and Rust.

/// Which markup a manuscript uses. Composition only distinguishes Typst from
/// LaTeX (unlike extraction, which also has a "mixed" mode).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ComposeFormat {
    Typst,
    Latex,
}

impl ComposeFormat {
    /// Lenient parse: `latex`/`tex` → LaTeX, everything else → Typst (the
    /// default authoring format for imprint).
    pub fn from_str_lenient(s: &str) -> Self {
        match s.to_ascii_lowercase().as_str() {
            "latex" | "tex" => ComposeFormat::Latex,
            _ => ComposeFormat::Typst,
        }
    }
}

/// Compose an inline citation token. Typst → `@key`, LaTeX → `\cite{key}`.
///
/// When `append_space` is true a single leading space is prepended, matching
/// the Swift router's behavior when inserting a citation after existing text.
pub fn compose_citation(cite_key: &str, format: ComposeFormat, append_space: bool) -> String {
    let token = match format {
        ComposeFormat::Typst => format!("@{cite_key}"),
        ComposeFormat::Latex => format!("\\cite{{{cite_key}}}"),
    };
    if append_space {
        format!(" {token}")
    } else {
        token
    }
}

/// Compose a heading line at `level` (1-based).
///
/// Typst uses `level` `=` characters (clamped to 1..=6). LaTeX maps
/// 1→`\section`, 2→`\subsection`, 3→`\subsubsection`, 4→`\paragraph`, and
/// anything else (including 0) →`\subparagraph`, matching the Swift router.
pub fn compose_heading(title: &str, level: u32, format: ComposeFormat) -> String {
    match format {
        ComposeFormat::Typst => {
            let depth = level.clamp(1, 6) as usize;
            format!("{} {title}", "=".repeat(depth))
        }
        ComposeFormat::Latex => match level {
            1 => format!("\\section{{{title}}}"),
            2 => format!("\\subsection{{{title}}}"),
            3 => format!("\\subsubsection{{{title}}}"),
            4 => format!("\\paragraph{{{title}}}"),
            _ => format!("\\subparagraph{{{title}}}"),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn citation_typst() {
        assert_eq!(
            compose_citation("einstein1905", ComposeFormat::Typst, false),
            "@einstein1905"
        );
        assert_eq!(
            compose_citation("einstein1905", ComposeFormat::Typst, true),
            " @einstein1905"
        );
    }

    #[test]
    fn citation_latex() {
        assert_eq!(
            compose_citation("knuth1984", ComposeFormat::Latex, false),
            "\\cite{knuth1984}"
        );
        assert_eq!(
            compose_citation("knuth1984", ComposeFormat::Latex, true),
            " \\cite{knuth1984}"
        );
    }

    #[test]
    fn heading_typst_levels() {
        assert_eq!(compose_heading("Intro", 1, ComposeFormat::Typst), "= Intro");
        assert_eq!(compose_heading("Sub", 2, ComposeFormat::Typst), "== Sub");
        // Clamp: level 0 → 1 `=`, level 9 → 6 `=`.
        assert_eq!(compose_heading("Zero", 0, ComposeFormat::Typst), "= Zero");
        assert_eq!(
            compose_heading("Deep", 9, ComposeFormat::Typst),
            "====== Deep"
        );
    }

    #[test]
    fn heading_latex_levels() {
        assert_eq!(
            compose_heading("A", 1, ComposeFormat::Latex),
            "\\section{A}"
        );
        assert_eq!(
            compose_heading("B", 2, ComposeFormat::Latex),
            "\\subsection{B}"
        );
        assert_eq!(
            compose_heading("C", 3, ComposeFormat::Latex),
            "\\subsubsection{C}"
        );
        assert_eq!(
            compose_heading("D", 4, ComposeFormat::Latex),
            "\\paragraph{D}"
        );
        assert_eq!(
            compose_heading("E", 5, ComposeFormat::Latex),
            "\\subparagraph{E}"
        );
        assert_eq!(
            compose_heading("Z", 0, ComposeFormat::Latex),
            "\\subparagraph{Z}"
        );
    }

    #[test]
    fn format_parse_is_lenient() {
        assert_eq!(
            ComposeFormat::from_str_lenient("LaTeX"),
            ComposeFormat::Latex
        );
        assert_eq!(ComposeFormat::from_str_lenient("tex"), ComposeFormat::Latex);
        assert_eq!(
            ComposeFormat::from_str_lenient("typst"),
            ComposeFormat::Typst
        );
        assert_eq!(
            ComposeFormat::from_str_lenient("nonsense"),
            ComposeFormat::Typst
        );
    }
}
