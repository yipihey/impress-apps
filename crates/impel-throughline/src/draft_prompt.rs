//! Prompt contract + reply parsing for the LLM-backed [`ProposalDrafter`]
//! (ADR-0016 D6). Always compiled (no provider dependency) so the contract
//! and the salvage parser stay unit-tested even on toolchains where the
//! `llm` feature's provider stack can't build.

use std::collections::BTreeMap;

use imprint_service::throughline::ThroughlineParagraph;
use imprint_service::SectionRecord;

use crate::{DraftResult, SyncDirection};

/// The system prompt — the ADR-0016 D6 authority split, verbatim. Every
/// LLM drafter MUST carry this contract; the review gate remains the
/// actual enforcement point.
pub fn system_contract() -> &'static str {
    "You draft sync proposals between a manuscript and its throughline (a \
     short narrative companion). Authority is split and you must respect it: \
     claims and narrative order flow from the throughline; evidence, \
     derivations, and numbers flow from the manuscript. Never strengthen a \
     claim beyond what the anchored manuscript sections support — if the \
     throughline asserts more than the manuscript shows, say so in the note \
     field rather than papering over it. Your output is a PROPOSAL for human \
     review; it is never applied automatically. Respond with ONLY a JSON \
     object, no prose, of the form:\n\
     {\"paragraph_text\": string|null, \"section_bodies\": {key: string}, \
     \"note\": string|null}"
}

/// User-message payload for one stale anchor.
pub fn build_prompt(
    direction: &SyncDirection,
    paragraph: &ThroughlineParagraph,
    sections: &[SectionRecord],
) -> String {
    let mut out = String::new();
    match direction {
        SyncDirection::ManuscriptAhead => {
            out.push_str(
                "Direction: manuscript-ahead. The anchored sections changed; \
                 draft an updated throughline paragraph (set paragraph_text; \
                 leave section_bodies empty). Keep it one paragraph, \
                 blogpost register, claims no stronger than the sections.\n\n",
            );
        }
        SyncDirection::ThroughlineAhead => {
            out.push_str(
                "Direction: throughline-ahead. The narrative paragraph \
                 changed; draft the corresponding edits to EACH anchored \
                 section (fill section_bodies keyed by section key; leave \
                 paragraph_text null). Preserve all evidence, derivations, \
                 and numbers exactly as the current sections state them.\n\n",
            );
        }
        SyncDirection::Broken => {
            out.push_str(
                "Direction: broken. An anchored section no longer resolves. \
                 Produce only a note explaining the likely cause; repairs \
                 are chosen by the human.\n\n",
            );
        }
    }
    out.push_str(&format!(
        "Throughline paragraph <{}>:\n{}\n\n",
        paragraph.label, paragraph.body
    ));
    for s in sections {
        out.push_str(&format!(
            "Section [{}] \"{}\":\n{}\n\n",
            s.section_key, s.title, s.body
        ));
    }
    out
}

/// Parse the model reply: strict JSON first, then salvage the first
/// `{...}` block. A malformed reply yields `None` (caller falls back to
/// the template draft — the checkpoint still opens with full context).
pub fn parse_reply(reply: &str) -> Option<DraftResult> {
    #[derive(serde::Deserialize)]
    struct Row {
        #[serde(default)]
        paragraph_text: Option<String>,
        #[serde(default)]
        section_bodies: BTreeMap<String, String>,
        #[serde(default)]
        note: Option<String>,
    }
    let attempt = |s: &str| -> Option<Row> { serde_json::from_str(s).ok() };
    let row = attempt(reply.trim()).or_else(|| {
        let start = reply.find('{')?;
        let end = reply.rfind('}')?;
        if end <= start {
            return None;
        }
        attempt(&reply[start..=end])
    })?;
    Some(DraftResult {
        paragraph_text: row.paragraph_text,
        section_bodies: row.section_bodies,
        note: row.note,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_clean_reply() {
        let d =
            parse_reply(r#"{"paragraph_text": "We claim X.", "section_bodies": {}, "note": null}"#)
                .unwrap();
        assert_eq!(d.paragraph_text.as_deref(), Some("We claim X."));
        assert!(d.section_bodies.is_empty());
    }

    #[test]
    fn salvages_from_prose() {
        let d =
            parse_reply("Here you go:\n{\"section_bodies\": {\"intro\": \"New body.\"}}\nDone.")
                .unwrap();
        assert_eq!(d.section_bodies["intro"], "New body.");
        assert_eq!(d.paragraph_text, None);
    }

    #[test]
    fn malformed_reply_is_none() {
        assert!(parse_reply("no json here").is_none());
        assert!(parse_reply("} backwards {").is_none());
    }

    #[test]
    fn contract_carries_the_authority_split() {
        let c = system_contract();
        assert!(c.contains("claims and narrative order flow from the throughline"));
        assert!(c.contains("numbers flow from the manuscript"));
        assert!(c.contains("Never strengthen a claim"));
        assert!(c.contains("never applied automatically"));
    }
}
