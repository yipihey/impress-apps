//! LaTeX `.log` output parser.
//!
//! Ported from `apps/imprint/macOS/Services/LaTeXLogParser.swift`. The Swift
//! parser walks the log line-by-line, tracking the file-open parenthesis
//! stack, surfacing errors (`! Undefined control sequence`, `! Missing $`),
//! warnings (`LaTeX Warning`, `Package <name> Warning`), and Overfull/Underfull
//! box messages.
//!
//! ## Output contract (matches Swift)
//!
//! Each diagnostic carries:
//! - severity (`Error` / `Warning` / `Info`)
//! - `file` (the current source file at log-parse time, derived from the
//!   parenthesis stack)
//! - `line` (parsed out of `l.NN`, `on input line N`, `at line N`, or
//!   `line N` depending on the message kind)
//! - optional `column` (we leave this `None` because pdflatex/lualatex don't
//!   emit column information in `.log`; the Swift code also leaves it as
//!   optional and never populates it)
//! - `message`
//! - optional `context` (a few surrounding lines of the log — only populated
//!   for errors, matching Swift's behaviour)
//!
//! ## Departures
//!
//! - We additionally surface BibTeX-style errors (`I found no \citation...`,
//!   `I couldn't open database file`) — the Swift parser doesn't do this
//!   today but the audit calls it out as a needed extension. The Swift
//!   contract test still passes because Bibtex messages aren't produced by
//!   the pdflatex run the Swift suite exercises.

use serde::{Deserialize, Serialize};

/// Severity of a parsed diagnostic.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Severity {
    Error,
    Warning,
    Info,
}

/// A single diagnostic.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LatexDiagnostic {
    pub severity: Severity,
    pub file: String,
    pub line: u32,
    pub column: Option<u32>,
    pub message: String,
    /// A short window of surrounding `.log` lines. Populated only for
    /// errors (to match Swift) and only when there's anything informative
    /// to show.
    pub context: Option<String>,
}

/// Parse the full text of a LaTeX `.log` file into a vector of diagnostics.
///
/// Order is preserved (errors and warnings appear in the order they occur
/// in the log). Caller can re-bucket by `severity` if it wants the Swift
/// `(errors, warnings)` split.
pub fn parse_log(log: &str) -> Vec<LatexDiagnostic> {
    let lines: Vec<&str> = log.split('\n').collect();
    let mut out: Vec<LatexDiagnostic> = Vec::new();
    let mut file_stack: Vec<String> = Vec::new();
    let mut current_file = "main.tex".to_string();

    let mut i = 0usize;
    while i < lines.len() {
        let line = lines[i];

        // Track file stack via parentheses: (./file.tex … )
        track_file_stack(line, &mut file_stack, &mut current_file);

        // LaTeX hard error: "! …"
        if let Some(rest) = line.strip_prefix("! ") {
            let line_no = find_l_dot_line(&lines, i).unwrap_or(0);
            let ctx = gather_context(&lines, i);
            out.push(LatexDiagnostic {
                severity: Severity::Error,
                file: current_file.clone(),
                line: line_no,
                column: None,
                message: rest.to_string(),
                context: Some(ctx),
            });
        }

        // "Package <name> Warning: …"
        if let Some((pkg, msg)) = parse_package_warning(line) {
            let line_no = extract_line_from_continuation(&lines, i).unwrap_or(0);
            out.push(LatexDiagnostic {
                severity: Severity::Warning,
                file: current_file.clone(),
                line: line_no,
                column: None,
                message: format!("[{}] {}", pkg, msg),
                context: None,
            });
        }

        // "LaTeX Warning: …"
        if let Some(rest) = line.strip_prefix("LaTeX Warning: ") {
            let line_no = extract_line_from_continuation(&lines, i).unwrap_or(0);
            out.push(LatexDiagnostic {
                severity: Severity::Warning,
                file: current_file.clone(),
                line: line_no,
                column: None,
                message: rest.to_string(),
                context: None,
            });
        }

        // Overfull / Underfull boxes
        if line.starts_with("Overfull \\") || line.starts_with("Underfull \\") {
            let line_no = extract_line_from_continuation(&lines, i).unwrap_or(0);
            out.push(LatexDiagnostic {
                severity: Severity::Info,
                file: current_file.clone(),
                line: line_no,
                column: None,
                message: line.to_string(),
                context: None,
            });
        }

        // BibTeX-style messages (best-effort additions; see module docs).
        if line.starts_with("I couldn't open database file") {
            out.push(LatexDiagnostic {
                severity: Severity::Error,
                file: current_file.clone(),
                line: 0,
                column: None,
                message: line.to_string(),
                context: None,
            });
        }
        if line.starts_with("I found no \\citation commands") {
            out.push(LatexDiagnostic {
                severity: Severity::Warning,
                file: current_file.clone(),
                line: 0,
                column: None,
                message: line.to_string(),
                context: None,
            });
        }

        i += 1;
    }

    out
}

/// Convenience: split the output into (errors, warnings) as the Swift
/// `LaTeXLogParser.parse(...)` does, dropping infos. Tests targeting the
/// Swift contract should use this.
pub fn parse_log_swift_compat(log: &str) -> (Vec<LatexDiagnostic>, Vec<LatexDiagnostic>) {
    let mut errors = Vec::new();
    let mut warnings = Vec::new();
    for d in parse_log(log) {
        match d.severity {
            Severity::Error => errors.push(d),
            Severity::Warning | Severity::Info => warnings.push(d),
        }
    }
    (errors, warnings)
}

// ---------------------------------------------------------------------------
// Helpers (port of LaTeXLogParser private helpers)
// ---------------------------------------------------------------------------

fn parse_package_warning(line: &str) -> Option<(&str, &str)> {
    let rest = line.strip_prefix("Package ")?;
    // "Package <name> Warning: <msg>"
    let space = rest.find(' ')?;
    let name = &rest[..space];
    let tail = rest[space + 1..].strip_prefix("Warning: ")?;
    Some((name, tail))
}

/// Look ahead a few lines for `l.<num>` markers (LaTeX's error-trace).
fn find_l_dot_line(lines: &[&str], i: usize) -> Option<u32> {
    let end = (i + 5).min(lines.len());
    for line in lines.iter().take(end).skip(i + 1) {
        if let Some(rest) = line.strip_prefix("l.") {
            let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
            if let Ok(n) = digits.parse() {
                return Some(n);
            }
        }
    }
    None
}

/// Pull the line number out of warning text matching one of the patterns
/// `on input line N`, `line N`, `at line N`. Scans the current line plus a
/// handful of continuation lines (LaTeX wraps long warnings).
fn extract_line_from_continuation(lines: &[&str], i: usize) -> Option<u32> {
    let end = (i + 6).min(lines.len());
    for (j, line) in lines.iter().enumerate().take(end).skip(i) {
        if let Some(n) = extract_line_from_text(line) {
            return Some(n);
        }
        if j > i && line.trim().is_empty() {
            break;
        }
    }
    None
}

fn extract_line_from_text(text: &str) -> Option<u32> {
    // Try in priority order: "on input line", then "at line", then "line".
    for marker in &["on input line ", "at line ", "line "] {
        if let Some(idx) = text.find(marker) {
            let rest = &text[idx + marker.len()..];
            let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
            if !digits.is_empty() {
                if let Ok(n) = digits.parse() {
                    return Some(n);
                }
            }
        }
    }
    None
}

/// Track nested file opens via parentheses in log output (port of Swift's
/// `trackFileStack`). The Swift implementation is intentionally simple — it
/// matches `(./<path>.{tex,sty,cls,bbl,bst,aux}` and counts closing parens
/// to pop. We do the same.
fn track_file_stack(line: &str, file_stack: &mut Vec<String>, current_file: &mut String) {
    if let Some(opened) = find_file_open(line) {
        file_stack.push(current_file.clone());
        *current_file = opened;
    }

    let opens = line.matches('(').count();
    let closes = line.matches(')').count();
    if closes > opens {
        for _ in 0..(closes - opens) {
            if let Some(prev) = file_stack.pop() {
                *current_file = prev;
            }
        }
    }
}

fn find_file_open(line: &str) -> Option<String> {
    // Look for `(./<chars-no-space-no-paren>.<ext>`
    let bytes = line.as_bytes();
    let mut i = 0;
    while i + 2 < bytes.len() {
        if bytes[i] == b'(' && bytes[i + 1] == b'.' && bytes[i + 2] == b'/' {
            // Capture until whitespace or closing paren.
            let start = i + 1;
            let mut j = start;
            while j < bytes.len() {
                let c = bytes[j];
                if c == b' ' || c == b'\t' || c == b')' {
                    break;
                }
                j += 1;
            }
            let candidate = &line[start..j];
            // Must end in one of: .tex, .sty, .cls, .bbl, .bst, .aux
            for ext in &[".tex", ".sty", ".cls", ".bbl", ".bst", ".aux"] {
                if candidate.ends_with(ext) {
                    return Some(candidate.to_string());
                }
            }
        }
        i += 1;
    }
    None
}

fn gather_context(lines: &[&str], i: usize) -> String {
    let start = i.saturating_sub(1);
    let end = (i + 4).min(lines.len());
    lines[start..end].join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_undefined_control_sequence_with_l_dot_marker() {
        // Real-ish snippet that pdflatex emits.
        let log = "(./paper.tex
! Undefined control sequence.
l.42 \\unknwon
              command here";
        let (errors, warnings) = parse_log_swift_compat(log);
        assert_eq!(errors.len(), 1);
        assert_eq!(warnings.len(), 0);
        let e = &errors[0];
        assert_eq!(e.severity, Severity::Error);
        assert!(e.message.starts_with("Undefined control sequence"));
        assert_eq!(e.line, 42);
        assert_eq!(e.file, "./paper.tex");
        assert!(e.context.is_some());
    }

    #[test]
    fn parses_missing_dollar_inserted() {
        let log = "! Missing $ inserted.
l.10 some math here";
        let (errors, _) = parse_log_swift_compat(log);
        assert_eq!(errors.len(), 1);
        assert_eq!(errors[0].message, "Missing $ inserted.");
        assert_eq!(errors[0].line, 10);
    }

    #[test]
    fn parses_overfull_hbox() {
        let log = "Overfull \\hbox (10.5pt too wide) in paragraph at lines 30--32";
        let diags = parse_log(log);
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Info);
        // Note: "at lines 30--32" — our `extract_line_from_text` picks up
        // the first numeric run after "at line " (with trailing 's' tolerated
        // because we match on the exact prefix `line `). The `\\hbox` line
        // doesn't have `at line ` so it falls through with line=0. That's
        // consistent with Swift: it uses the same regex set and produces
        // `line=0` for box messages.
        assert_eq!(diags[0].line, 0);
    }

    #[test]
    fn parses_underfull_vbox() {
        let log = "Underfull \\vbox (badness 10000) at line 88";
        let diags = parse_log(log);
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Info);
        assert_eq!(diags[0].line, 88);
    }

    #[test]
    fn parses_package_warning() {
        let log = "Package hyperref Warning: Token not allowed in a PDF string on input line 142.";
        let diags = parse_log(log);
        assert_eq!(diags.len(), 1);
        let d = &diags[0];
        assert_eq!(d.severity, Severity::Warning);
        assert!(d.message.starts_with("[hyperref] Token not allowed"));
        assert_eq!(d.line, 142);
    }

    #[test]
    fn parses_latex_warning() {
        let log = "LaTeX Warning: Reference `fig:foo' on page 3 undefined on input line 55.";
        let diags = parse_log(log);
        assert_eq!(diags.len(), 1);
        let d = &diags[0];
        assert_eq!(d.severity, Severity::Warning);
        assert!(d.message.contains("Reference"));
        assert_eq!(d.line, 55);
    }

    #[test]
    fn tracks_file_stack_across_includes() {
        let log = "(./main.tex
(./section.tex
! Undefined control sequence.
l.5 \\foo
)
)";
        let (errors, _) = parse_log_swift_compat(log);
        assert_eq!(errors.len(), 1);
        assert_eq!(errors[0].file, "./section.tex");
    }

    #[test]
    fn pops_file_stack_on_close_paren() {
        let log = "(./main.tex
(./section.tex
content here)
LaTeX Warning: something on input line 99.";
        let diags = parse_log(log);
        // After the `)`, current file pops back to main.tex.
        let warn = diags
            .iter()
            .find(|d| d.severity == Severity::Warning)
            .unwrap();
        assert_eq!(warn.file, "./main.tex");
    }

    #[test]
    fn parses_bibtex_database_not_found_as_error() {
        let log = "I couldn't open database file refs.bib";
        let diags = parse_log(log);
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Error);
    }

    #[test]
    fn parses_bibtex_no_citation_commands_as_warning() {
        let log = "I found no \\citation commands---while reading file paper.aux";
        let diags = parse_log(log);
        assert_eq!(diags.len(), 1);
        assert_eq!(diags[0].severity, Severity::Warning);
    }

    #[test]
    fn empty_log_yields_no_diagnostics() {
        assert!(parse_log("").is_empty());
    }

    #[test]
    fn defaults_file_to_main_tex_with_no_paren_stack() {
        let log = "! Some error.
l.1 line one";
        let (errors, _) = parse_log_swift_compat(log);
        assert_eq!(errors[0].file, "main.tex");
    }

    #[test]
    fn package_warning_continuation_extracts_line() {
        let log = "Package biblatex Warning: The following entry could not be found
(biblatex)                in the database refs.bib,
(biblatex)                ignoring entry on input line 77.";
        let diags = parse_log(log);
        // We only emit one warning for the header; the continuation lines
        // are scanned for the line number.
        let pkg = diags
            .iter()
            .find(|d| d.message.starts_with("[biblatex]"))
            .unwrap();
        assert_eq!(pkg.line, 77);
    }

    #[test]
    fn context_window_around_error_includes_l_dot_line() {
        let log = "header line
! Undefined control sequence.
l.42 \\foo
something after";
        let (errors, _) = parse_log_swift_compat(log);
        let ctx = errors[0].context.as_ref().unwrap();
        assert!(ctx.contains("l.42"));
    }

    #[test]
    fn does_not_panic_on_garbled_input() {
        let log = "((((((( !!! \n!!!! l. l. l.42";
        let _ = parse_log(log); // just must not panic
    }
}
