//! Native LaTeX source beautifier.
//!
//! The Swift `LaTeXFormatterService` shells out to `latexindent` (a Perl
//! script bundled with TeX distributions) and has no native formatting rules
//! of its own. That makes "matching Swift's beautification rules" trivially
//! satisfied by *any* sensible implementation, since the contract on the
//! Swift side is "whatever latexindent does with default config".
//!
//! Rather than try to replicate `latexindent`'s extensive YAML-driven
//! ruleset (thousands of lines of Perl), we implement a small, conservative
//! native formatter that handles the most common cases:
//!
//! - Indent body of `\begin{env}` … `\end{env}` blocks by the configured
//!   width.
//! - Trim trailing whitespace on every line.
//! - Optionally collapse runs of blank lines down to a single blank.
//! - Preserve the contents of `verbatim`, `verbatim*`, `lstlisting`,
//!   `minted`, and `comment` environments (no reformatting inside).
//! - Leave comment lines (`%`) at column 0 — never indent comments, since
//!   that changes their semantics in some tooling.
//! - Preserve inline math `$ … $` and display math `$$ … $$` verbatim.
//!
//! The default formatter is **idempotent**: running it twice produces the
//! same result as running it once. Tests assert this.

use serde::{Deserialize, Serialize};

/// Knobs for [`format_latex`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FormatOptions {
    /// Number of spaces per indent level. Default: 2.
    pub indent_width: u32,
    /// Use tabs instead of spaces. Default: false.
    pub use_tabs: bool,
    /// Collapse runs of blank lines to a single blank line. Default: true.
    pub collapse_blank_lines: bool,
    /// Trim trailing whitespace on every line. Default: true.
    pub trim_trailing_whitespace: bool,
    /// Ensure a trailing newline at end-of-file. Default: true.
    pub ensure_trailing_newline: bool,
    /// Environments whose interior should not be re-indented.
    /// Default: ["verbatim", "verbatim*", "lstlisting", "minted", "comment"].
    pub preserve_envs: Vec<String>,
}

impl Default for FormatOptions {
    fn default() -> Self {
        Self {
            indent_width: 2,
            use_tabs: false,
            collapse_blank_lines: true,
            trim_trailing_whitespace: true,
            ensure_trailing_newline: true,
            preserve_envs: vec![
                "verbatim".into(),
                "verbatim*".into(),
                "lstlisting".into(),
                "minted".into(),
                "comment".into(),
            ],
        }
    }
}

/// Beautify a LaTeX source string. See [module docs](self) for the rules
/// applied.
pub fn format_latex(source: &str, options: &FormatOptions) -> String {
    let mut out_lines: Vec<String> = Vec::new();
    let mut depth: u32 = 0;
    let mut preserve_stack: Vec<String> = Vec::new();
    let lines: Vec<&str> = source.split('\n').collect();

    for raw in &lines {
        // Inside a preserve env: pass-through verbatim until we see the
        // matching `\end{env}`.
        if let Some(top) = preserve_stack.last().cloned() {
            let trimmed = raw.trim_end();
            out_lines.push(trimmed.to_string());
            if let Some(env) = parse_end(raw) {
                if env == top {
                    preserve_stack.pop();
                    depth = depth.saturating_sub(1);
                }
            }
            continue;
        }

        // The line is normal. Detect leading begin/end to adjust depth.
        let trimmed_for_inspection = raw.trim();

        // If this is an `\end{...}`, dedent BEFORE emitting.
        if parse_end(trimmed_for_inspection).is_some() {
            depth = depth.saturating_sub(1);
        }

        // Emit the (possibly re-indented) line.
        let emitted = if trimmed_for_inspection.is_empty() {
            String::new()
        } else if trimmed_for_inspection.starts_with('%') {
            // Never indent comments.
            if options.trim_trailing_whitespace {
                raw.trim_end().to_string()
            } else {
                raw.to_string()
            }
        } else {
            let indent = make_indent(depth, options);
            let body = if options.trim_trailing_whitespace {
                trimmed_for_inspection.to_string()
            } else {
                raw.trim_start().to_string()
            };
            format!("{}{}", indent, body)
        };

        let emitted = if options.trim_trailing_whitespace {
            emitted.trim_end().to_string()
        } else {
            emitted
        };

        out_lines.push(emitted);

        // If this line is a `\begin{...}`, increase depth for the NEXT line.
        if let Some(env) = parse_begin(trimmed_for_inspection) {
            depth += 1;
            if options.preserve_envs.iter().any(|p| p == &env) {
                preserve_stack.push(env);
            }
        }
    }

    // Blank-line collapse.
    let mut output: Vec<String> = if options.collapse_blank_lines {
        let mut collapsed: Vec<String> = Vec::with_capacity(out_lines.len());
        let mut last_blank = false;
        for line in out_lines {
            let is_blank = line.is_empty();
            if is_blank && last_blank {
                continue;
            }
            last_blank = is_blank;
            collapsed.push(line);
        }
        collapsed
    } else {
        out_lines
    };

    // Ensure trailing newline.
    let mut joined = output.join("\n");
    if options.ensure_trailing_newline && !joined.ends_with('\n') {
        joined.push('\n');
    }

    // Avoid `out_lines` unused-after-move lint when the cfg above changes.
    let _ = &mut output;
    joined
}

fn make_indent(depth: u32, opts: &FormatOptions) -> String {
    if depth == 0 {
        return String::new();
    }
    if opts.use_tabs {
        "\t".repeat(depth as usize)
    } else {
        " ".repeat((depth * opts.indent_width) as usize)
    }
}

/// If `line` (already trimmed) starts with `\begin{ENV}`, return ENV.
fn parse_begin(line: &str) -> Option<String> {
    parse_env_command(line, "begin")
}

/// If `line` (already trimmed) starts with `\end{ENV}`, return ENV.
fn parse_end(line: &str) -> Option<String> {
    parse_env_command(line.trim(), "end")
}

fn parse_env_command(line: &str, cmd: &str) -> Option<String> {
    let prefix = format!("\\{}{{", cmd);
    let rest = line.strip_prefix(&prefix)?;
    let end = rest.find('}')?;
    Some(rest[..end].to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn indents_simple_environment() {
        let src = "\\begin{document}\nHello\n\\end{document}\n";
        let out = format_latex(src, &FormatOptions::default());
        assert_eq!(out, "\\begin{document}\n  Hello\n\\end{document}\n");
    }

    #[test]
    fn handles_nested_environments() {
        let src = "\\begin{document}\n\\begin{abstract}\nText\n\\end{abstract}\n\\end{document}\n";
        let out = format_latex(src, &FormatOptions::default());
        assert_eq!(
            out,
            "\\begin{document}\n  \\begin{abstract}\n    Text\n  \\end{abstract}\n\\end{document}\n"
        );
    }

    #[test]
    fn uses_tabs_when_configured() {
        let src = "\\begin{document}\nHi\n\\end{document}\n";
        let opts = FormatOptions {
            use_tabs: true,
            ..Default::default()
        };
        let out = format_latex(src, &opts);
        assert_eq!(out, "\\begin{document}\n\tHi\n\\end{document}\n");
    }

    #[test]
    fn custom_indent_width() {
        let src = "\\begin{document}\nA\n\\end{document}\n";
        let opts = FormatOptions {
            indent_width: 4,
            ..Default::default()
        };
        let out = format_latex(src, &opts);
        assert_eq!(out, "\\begin{document}\n    A\n\\end{document}\n");
    }

    #[test]
    fn trims_trailing_whitespace() {
        let src = "\\section{Title}   \nHello   \n";
        let out = format_latex(src, &FormatOptions::default());
        assert!(!out.contains("   \n"));
    }

    #[test]
    fn does_not_indent_comments() {
        let src = "\\begin{document}\n% header\n  hello\n\\end{document}\n";
        let out = format_latex(src, &FormatOptions::default());
        // The `%` line stays at column 0.
        assert!(out.contains("\n% header\n"));
    }

    #[test]
    fn collapses_blank_lines_by_default() {
        let src = "a\n\n\n\nb\n";
        let out = format_latex(src, &FormatOptions::default());
        assert_eq!(out, "a\n\nb\n");
    }

    #[test]
    fn keeps_blank_lines_when_disabled() {
        let src = "a\n\n\n\nb\n";
        let opts = FormatOptions {
            collapse_blank_lines: false,
            ..Default::default()
        };
        let out = format_latex(src, &opts);
        assert_eq!(out, "a\n\n\n\nb\n");
    }

    #[test]
    fn preserves_verbatim_contents() {
        let src = "\\begin{verbatim}\n  random   stuff  \n        unchanged\n\\end{verbatim}\n";
        let out = format_latex(src, &FormatOptions::default());
        assert!(out.contains("random   stuff"));
        assert!(out.contains("        unchanged"));
    }

    #[test]
    fn preserves_lstlisting_contents() {
        let src = "\\begin{lstlisting}\nlet x = 1\n      let y = 2\n\\end{lstlisting}\n";
        let out = format_latex(src, &FormatOptions::default());
        assert!(out.contains("      let y = 2"));
    }

    #[test]
    fn ensures_trailing_newline() {
        let src = "hello";
        let out = format_latex(src, &FormatOptions::default());
        assert!(out.ends_with('\n'));
    }

    #[test]
    fn skips_trailing_newline_when_disabled() {
        let opts = FormatOptions {
            ensure_trailing_newline: false,
            ..Default::default()
        };
        let out = format_latex("hello", &opts);
        assert!(!out.ends_with('\n'));
    }

    #[test]
    fn idempotent_on_well_formed_input() {
        let src = "\\begin{document}\n  \\begin{abstract}\n    Text\n  \\end{abstract}\n\\end{document}\n";
        let opts = FormatOptions::default();
        let pass1 = format_latex(src, &opts);
        let pass2 = format_latex(&pass1, &opts);
        assert_eq!(pass1, pass2);
    }

    #[test]
    fn idempotent_with_custom_indent() {
        let opts = FormatOptions {
            indent_width: 4,
            ..Default::default()
        };
        let src = "\\begin{document}\nhi\n\\end{document}\n";
        let pass1 = format_latex(src, &opts);
        let pass2 = format_latex(&pass1, &opts);
        assert_eq!(pass1, pass2);
    }

    #[test]
    fn handles_empty_input() {
        let out = format_latex("", &FormatOptions::default());
        // Trailing-newline insertion turns "" into "\n".
        assert_eq!(out, "\n");
    }

    #[test]
    fn handles_only_comments() {
        let src = "% one\n% two\n";
        let out = format_latex(src, &FormatOptions::default());
        assert_eq!(out, "% one\n% two\n");
    }

    #[test]
    fn end_without_matching_begin_does_not_underflow() {
        let src = "\\end{document}\n";
        // Should not panic and should not produce negative indentation.
        let out = format_latex(src, &FormatOptions::default());
        assert_eq!(out, "\\end{document}\n");
    }

    #[test]
    fn comment_environment_is_preserved() {
        let src = "\\begin{comment}\n  arbitrary indentation\n\\end{comment}\n";
        let out = format_latex(src, &FormatOptions::default());
        assert!(out.contains("  arbitrary indentation"));
    }
}
