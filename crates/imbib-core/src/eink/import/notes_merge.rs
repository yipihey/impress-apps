//! Appending imported highlights and notes to a paper's Notes field.
//!
//! The field is a document with YAML front matter that
//! `PublicationNotesDocument` owns on the Swift side; appending at the end
//! leaves the front matter and the user's prose untouched. A marker
//! comment records which tablet snapshot was appended, so the same one is
//! never appended twice.

/// One line of the block.
#[derive(Debug, Clone, PartialEq)]
pub struct NoteEntry {
    pub page_number: Option<i64>,
    /// `highlight`, `note` (typed) or `ink` (handwriting, OCR).
    pub kind: String,
    pub text: String,
    pub ocr_confidence: Option<f64>,
}

pub fn marker(remote_id: &str, imported_ms: i64) -> String {
    format!("<!-- eink:{remote_id}:{imported_ms} -->")
}

pub fn already_appended(raw_note: &str, remote_id: &str, imported_ms: i64) -> bool {
    raw_note.contains(&marker(remote_id, imported_ms))
}

pub fn build_block(date: &str, remote_id: &str, imported_ms: i64, entries: &[NoteEntry]) -> String {
    let mut out = format!(
        "## reMarkable notes — {date}\n{}\n",
        marker(remote_id, imported_ms)
    );
    for entry in entries {
        let text = entry.text.trim();
        if text.is_empty() {
            continue;
        }
        let page = entry
            .page_number
            .map(|p| format!("**p. {}**", p + 1))
            .unwrap_or_else(|| "**—**".into());
        let line = match entry.kind.as_str() {
            "highlight" => format!("{page} — \"{text}\""),
            "note" => format!("{page} (typed) — {text}"),
            "ink" => match entry.ocr_confidence {
                Some(confidence) => format!("{page} (handwritten, OCR {confidence:.2}) — {text}"),
                None => format!("{page} (handwritten) — {text}"),
            },
            other => format!("{page} ({other}) — {text}"),
        };
        out.push_str(&line);
        out.push('\n');
    }
    out
}

/// The note with the block appended (front matter and prose untouched).
pub fn append_to_note(raw_note: &str, block: &str) -> String {
    let trimmed = raw_note.trim_end();
    if trimmed.is_empty() {
        return block.to_string();
    }
    format!("{trimmed}\n\n{block}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_block_is_appended_once_after_the_front_matter() {
        let raw = "---\nKey findings: x\n---\n\nMy prose.\n";
        let entries = vec![
            NoteEntry {
                page_number: Some(2),
                kind: "highlight".into(),
                text: "dark matter".into(),
                ocr_confidence: None,
            },
            NoteEntry {
                page_number: Some(3),
                kind: "ink".into(),
                text: "hello".into(),
                ocr_confidence: Some(0.82),
            },
            NoteEntry {
                page_number: None,
                kind: "note".into(),
                text: "".into(),
                ocr_confidence: None,
            },
        ];
        let block = build_block("2026-09-07", "r1", 42, &entries);
        let merged = append_to_note(raw, &block);
        assert!(merged.starts_with("---\nKey findings: x\n---\n\nMy prose.\n\n## reMarkable notes — 2026-09-07\n<!-- eink:r1:42 -->\n"));
        assert!(merged.contains("**p. 3** — \"dark matter\""));
        assert!(merged.contains("**p. 4** (handwritten, OCR 0.82) — hello"));
        assert!(!merged.contains("(typed)"), "empty entries are dropped");
        assert!(already_appended(&merged, "r1", 42));
        assert!(!already_appended(&merged, "r1", 43));
        assert_eq!(append_to_note("", &block), block);
    }
}
