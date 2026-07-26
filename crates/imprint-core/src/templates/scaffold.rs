//! Starter-document generation from a template.
//!
//! A built-in template's `typst_source` is *only* a style definition: it declares
//! a single `#let <name>(...) = { ... }` show-function and ends with a comment
//! like `// Usage: #show: apj.with(...)`. Compiling that source on its own is
//! valid Typst but produces a single blank page — the show-function it declares
//! is never invoked, so nothing is ever rendered.
//!
//! "Start a new manuscript from the ApJ template" therefore needs one more step:
//! emit the style definition *plus* the `#show:` invocation *plus* a body
//! skeleton. That is what [`scaffold_document`] does. The parameter list of each
//! template differs (some take `keywords`, some take `summary` instead of
//! `abstract`, some take neither), so the show-rule arguments are derived by
//! parsing the template's own function signature rather than being hardcoded.

use super::Template;

/// Values used to seed a new document created from a template.
#[derive(Debug, Clone, Default)]
pub struct ScaffoldOptions {
    /// Manuscript title.
    pub title: String,
    /// Author names, in order.
    pub authors: Vec<String>,
    /// Affiliation strings, in order; referenced by superscript index.
    pub affiliations: Vec<String>,
    /// Abstract text (also used for templates whose parameter is `summary`).
    pub abstract_text: Option<String>,
    /// Keywords, for templates that accept them.
    pub keywords: Vec<String>,
    /// Whether to append a standard section skeleton to the body.
    pub include_sections: bool,
}

impl ScaffoldOptions {
    /// Options with only a title set, and the section skeleton enabled.
    pub fn with_title(title: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            include_sections: true,
            ..Default::default()
        }
    }
}

/// Name of the show-function a template defines (e.g. `apj`, or `article` for
/// the `generic` template). Returns `None` if the source declares no `#let f(`.
pub fn show_function_name(source: &str) -> Option<String> {
    for line in source.lines() {
        let Some(rest) = line.trim_start().strip_prefix("#let ") else {
            continue;
        };
        let name: String = rest
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect();
        if !name.is_empty() && rest[name.len()..].starts_with('(') {
            return Some(name);
        }
    }
    None
}

/// Parameter names accepted by a template's show-function, in declaration order.
///
/// Parses from the `#let name(` line up to the matching `) = {`, taking the
/// identifier before each `:` (and bare positional parameters such as `body`).
pub fn template_parameters(source: &str) -> Vec<String> {
    let mut params = Vec::new();
    let mut in_signature = false;

    for line in source.lines() {
        let trimmed = line.trim();
        if !in_signature {
            if trimmed.starts_with("#let ") && trimmed.ends_with('(') {
                in_signature = true;
            }
            continue;
        }
        if trimmed.starts_with(')') {
            break;
        }
        let ident = trimmed
            .split(':')
            .next()
            .unwrap_or("")
            .trim_end_matches(',')
            .trim();
        if !ident.is_empty() && ident.chars().all(|c| c.is_alphanumeric() || c == '_') {
            params.push(ident.to_string());
        }
    }

    params
}

/// Escape a plain string so it is safe inside a Typst markup content block.
fn escape_markup(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 8);
    for ch in text.chars() {
        match ch {
            '\\' | '#' | '$' | '[' | ']' | '*' | '_' | '@' | '<' | '>' | '~' | '`' | '\'' | '"' => {
                out.push('\\');
                out.push(ch);
            }
            _ => out.push(ch),
        }
    }
    out
}

/// Escape a plain string so it is safe inside a Typst double-quoted string.
fn escape_string(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 4);
    for ch in text.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            _ => out.push(ch),
        }
    }
    out
}

/// Render a Typst array literal of strings. A single-element array needs the
/// trailing comma or Typst reads it as a parenthesised expression.
fn typst_string_array(values: &[String]) -> String {
    if values.is_empty() {
        return "()".to_string();
    }
    let items: Vec<String> = values
        .iter()
        .map(|v| format!("\"{}\"", escape_string(v)))
        .collect();
    if items.len() == 1 {
        format!("({},)", items[0])
    } else {
        format!("({})", items.join(", "))
    }
}

const DEFAULT_SECTIONS: &[(&str, &str)] = &[
    (
        "Introduction",
        "Motivate the problem and summarise the contribution.",
    ),
    ("Methods", "Describe the data, model, and analysis."),
    ("Results", "Present the findings."),
    ("Discussion", "Interpret the results and note limitations."),
    ("Conclusions", "State the take-away."),
];

/// Build a complete, compilable Typst document from a template.
///
/// The output is the template's own style definition, followed by a
/// `#show: <name>.with(...)` invocation carrying only the arguments the template
/// actually declares, followed by an optional section skeleton.
pub fn scaffold_document(template: &Template, options: &ScaffoldOptions) -> String {
    let source = &template.typst_source;
    let params = template_parameters(source);

    let mut out = String::with_capacity(source.len() + 1024);
    out.push_str(source);
    if !out.ends_with('\n') {
        out.push('\n');
    }
    out.push('\n');

    let title = if options.title.trim().is_empty() {
        "Untitled Manuscript"
    } else {
        options.title.trim()
    };

    match show_function_name(source) {
        Some(func) => {
            let has = |p: &str| params.iter().any(|x| x == p);
            let mut args: Vec<String> = Vec::new();

            if has("title") {
                args.push(format!("  title: [{}],", escape_markup(title)));
            }
            if has("authors") {
                args.push(format!(
                    "  authors: {},",
                    typst_string_array(&options.authors)
                ));
            }
            if has("affiliations") {
                args.push(format!(
                    "  affiliations: {},",
                    typst_string_array(&options.affiliations)
                ));
            }

            // `abstract` and `summary` are the same slot; Cell and Lancet use
            // the latter. Fill whichever the template declares.
            let abstract_body = options
                .abstract_text
                .as_deref()
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .unwrap_or("Summarise the work in a paragraph.");
            for slot in ["abstract", "summary"] {
                if has(slot) {
                    args.push(format!("  {}: [{}],", slot, escape_markup(abstract_body)));
                }
            }

            if has("keywords") {
                args.push(format!(
                    "  keywords: {},",
                    typst_string_array(&options.keywords)
                ));
            }

            out.push_str("// Document configuration — edit these values.\n");
            out.push_str(&format!("#show: {}.with(\n", func));
            for arg in &args {
                out.push_str(arg);
                out.push('\n');
            }
            out.push_str(")\n\n");
        }
        None => {
            // A template that is already a whole document rather than a style
            // definition: fall back to a plain heading so the title is not lost.
            out.push_str(&format!("= {}\n\n", escape_markup(title)));
        }
    }

    if options.include_sections {
        for (heading, hint) in DEFAULT_SECTIONS {
            out.push_str(&format!("= {}\n\n{}\n\n", heading, hint));
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::templates::TemplateRegistry;

    #[test]
    fn test_show_function_name_matches_known_templates() {
        let registry = TemplateRegistry::new();
        let generic = registry.get("generic").unwrap();
        assert_eq!(
            show_function_name(&generic.typst_source).as_deref(),
            Some("article")
        );
        let apj = registry.get("apj").unwrap();
        assert_eq!(
            show_function_name(&apj.typst_source).as_deref(),
            Some("apj")
        );
    }

    #[test]
    fn test_every_builtin_declares_a_show_function() {
        let registry = TemplateRegistry::new();
        for template in registry.list() {
            assert!(
                show_function_name(&template.typst_source).is_some(),
                "template '{}' declares no #let show-function",
                template.id()
            );
            let params = template_parameters(&template.typst_source);
            assert!(
                params.iter().any(|p| p == "body"),
                "template '{}' show-function takes no `body` parameter (params: {:?})",
                template.id(),
                params
            );
        }
    }

    #[test]
    fn test_apj_parameters() {
        let registry = TemplateRegistry::new();
        let apj = registry.get("apj").unwrap();
        let params = template_parameters(&apj.typst_source);
        assert_eq!(
            params,
            vec![
                "title",
                "authors",
                "affiliations",
                "abstract",
                "keywords",
                "body"
            ]
        );
    }

    #[test]
    fn test_scaffold_emits_show_rule() {
        let registry = TemplateRegistry::new();
        let apj = registry.get("apj").unwrap();
        let mut opts = ScaffoldOptions::with_title("A Test of Something");
        opts.authors = vec!["Jane Doe".to_string()];
        opts.affiliations = vec!["Stanford University".to_string()];

        let doc = scaffold_document(apj, &opts);
        assert!(doc.contains("#show: apj.with("));
        assert!(doc.contains("title: [A Test of Something]"));
        assert!(doc.contains("authors: (\"Jane Doe\",)"));
        assert!(doc.contains("= Introduction"));
        // The style definition is still present.
        assert!(doc.contains("#let apj("));
    }

    #[test]
    fn test_scaffold_omits_undeclared_arguments() {
        let registry = TemplateRegistry::new();
        // PRL declares no `keywords` parameter.
        let prl = registry.get("prl").unwrap();
        let params = template_parameters(&prl.typst_source);
        assert!(!params.iter().any(|p| p == "keywords"));

        let mut opts = ScaffoldOptions::with_title("Title");
        opts.keywords = vec!["one".to_string()];
        let doc = scaffold_document(prl, &opts);
        assert!(
            !doc.contains("  keywords:"),
            "must not pass keywords to a template that does not declare it"
        );
    }

    #[test]
    fn test_scaffold_uses_summary_slot_when_present() {
        let registry = TemplateRegistry::new();
        let cell = registry.get("cell").unwrap();
        let mut opts = ScaffoldOptions::with_title("Title");
        opts.abstract_text = Some("The point of the paper.".to_string());
        let doc = scaffold_document(cell, &opts);
        assert!(doc.contains("summary: [The point of the paper.]"));
    }

    #[test]
    fn test_escape_markup_neutralises_typst_syntax() {
        let escaped = escape_markup("Cost #1 [bracket] *star* $math$");
        assert!(!escaped.contains("$math$"));
        assert!(escaped.contains("\\#1"));
        assert!(escaped.contains("\\[bracket\\]"));
    }
}
