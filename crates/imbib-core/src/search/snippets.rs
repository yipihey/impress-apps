//! Search result snippet generation

/// Extract a snippet around query terms
#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_snippet(text: &str, query_terms: &[String], context_chars: u32) -> Option<String> {
    let context_chars = context_chars as usize;
    let text_lower = text.to_lowercase();

    // Find first matching term
    let mut best_pos: Option<usize> = None;
    for term in query_terms {
        if let Some(pos) = text_lower.find(&term.to_lowercase()) {
            if best_pos.is_none() || pos < best_pos.unwrap() {
                best_pos = Some(pos);
            }
        }
    }

    let pos = best_pos?;

    // Calculate snippet boundaries
    let start = if pos > context_chars {
        // Find word boundary
        let search_start = pos - context_chars;
        text[search_start..pos]
            .rfind(char::is_whitespace)
            .map(|p| search_start + p + 1)
            .unwrap_or(search_start)
    } else {
        0
    };

    let end = if pos + context_chars < text.len() {
        let search_end = pos + context_chars;
        text[pos..search_end]
            .find(char::is_whitespace)
            .map(|p| pos + p)
            .unwrap_or(search_end)
    } else {
        text.len()
    };

    let mut snippet = String::new();

    if start > 0 {
        snippet.push_str("...");
    }

    snippet.push_str(text[start..end].trim());

    if end < text.len() {
        snippet.push_str("...");
    }

    Some(snippet)
}

/// Highlight query terms in text
#[cfg(feature = "native")]
#[uniffi::export]
pub fn highlight_terms(
    text: &str,
    query_terms: &[String],
    highlight_start: &str,
    highlight_end: &str,
) -> String {
    let mut result = text.to_string();

    for term in query_terms {
        let term_lower = term.to_lowercase();
        let mut offset = 0;

        while let Some(pos) = result[offset..].to_lowercase().find(&term_lower) {
            let absolute_pos = offset + pos;
            let term_len = term.len();

            // Preserve original case
            let original = &result[absolute_pos..absolute_pos + term_len];
            let highlighted = format!("{}{}{}", highlight_start, original, highlight_end);

            result.replace_range(absolute_pos..absolute_pos + term_len, &highlighted);

            offset = absolute_pos + highlighted.len();
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_snippet() {
        let text = "This is a long text about quantum mechanics and special relativity theory.";
        let terms = vec!["quantum".to_string()];

        let snippet = extract_snippet(text, &terms, 20).unwrap();
        assert!(snippet.contains("quantum"));
    }

    #[test]
    fn test_highlight_terms() {
        let text = "The quantum theory explains quantum mechanics.";
        let terms = vec!["quantum".to_string()];

        let highlighted = highlight_terms(text, &terms, "<b>", "</b>");
        assert!(highlighted.contains("<b>quantum</b>"));
        assert_eq!(highlighted.matches("<b>").count(), 2);
    }

    #[test]
    fn test_extract_snippet_at_start() {
        let text = "Quantum mechanics is fascinating.";
        let terms = vec!["quantum".to_string()];

        let snippet = extract_snippet(text, &terms, 20).unwrap();
        assert!(snippet.starts_with("Quantum"));
    }

    #[test]
    fn test_extract_snippet_at_end() {
        let text = "The study of physics including quantum";
        let terms = vec!["quantum".to_string()];

        let snippet = extract_snippet(text, &terms, 15).unwrap();
        assert!(snippet.contains("quantum"));
    }

    #[test]
    fn test_extract_snippet_no_match() {
        let text = "This text has no matching terms.";
        let terms = vec!["quantum".to_string()];

        let snippet = extract_snippet(text, &terms, 20);
        assert!(snippet.is_none());
    }
}
