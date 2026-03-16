/// Standard `.gitignore` patterns for LaTeX/Typst projects.
pub fn latex_gitignore() -> &'static str {
    r#"# LaTeX build artifacts
*.aux
*.bbl
*.blg
*.fdb_latexmk
*.fls
*.log
*.out
*.synctex.gz
*.synctex(busy)
*.toc
*.lof
*.lot
*.nav
*.snm
*.vrb
*.bcf
*.run.xml
*.xdv

# BibTeX/Biber
*.bib.bak

# Typst build artifacts
*.typ.pdf

# Build directories
.build/
build/
_build/
out/

# Editor files
*.swp
*.swo
*~
.DS_Store
.vscode/
.idea/

# imprint project files (local state)
.imprint-local/
"#
}

/// Return patterns from `latex_gitignore()` that are missing from `existing`.
pub fn needs_update(existing: &str) -> Vec<&'static str> {
    let essential_patterns = [
        "*.aux",
        "*.bbl",
        "*.blg",
        "*.fdb_latexmk",
        "*.fls",
        "*.log",
        "*.out",
        "*.synctex.gz",
        "*.toc",
        ".build/",
        ".DS_Store",
    ];

    let existing_lines: Vec<&str> = existing
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .collect();

    essential_patterns
        .iter()
        .filter(|p| !existing_lines.contains(p))
        .copied()
        .collect()
}

/// Merge additional patterns into an existing `.gitignore` file.
///
/// Appends a clearly marked section so the user can see what was added.
pub fn merge_gitignore(existing: &str, additions: &[&str]) -> String {
    if additions.is_empty() {
        return existing.to_string();
    }

    let mut result = existing.to_string();
    if !result.ends_with('\n') {
        result.push('\n');
    }
    result.push_str("\n# Added by impress\n");
    for pattern in additions {
        result.push_str(pattern);
        result.push('\n');
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn latex_gitignore_has_essential_patterns() {
        let content = latex_gitignore();
        assert!(content.contains("*.aux"));
        assert!(content.contains("*.log"));
        assert!(content.contains("*.synctex.gz"));
        assert!(content.contains(".DS_Store"));
        assert!(content.contains(".build/"));
    }

    #[test]
    fn needs_update_detects_missing() {
        let existing = "*.aux\n*.log\n";
        let missing = needs_update(existing);
        assert!(missing.contains(&"*.bbl"));
        assert!(missing.contains(&"*.synctex.gz"));
        assert!(!missing.contains(&"*.aux"));
        assert!(!missing.contains(&"*.log"));
    }

    #[test]
    fn needs_update_complete_file_has_nothing() {
        let complete = latex_gitignore();
        let missing = needs_update(complete);
        assert!(missing.is_empty());
    }

    #[test]
    fn merge_gitignore_appends_section() {
        let existing = "*.aux\n*.log\n";
        let additions = vec!["*.bbl", "*.synctex.gz"];
        let result = merge_gitignore(existing, &additions);
        assert!(result.contains("# Added by impress"));
        assert!(result.contains("*.bbl\n"));
        assert!(result.contains("*.synctex.gz\n"));
        assert!(result.starts_with("*.aux\n"));
    }

    #[test]
    fn merge_gitignore_empty_additions() {
        let existing = "*.aux\n";
        let result = merge_gitignore(existing, &[]);
        assert_eq!(result, existing);
    }

    #[test]
    fn needs_update_ignores_comments() {
        let existing = "# *.aux\n# *.log\n";
        let missing = needs_update(existing);
        // Comments don't count — patterns are still missing
        assert!(missing.contains(&"*.aux"));
        assert!(missing.contains(&"*.log"));
    }
}
