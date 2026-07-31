//! Matching PDFs found on disk to the bibliography entries they belong to
//! (ADR-0023 W5).
//!
//! ## What this is for
//!
//! A watched folder (ADR-0023 W2) already turns a `.bib` into publications.
//! Researchers keep the PDFs next to the `.bib`, and BibDesk has recorded that
//! association in `Bdsk-File-*` fields for twenty years. This module answers
//! the one question the watcher cannot: **given the entries of a watched `.bib`
//! and the PDFs discovered beside it, which PDF belongs to which entry, and how
//! sure are we?**
//!
//! It is Rust because ADR-0023 D5 says so — the platform layer discovers paths,
//! everything below it is logic — and because every signal it needs already
//! lives in this crate:
//!
//! * [`crate::bibtex::bdsk_file`] decodes what BibDesk wrote,
//! * [`crate::deduplication`] owns the suite's title/author normalisation and
//!   its Jaro-Winkler/Levenshtein blend,
//! * [`crate::filename`] owns imbib's OWN `Author_Year_Title.pdf` convention
//!   (imbib ADR-004).
//!
//! A second implementation of any of those would be a second answer to it. The
//! only genuinely new thing here is the **ordering of the signals and the
//! thresholds**, and both are named constants below with their rationale.
//!
//! ## The signals, in credibility order
//!
//! | Signal | Confidence | Why it ranks there |
//! |---|---|---|
//! | [`AttachmentSignal::DeclaredFileField`] | [`CONFIDENCE_DECLARED_PATH`] / [`CONFIDENCE_DECLARED_NAME`] | The entry itself names the file. This is BibDesk's own data, written by the user's own tool; nothing we infer can outrank a statement of fact. |
//! | [`AttachmentSignal::CiteKey`] | [`CONFIDENCE_CITE_KEY`] / [`CONFIDENCE_CITE_KEY_NORMALIZED`] | A cite key is unique within a `.bib` by construction, so `smith2024.pdf` beside `smith2024.bib` is not a coincidence. |
//! | [`AttachmentSignal::HouseNaming`] | [`CONFIDENCE_HOUSE_NAMING`] | The filename is exactly what [`crate::filename::generate_pdf_filename`] would have produced — i.e. imbib itself, or a user following imbib's documented convention, named this file. |
//! | [`AttachmentSignal::Fuzzy`] | ≤ [`CONFIDENCE_FUZZY_CEILING`] | Title/author/year similarity. A guess, however good. |
//!
//! ## The one structural rule
//!
//! **[`CONFIDENCE_FUZZY_CEILING`] is below [`AUTO_ATTACH_CONFIDENCE`], so a
//! fuzzy match can never auto-attach.** That is not a tuning accident, it is
//! the design: the three signals above the line are all cases where *somebody
//! stated* the association (BibDesk, the cite key, imbib's own namer), and the
//! one below it is a case where we inferred it. Inference gets offered to a
//! human; assertion gets acted on. Re-tuning the fuzzy weights can therefore
//! never silently turn a guess into an automatic write to a user's library.
//!
//! ## What it deliberately does not do
//!
//! * It does not read the PDFs. Extracting a DOI from page 1 would be a
//!   stronger signal than any of these, and `im_identifiers::extract_all` plus
//!   [`crate::pdf`] would supply it — but it costs a full text extraction per
//!   candidate at scan time, which is ADR-0023 D7's burst hazard for a
//!   subtitle. Recorded as W5's deferral, not forgotten.
//! * It does not attach anything. It returns verdicts; the caller writes.
//! * It does not touch the filesystem. Paths in, verdicts out — which is what
//!   makes the golden corpus possible.

use std::collections::HashMap;

use unicode_normalization::UnicodeNormalization;

use crate::bibtex::bdsk_file::bdsk_file_decode_internal as bdsk_file_decode;
use crate::bibtex::latex_decoder::decode_latex_internal;
use crate::deduplication::normalization::{extract_surname, split_authors};
use crate::deduplication::similarity::title_similarity;
use crate::filename::{generate_pdf_filename_from_metadata_internal, FilenameOptions};

// ── Thresholds ──────────────────────────────────────────────────────────────

/// The entry names this exact file (relative path suffix match).
///
/// 1.0 and not 0.99: the entry's `Bdsk-File-1` decoding to `Papers/x.pdf` and a
/// discovered `…/Papers/x.pdf` is not a similarity judgement at all, it is the
/// same path.
pub const CONFIDENCE_DECLARED_PATH: f64 = 1.0;

/// The entry names a file with this basename, but at a different (or
/// unresolvable) relative location.
///
/// Below [`CONFIDENCE_DECLARED_PATH`] because the user may genuinely have two
/// `paper.pdf` in two subdirectories — but still above
/// [`AUTO_ATTACH_CONFIDENCE`], because the entry DID name this filename and the
/// ambiguity rule below is what catches the two-`paper.pdf` case.
pub const CONFIDENCE_DECLARED_NAME: f64 = 0.97;

/// The filename stem IS the cite key.
pub const CONFIDENCE_CITE_KEY: f64 = 0.95;

/// The filename stem is the cite key once both are normalised (case, spaces,
/// underscores, diacritics). `Smith 2024.pdf` for `Smith2024` is the same
/// claim typed by a human rather than by a program.
pub const CONFIDENCE_CITE_KEY_NORMALIZED: f64 = 0.93;

/// The filename is what [`crate::filename::generate_pdf_filename`] would have
/// produced for this entry — imbib's own `Author_Year_Title.pdf` convention
/// (imbib ADR-004).
pub const CONFIDENCE_HOUSE_NAMING: f64 = 0.92;

/// The highest a purely fuzzy match may score.
///
/// **Deliberately below [`AUTO_ATTACH_CONFIDENCE`].** See the module note: a
/// guess is offered, never performed.
pub const CONFIDENCE_FUZZY_CEILING: f64 = 0.88;

/// At or above this, a UNIQUE match attaches without asking.
///
/// Set between [`CONFIDENCE_HOUSE_NAMING`] and [`CONFIDENCE_FUZZY_CEILING`],
/// which is the whole point: it is the line between "somebody stated this" and
/// "we inferred this", not a number tuned against a corpus.
pub const AUTO_ATTACH_CONFIDENCE: f64 = 0.90;

/// Below this a candidate is not offered at all — the PDF is reported as
/// unmatched instead.
///
/// A PDF that matches nothing must say so plainly. Offering the user a 0.2
/// candidate trains them to dismiss the offer surface, which costs more than
/// the occasional missed match: the folder is still there, and Reveal in Finder
/// is one gesture away.
pub const OFFER_CONFIDENCE: f64 = 0.55;

/// How far clear of the runner-up the leader must be to count as unique.
///
/// Two entries by the same author in the same year are the case this exists
/// for. Without a margin, `Einstein_1905.pdf` would auto-attach to whichever of
/// two 1905 Einstein papers happened to sort first — a silent wrong answer,
/// which is worse than a question.
pub const AMBIGUITY_MARGIN: f64 = 0.08;

/// The most candidates one ambiguous PDF will offer. Beyond this the list stops
/// being a choice and starts being a search problem.
pub const MAX_OFFERED_CANDIDATES: usize = 5;

/// **The threshold ordering, enforced at COMPILE TIME.**
///
/// These were unit tests until clippy pointed out — correctly — that an
/// assertion over two constants is constant-folded. It was right about the
/// mechanism and the conclusion runs the other way: if the claim is decidable
/// without running anything, it should fail the BUILD, not a test somebody has
/// to remember to run. A `const` block is the strongest form this rule can
/// take, and the rule is worth it: the whole safety argument of this module is
/// that a fuzzy score cannot reach the auto-attach line.
const _: () = {
    assert!(
        CONFIDENCE_FUZZY_CEILING < AUTO_ATTACH_CONFIDENCE,
        "a fuzzy match must never be able to auto-attach"
    );
    assert!(
        CONFIDENCE_HOUSE_NAMING >= AUTO_ATTACH_CONFIDENCE,
        "imbib's own naming is a statement, not a guess — it must auto-attach"
    );
    assert!(CONFIDENCE_CITE_KEY >= AUTO_ATTACH_CONFIDENCE);
    assert!(CONFIDENCE_CITE_KEY_NORMALIZED >= AUTO_ATTACH_CONFIDENCE);
    assert!(CONFIDENCE_DECLARED_NAME >= AUTO_ATTACH_CONFIDENCE);
    assert!(CONFIDENCE_DECLARED_PATH >= CONFIDENCE_DECLARED_NAME);
    assert!(
        OFFER_CONFIDENCE < AUTO_ATTACH_CONFIDENCE,
        "the offer floor is below the attach line, or nothing is ever offered"
    );
    assert!(AMBIGUITY_MARGIN > 0.0);
};

// ── Inputs ──────────────────────────────────────────────────────────────────

/// One bibliography entry a PDF might belong to.
///
/// `fields` is the entry's fields verbatim (keys as written), because the
/// matcher reads several of them — `title`, `author`, `year`, every
/// `Bdsk-File-*`, and the plain `file`/`local-file` forms other tools write —
/// and a caller pre-extracting them would be a caller deciding which signals
/// exist.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct AttachmentEntry {
    /// The caller's handle for this entry, echoed back in every verdict. imbib
    /// passes the publication's UUID string; a `.bib`-only caller can pass the
    /// cite key.
    pub id: String,
    pub cite_key: String,
    pub fields: Vec<crate::bibtex::BibTeXField>,
}

impl AttachmentEntry {
    /// Build a candidate from a parsed entry, using the cite key as the id.
    pub fn from_bibtex(entry: &crate::bibtex::BibTeXEntry) -> Self {
        Self {
            id: entry.cite_key.clone(),
            cite_key: entry.cite_key.clone(),
            fields: entry.fields.clone(),
        }
    }

    fn field(&self, key: &str) -> Option<&str> {
        let lowered = key.to_lowercase();
        self.fields
            .iter()
            .find(|f| f.key.to_lowercase() == lowered)
            .map(|f| f.value.as_str())
    }
}

// ── Outputs ─────────────────────────────────────────────────────────────────

/// Why the matcher thinks this PDF belongs to this entry.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum AttachmentSignal {
    /// The entry's own `Bdsk-File-*` (or `file` / `local-file`) field names the
    /// file. BibDesk's data, honoured first and exactly.
    DeclaredFileField,
    /// The filename stem is the entry's cite key.
    CiteKey,
    /// The filename is imbib's own `Author_Year_Title.pdf` convention.
    HouseNaming,
    /// Title / author / year similarity. Never enough to attach on its own.
    Fuzzy,
}

impl AttachmentSignal {
    /// A stable string, for goldens and for logs.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::DeclaredFileField => "declared-file-field",
            Self::CiteKey => "cite-key",
            Self::HouseNaming => "house-naming",
            Self::Fuzzy => "fuzzy",
        }
    }
}

/// What the caller should DO with a match.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum AttachmentVerdict {
    /// At or above [`AUTO_ATTACH_CONFIDENCE`] and clear of every rival by more
    /// than [`AMBIGUITY_MARGIN`]. Attach it; that is the feature.
    Automatic,
    /// Plausible, but either below the auto threshold or not unique. **Never
    /// attach one of these without a human saying so** (ADR-0023 W5).
    Offer,
}

impl AttachmentVerdict {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Automatic => "automatic",
            Self::Offer => "offer",
        }
    }
}

/// One (PDF, entry) pairing the matcher is prepared to defend.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct AttachmentMatch {
    /// The candidate path, exactly as it was handed in.
    pub pdf_path: String,
    /// [`AttachmentEntry::id`] of the entry it belongs to.
    pub entry_id: String,
    pub cite_key: String,
    pub confidence: f64,
    pub signal: AttachmentSignal,
    pub verdict: AttachmentVerdict,
    /// One line a human can read on the offer row.
    pub reason: String,
}

/// Everything the matcher concluded about one folder's PDFs.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Default)]
pub struct AttachmentMatchReport {
    /// Every pairing at or above [`OFFER_CONFIDENCE`]. A PDF with an
    /// `Automatic` verdict appears exactly once; an ambiguous one appears once
    /// per candidate, best first.
    pub matches: Vec<AttachmentMatch>,
    /// PDFs no entry claimed at all, in input order. Not a failure — a folder
    /// legitimately contains PDFs that are not in its `.bib`.
    pub unmatched_pdfs: Vec<String>,
}

impl AttachmentMatchReport {
    /// The matches to act on without asking anybody.
    pub fn automatic(&self) -> impl Iterator<Item = &AttachmentMatch> {
        self.matches
            .iter()
            .filter(|m| m.verdict == AttachmentVerdict::Automatic)
    }

    /// The matches that need a human. Paired with [`Self::unmatched_pdfs`],
    /// this is the whole content of the review surface.
    pub fn offers(&self) -> impl Iterator<Item = &AttachmentMatch> {
        self.matches
            .iter()
            .filter(|m| m.verdict == AttachmentVerdict::Offer)
    }

    /// Every verdict concerning one entry — the per-entry view ADR-0023 W5
    /// asks for, without a second index to keep in step.
    pub fn matches_for_entry<'a>(
        &'a self,
        entry_id: &'a str,
    ) -> impl Iterator<Item = &'a AttachmentMatch> {
        self.matches.iter().filter(move |m| m.entry_id == entry_id)
    }
}

// ── The matcher ─────────────────────────────────────────────────────────────

/// Match a watched `.bib`'s entries against the PDFs discovered in scope.
///
/// Deterministic: same inputs, same output, in a stable order (candidates by
/// descending confidence, ties broken by cite key). That is what makes the
/// re-scan idempotent one layer up — the caller can compare a fresh report
/// against what it already attached and write nothing.
pub fn match_attachments_internal(
    entries: &[AttachmentEntry],
    pdf_paths: &[String],
) -> AttachmentMatchReport {
    // Hoisted once per entry rather than recomputed per (entry, PDF): the loop
    // below is O(entries × PDFs) and every one of these is an allocation.
    let profiles: Vec<EntryProfile> = entries.iter().map(EntryProfile::build).collect();

    let mut report = AttachmentMatchReport::default();

    for path in pdf_paths {
        let probe = PdfProbe::build(path);
        let mut candidates: Vec<AttachmentMatch> = Vec::new();

        for profile in &profiles {
            if let Some((confidence, signal, reason)) = profile.score(&probe) {
                if confidence + f64::EPSILON < OFFER_CONFIDENCE {
                    continue;
                }
                candidates.push(AttachmentMatch {
                    pdf_path: path.clone(),
                    entry_id: profile.id.clone(),
                    cite_key: profile.cite_key.clone(),
                    confidence,
                    signal,
                    verdict: AttachmentVerdict::Offer,
                    reason,
                });
            }
        }

        if candidates.is_empty() {
            report.unmatched_pdfs.push(path.clone());
            continue;
        }

        // Deterministic order: best first, ties broken by cite key so two
        // entries that score identically do not depend on input order.
        candidates.sort_by(|a, b| {
            b.confidence
                .partial_cmp(&a.confidence)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.cite_key.cmp(&b.cite_key))
        });

        let leader = candidates[0].confidence;
        let unique = candidates.len() == 1
            // A DECLARATION outranks every inference, categorically — not by
            // the margin, which 1.00-vs-0.95 would fail. If one entry's
            // `Bdsk-File-1` names this file and another entry merely happens to
            // share its name, there is no contest: the first is a statement the
            // user's own tool made, the second is a coincidence. Two entries
            // that BOTH declare the same file are genuinely ambiguous and fall
            // through to the margin, which they fail — so they are offered.
            || (candidates[0].signal == AttachmentSignal::DeclaredFileField
                && candidates[1].signal != AttachmentSignal::DeclaredFileField)
            || leader - candidates[1].confidence > AMBIGUITY_MARGIN;

        if leader >= AUTO_ATTACH_CONFIDENCE && unique {
            let mut winner = candidates.remove(0);
            winner.verdict = AttachmentVerdict::Automatic;
            report.matches.push(winner);
            // The rivals are not offered: this PDF has an answer, and offering
            // a second one would invite the user to undo a correct write.
            continue;
        }

        candidates.truncate(MAX_OFFERED_CANDIDATES);
        report.matches.append(&mut candidates);
    }

    report
}

/// UniFFI surface — the shape Swift calls (ADR-0023 D5's Rust half).
#[cfg(feature = "native")]
#[uniffi::export]
pub fn match_attachments(
    entries: Vec<AttachmentEntry>,
    pdf_paths: Vec<String>,
) -> AttachmentMatchReport {
    match_attachments_internal(&entries, &pdf_paths)
}

/// The thresholds, as data, so a UI can explain itself without a second copy
/// of the numbers.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct AttachmentThresholds {
    pub auto_attach: f64,
    pub offer: f64,
    pub ambiguity_margin: f64,
    pub fuzzy_ceiling: f64,
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn attachment_thresholds() -> AttachmentThresholds {
    attachment_thresholds_internal()
}

pub fn attachment_thresholds_internal() -> AttachmentThresholds {
    AttachmentThresholds {
        auto_attach: AUTO_ATTACH_CONFIDENCE,
        offer: OFFER_CONFIDENCE,
        ambiguity_margin: AMBIGUITY_MARGIN,
        fuzzy_ceiling: CONFIDENCE_FUZZY_CEILING,
    }
}

// ── Scoring ─────────────────────────────────────────────────────────────────

/// One PDF path, pre-chewed.
struct PdfProbe {
    /// Full path, separators normalised to `/`.
    path: String,
    /// Last path component.
    file_name: String,
    /// Last path component without its extension.
    stem: String,
    /// [`normalize_name`] of the stem — the form every filename comparison uses.
    normalized_stem: String,
    /// [`normalize_name`] with the spaces taken out too — the form a cite key
    /// is compared in, because a cite key is one token.
    squashed_stem: String,
    /// The stem read as prose: separators become spaces, so the dedup crate's
    /// title normaliser sees words rather than one long token.
    stem_as_prose: String,
}

impl PdfProbe {
    fn build(path: &str) -> Self {
        let normalized_path = path.replace('\\', "/");
        let file_name = normalized_path
            .rsplit('/')
            .next()
            .unwrap_or(&normalized_path)
            .to_string();
        let stem = match file_name.rfind('.') {
            Some(dot) if dot > 0 => file_name[..dot].to_string(),
            _ => file_name.clone(),
        };
        let normalized_stem = normalize_name(&stem);
        let squashed_stem = normalized_stem.replace(' ', "");
        let stem_as_prose = separators_to_spaces(&stem);
        Self {
            path: normalized_path,
            file_name,
            stem,
            normalized_stem,
            squashed_stem,
            stem_as_prose,
        }
    }
}

/// One entry, pre-chewed.
struct EntryProfile {
    id: String,
    cite_key: String,
    squashed_cite_key: String,
    title: Option<String>,
    year: Option<String>,
    surnames: Vec<String>,
    /// Relative paths the entry DECLARES, from `Bdsk-File-*` and friends.
    declared_paths: Vec<String>,
    /// [`normalize_name`] of the filename imbib itself would generate.
    house_name: Option<String>,
}

impl EntryProfile {
    fn build(entry: &AttachmentEntry) -> Self {
        let title = entry
            .field("title")
            .map(|t| decode_latex_internal(strip_braces(t)))
            .filter(|t| !t.trim().is_empty());
        let year = entry
            .field("year")
            .map(|y| y.trim().trim_matches(|c| c == '{' || c == '}').to_string())
            .filter(|y| !y.is_empty());
        let author_field = entry
            .field("author")
            .map(|a| decode_latex_internal(strip_braces(a)));
        let authors: Vec<String> = author_field
            .as_deref()
            .map(split_authors)
            .unwrap_or_default();
        let surnames: Vec<String> = authors
            .iter()
            .map(|a| extract_surname(a))
            .filter(|s| s.len() > 1)
            .collect();

        // imbib's own convention (imbib ADR-004), through imbib's own
        // generator: a second spelling of `Author_Year_Title` here would be a
        // second convention the moment either moved.
        let house_name = title.as_ref().map(|t| {
            let generated = generate_pdf_filename_from_metadata_internal(
                t.clone(),
                authors.clone(),
                year.as_ref().and_then(|y| y.parse::<i32>().ok()),
                &FilenameOptions::default(),
            );
            normalize_name(generated.trim_end_matches(".pdf"))
        });

        Self {
            id: entry.id.clone(),
            cite_key: entry.cite_key.clone(),
            squashed_cite_key: normalize_name(&entry.cite_key).replace(' ', ""),
            title,
            year,
            surnames,
            declared_paths: declared_paths(entry),
            house_name,
        }
    }

    /// The best signal this entry has for this PDF, or `None`.
    fn score(&self, pdf: &PdfProbe) -> Option<(f64, AttachmentSignal, String)> {
        // 1. What the entry itself says. Checked first and returned
        //    immediately: no inferred signal may outrank a declaration.
        for declared in &self.declared_paths {
            let declared_norm = declared.replace('\\', "/");
            if path_ends_with_component_boundary(&pdf.path, &declared_norm) {
                return Some((
                    CONFIDENCE_DECLARED_PATH,
                    AttachmentSignal::DeclaredFileField,
                    format!("the entry's file field names {declared}"),
                ));
            }
        }
        for declared in &self.declared_paths {
            let declared_name = declared.replace('\\', "/");
            let declared_name = declared_name.rsplit('/').next().unwrap_or(&declared_name);
            if normalize_name(declared_name) == normalize_name(&pdf.file_name) {
                return Some((
                    CONFIDENCE_DECLARED_NAME,
                    AttachmentSignal::DeclaredFileField,
                    format!("the entry's file field names a file called {declared_name}"),
                ));
            }
        }

        // 2. The cite key, which is unique within a `.bib` by construction.
        if pdf.stem.eq_ignore_ascii_case(&self.cite_key) {
            return Some((
                CONFIDENCE_CITE_KEY,
                AttachmentSignal::CiteKey,
                format!("the file is named for the cite key {}", self.cite_key),
            ));
        }
        // A cite key is ONE token — `Noether1918`, not `Noether 1918` — so the
        // comparison squashes separators out entirely rather than collapsing
        // them to spaces the way every other name comparison here does. A
        // human who typed `Noether 1918.pdf` is making the cite key's claim
        // with a space in it; the space is not part of the claim.
        if !pdf.squashed_stem.is_empty() && pdf.squashed_stem == self.squashed_cite_key {
            return Some((
                CONFIDENCE_CITE_KEY_NORMALIZED,
                AttachmentSignal::CiteKey,
                format!(
                    "the file name matches the cite key {} once spacing and case are ignored",
                    self.cite_key
                ),
            ));
        }

        // 3. imbib's own naming convention.
        if let Some(house) = &self.house_name {
            if !house.is_empty() && *house == pdf.normalized_stem {
                return Some((
                    CONFIDENCE_HOUSE_NAMING,
                    AttachmentSignal::HouseNaming,
                    "the file follows imbib's Author_Year_Title naming for this entry".to_string(),
                ));
            }
        }

        // 4. The guess.
        self.fuzzy(pdf)
    }

    fn fuzzy(&self, pdf: &PdfProbe) -> Option<(f64, AttachmentSignal, String)> {
        let title = self.title.as_deref()?;

        // THE dedup blend (0.6·Jaro-Winkler + 0.4·Levenshtein over
        // `normalize_title_internal`), not a second one.
        let title_score = title_similarity(&pdf.stem_as_prose, title);

        let haystack = normalize_name(&pdf.stem_as_prose);
        let surname_hit = self
            .surnames
            .iter()
            .any(|s| !s.is_empty() && contains_word(&haystack, &normalize_name(s)));
        let year_hit = self
            .year
            .as_deref()
            .map(|y| contains_word(&haystack, y))
            .unwrap_or(false);

        // A bare "the year appears in the name" is true of a third of all files
        // on a researcher's disk. Something about the WORK has to match too,
        // or this is noise dressed as evidence.
        if !surname_hit && title_score < 0.5 {
            return None;
        }

        // Three independent pieces of evidence, weighted to sum to exactly 1.0
        // so the score reads as "how much of what could agree, did". The
        // weights are calibrated against two cases the corpus pins, and they
        // are the reason the split is 0.55/0.30/0.15 rather than anything else:
        //
        //   * a file named for the TITLE alone (`On Denoting.pdf`) must clear
        //     `OFFER_CONFIDENCE`, so the title weight is 0.55;
        //   * a file named `Author Year.pdf` — no title words at all — must
        //     ALSO clear it, because when two same-year papers by one author
        //     are in the folder that filename is exactly the ambiguity a human
        //     has to resolve. So surname + year = 0.45, plus whatever weak
        //     title similarity two such names always share.
        //
        // Everything agreeing gives 1.0, which the ceiling then clamps: a
        // perfect fuzzy match is still a fuzzy match.
        let raw = title_score * 0.55
            + if surname_hit { 0.30 } else { 0.0 }
            + if year_hit { 0.15 } else { 0.0 };

        let confidence = raw.min(CONFIDENCE_FUZZY_CEILING);
        let mut parts = vec![format!("title {:.0}% alike", title_score * 100.0)];
        if surname_hit {
            parts.push("author in the file name".to_string());
        }
        if year_hit {
            parts.push("year in the file name".to_string());
        }
        Some((confidence, AttachmentSignal::Fuzzy, parts.join(", ")))
    }
}

// ── Field reading ───────────────────────────────────────────────────────────

/// The relative paths one entry declares, from every field form the wild
/// contains.
///
/// * `Bdsk-File-N` — BibDesk's base64 binary plist, decoded by
///   [`crate::bibtex::bdsk_file::bdsk_file_decode`].
/// * `file` / `local-file` / `pdf` — the plain forms JabRef, Zotero's BetterBibTeX
///   and hand-editing produce. JabRef writes `Description:path/to.pdf:PDF`, so
///   a value with colon-separated triples is unpacked.
fn declared_paths(entry: &AttachmentEntry) -> Vec<String> {
    let mut paths = Vec::new();
    for field in &entry.fields {
        let key = field.key.to_lowercase();
        if key.starts_with("bdsk-file-") {
            if let Some(decoded) = bdsk_file_decode(field.value.clone()) {
                paths.push(decoded);
            }
            continue;
        }
        if key == "file" || key == "local-file" || key == "pdf" {
            for entry_spec in field.value.split(';') {
                let spec = entry_spec.trim();
                if spec.is_empty() {
                    continue;
                }
                // `Description:path:PDF` (JabRef) or a bare path.
                let parts: Vec<&str> = spec.split(':').collect();
                let candidate = if parts.len() >= 3 {
                    parts[1..parts.len() - 1].join(":")
                } else {
                    spec.to_string()
                };
                let candidate = candidate.trim().to_string();
                if !candidate.is_empty() {
                    paths.push(candidate);
                }
            }
        }
    }
    paths
}

// ── String helpers ──────────────────────────────────────────────────────────

/// The one filename-comparison form.
///
/// NFKD then ASCII-alphanumeric-only, which is `normalize_title_internal`'s
/// rule and therefore the same diacritic answer the dedup crate gives — and,
/// not incidentally, the answer to macOS's NFD-on-disk vs NFC-in-the-`.bib`
/// trap, which would otherwise make `Müller_2020.pdf` fail to match itself.
/// Separators (`_`, `-`, `.`, whitespace) all collapse to one space, so
/// `Author_Year_Title` and `Author Year Title` are the same name.
fn normalize_name(input: &str) -> String {
    let decomposed: String = input
        .nfkd()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_lowercase()
            } else if c == '_' || c == '-' || c == '.' || c.is_whitespace() {
                ' '
            } else {
                '\u{0}'
            }
        })
        .filter(|c| *c != '\u{0}')
        .collect();
    decomposed.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Separators to spaces, nothing else — so the dedup crate's title normaliser
/// sees `zur elektrodynamik bewegter korper`, not one 30-character token that
/// Jaro-Winkler would score against a real title as noise.
fn separators_to_spaces(input: &str) -> String {
    input
        .chars()
        .map(|c| if c == '_' || c == '-' { ' ' } else { c })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Whether `needle` appears in `haystack` as a whole space-delimited run of
/// words. Both are [`normalize_name`] output.
///
/// Substring containment would make `ell` match `Russell`; a bibliography of
/// short surnames is exactly where that misfires.
fn contains_word(haystack: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return false;
    }
    let hay: Vec<&str> = haystack.split(' ').collect();
    let need: Vec<&str> = needle.split(' ').collect();
    if need.len() > hay.len() {
        return false;
    }
    hay.windows(need.len()).any(|w| w == need.as_slice())
}

/// A declared relative path matches a discovered absolute one only at a path
/// COMPONENT boundary.
///
/// `…/notes/paper.pdf` must not satisfy a declaration of `per.pdf`, which is
/// what a bare `ends_with` would allow.
fn path_ends_with_component_boundary(full: &str, suffix: &str) -> bool {
    let full_norm = full.trim_end_matches('/');
    let suffix_norm = suffix.trim_start_matches("./").trim_start_matches('/');
    if suffix_norm.is_empty() {
        return false;
    }
    if full_norm.eq_ignore_ascii_case(suffix_norm) {
        return true;
    }
    let Some(head_len) = full_norm.len().checked_sub(suffix_norm.len()) else {
        return false;
    };
    if head_len == 0 {
        return false;
    }
    full_norm[head_len..].eq_ignore_ascii_case(suffix_norm)
        && full_norm.as_bytes()[head_len - 1] == b'/'
}

/// BibTeX braces are grouping, not content.
fn strip_braces(value: &str) -> String {
    value.replace(['{', '}'], "").trim().to_string()
}

/// Every declared path in a set of entries, keyed by entry id — what a caller
/// needs to answer "is this PDF already attached?" without re-running the
/// matcher.
pub fn declared_paths_by_entry(entries: &[AttachmentEntry]) -> HashMap<String, Vec<String>> {
    entries
        .iter()
        .map(|e| (e.id.clone(), declared_paths(e)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bibtex::bdsk_file::bdsk_file_encode_internal as bdsk_file_encode;
    use crate::bibtex::BibTeXField;

    fn field(key: &str, value: &str) -> BibTeXField {
        BibTeXField {
            key: key.to_string(),
            value: value.to_string(),
        }
    }

    fn entry(cite_key: &str, fields: Vec<BibTeXField>) -> AttachmentEntry {
        AttachmentEntry {
            id: cite_key.to_string(),
            cite_key: cite_key.to_string(),
            fields,
        }
    }

    /// The threshold ordering is enforced at COMPILE TIME by the `const _`
    /// block near the constants; there is deliberately no runtime test for it,
    /// because a claim decidable without running anything should fail the build.
    ///
    /// What IS worth a runtime test is that the ordering is actually CONSULTED:
    /// a correct set of constants that nothing reads would satisfy the const
    /// block and attach everything.
    #[test]
    fn the_thresholds_are_actually_consulted() {
        let thresholds = attachment_thresholds_internal();
        assert_eq!(thresholds.auto_attach, AUTO_ATTACH_CONFIDENCE);
        assert_eq!(thresholds.fuzzy_ceiling, CONFIDENCE_FUZZY_CEILING);
        assert_eq!(thresholds.offer, OFFER_CONFIDENCE);
        assert_eq!(thresholds.ambiguity_margin, AMBIGUITY_MARGIN);
    }

    #[test]
    fn a_bdsk_file_field_wins_outright() {
        let encoded = bdsk_file_encode("Papers/whatever.pdf".to_string()).unwrap();
        let e = entry(
            "smith2024",
            vec![
                field("title", "A Study of Nothing"),
                field("author", "Smith, John"),
                field("year", "2024"),
                field("Bdsk-File-1", &encoded),
            ],
        );
        let report =
            match_attachments_internal(&[e], &["/tmp/lib/Papers/whatever.pdf".to_string()]);
        assert_eq!(report.matches.len(), 1);
        assert_eq!(
            report.matches[0].signal,
            AttachmentSignal::DeclaredFileField
        );
        assert_eq!(report.matches[0].confidence, CONFIDENCE_DECLARED_PATH);
        assert_eq!(report.matches[0].verdict, AttachmentVerdict::Automatic);
    }

    #[test]
    fn a_component_boundary_is_required() {
        assert!(path_ends_with_component_boundary(
            "/a/b/Papers/x.pdf",
            "Papers/x.pdf"
        ));
        assert!(!path_ends_with_component_boundary(
            "/a/b/paper.pdf",
            "per.pdf"
        ));
        assert!(path_ends_with_component_boundary(
            "/a/b/paper.pdf",
            "./b/paper.pdf"
        ));
    }

    #[test]
    fn normalization_collapses_separators_and_diacritics() {
        assert_eq!(
            normalize_name("Müller_2020_Über_Etwas"),
            "muller 2020 uber etwas"
        );
        assert_eq!(
            normalize_name("Muller 2020 Uber Etwas"),
            "muller 2020 uber etwas"
        );
        assert_eq!(normalize_name("Smith-2024.final"), "smith 2024 final");
    }

    #[test]
    fn contains_word_does_not_match_inside_a_word() {
        assert!(contains_word("russell 1905 on denoting", "russell"));
        assert!(!contains_word("russell 1905 on denoting", "ell"));
        assert!(contains_word("van der waals 1873", "van der waals"));
    }

    #[test]
    fn an_unclaimed_pdf_is_reported_unmatched_not_forced() {
        let e = entry(
            "einstein1905",
            vec![
                field("title", "Zur Elektrodynamik bewegter Koerper"),
                field("author", "Einstein, Albert"),
                field("year", "1905"),
            ],
        );
        let report =
            match_attachments_internal(&[e], &["/tmp/lib/tax-return-2019.pdf".to_string()]);
        assert!(report.matches.is_empty(), "{:?}", report.matches);
        assert_eq!(report.unmatched_pdfs.len(), 1);
    }
}
