//! Throughline persistence and staleness derivation (ADR-0016).
//!
//! A throughline is a curated narrative companion to a manuscript: a Typst
//! source whose paragraphs carry stable `<tl-*>` labels, plus an **anchor
//! map** (the sync ledger) linking each label to the manuscript sections it
//! narrates. The ledger records content hashes of both sides *at the last
//! accepted sync*; comparing them against current hashes yields the four
//! derived anchor states of ADR-0016 D5.
//!
//! Layering mirrors `sections.rs`: the Swift app owns the sidecar files
//! inside the `.imprint` package and mirrors them into the shared store;
//! this module is the store-side representation (one `throughline` item per
//! document, deterministic UUID-v5 id) plus the pure derivation functions.
//! Headless callers (MCP/CLI/tests) work entirely store-side.
//!
//! **Ledger discipline (ADR-0016 D6):** the ledger hashes are written only
//! by (a) throughline creation, (b) explicit human anchoring
//! (`set_anchor` — establishing a baseline is a human act), and (c) the
//! accept path of a sync proposal (`record_sync_accepted`). Derivation
//! never writes.

use std::collections::BTreeMap;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::blob_store::BlobStore;
use crate::error::ServiceError;
use crate::sections::{SectionRecord, SectionStore};
use impress_store_ffi::SharedStore;

/// Schema reference stored on the throughline mirror item. Matches
/// `impress-core::schemas::throughline`.
pub const THROUGHLINE_SCHEMA_REF: &str = "throughline";

/// Sidecar file names inside the `.imprint` package (ADR-0016 D2).
pub const THROUGHLINE_SOURCE_FILENAME: &str = "throughline.typ";
pub const THROUGHLINE_ANCHORS_FILENAME: &str = "throughline.anchors.json";

/// Current anchor-map schema version. Parsing rejects anything newer.
pub const ANCHOR_MAP_VERSION: u32 = 1;

/// Namespace for the deterministic UUID-v5 throughline item id, derived from
/// `"<document_id>::throughline"`. Picked once and frozen (same convention as
/// `SECTION_ID_NAMESPACE` in `sections.rs`).
const THROUGHLINE_ID_NAMESPACE: Uuid = Uuid::from_bytes([
    0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
]);

// ---------------------------------------------------------------------------
// Anchor map (the sync ledger)
// ---------------------------------------------------------------------------

/// Ledger entry for one throughline paragraph (identified by its `<tl-*>`
/// label). Hashes are SHA-256 hex recorded at the last accepted sync.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct AnchorEntry {
    /// Manuscript section keys this paragraph narrates.
    pub section_keys: Vec<String>,
    /// Ledger hash of each anchored section's body (key → sha256 hex).
    #[serde(default)]
    pub manuscript_hashes: BTreeMap<String, String>,
    /// Ledger hash of the paragraph body.
    #[serde(default)]
    pub throughline_hash: String,
}

/// The anchor map — `throughline.anchors.json` (ADR-0016 D2).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct AnchorMap {
    pub version: u32,
    pub document_id: String,
    /// Paragraph label (without angle brackets) → ledger entry.
    #[serde(default)]
    pub anchors: BTreeMap<String, AnchorEntry>,
    /// Section keys deliberately excluded from the narrative (ADR-0016 D7).
    #[serde(default)]
    pub supporting: Vec<String>,
}

impl AnchorMap {
    pub fn new(document_id: Uuid) -> Self {
        Self {
            version: ANCHOR_MAP_VERSION,
            document_id: document_id.to_string(),
            anchors: BTreeMap::new(),
            supporting: Vec::new(),
        }
    }

    /// Parse with a version gate: newer-than-known maps are rejected rather
    /// than silently misread (the map is a ledger; misreads corrupt sync).
    pub fn parse(json: &str) -> Result<Self, ServiceError> {
        let map: AnchorMap = serde_json::from_str(json)
            .map_err(|e| ServiceError::InvalidArgument(format!("anchor map parse: {e}")))?;
        if map.version > ANCHOR_MAP_VERSION {
            return Err(ServiceError::InvalidArgument(format!(
                "anchor map version {} is newer than supported {}",
                map.version, ANCHOR_MAP_VERSION
            )));
        }
        Ok(map)
    }

    /// Deterministic serialization (BTreeMaps keep key order stable).
    pub fn serialize(&self) -> Result<String, ServiceError> {
        serde_json::to_string_pretty(self).map_err(Into::into)
    }
}

// ---------------------------------------------------------------------------
// Paragraph extraction
// ---------------------------------------------------------------------------

/// A labeled paragraph extracted from `throughline.typ`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ThroughlineParagraph {
    /// Label without angle brackets, e.g. `tl-claim`.
    pub label: String,
    /// Paragraph text with the label token removed, trimmed.
    pub body: String,
    /// SHA-256 hex of `body`.
    pub content_hash: String,
    /// Zero-based appearance order.
    pub order_index: i64,
    /// Byte offset of the paragraph's first line in the source.
    pub start: usize,
    /// Byte offset one past the paragraph's last line.
    pub end: usize,
}

/// Extract labeled paragraphs from throughline Typst source.
///
/// A paragraph is a run of non-blank lines. A paragraph belongs to the
/// throughline structure iff it contains a `<tl-...>` label token (Typst
/// label syntax; conventionally at the end of the first line). Unlabeled
/// runs (headings, prose without labels) are ignored — they render but do
/// not participate in anchoring. The first label in a run wins; duplicate
/// labels across the document keep first occurrence (later ones ignored).
pub fn extract_paragraphs(source: &str) -> Vec<ThroughlineParagraph> {
    let mut out: Vec<ThroughlineParagraph> = Vec::new();
    let mut seen: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();

    let mut run_start: Option<usize> = None;
    let mut offset = 0usize;
    let mut runs: Vec<(usize, usize)> = Vec::new();
    for line in source.split_inclusive('\n') {
        let is_blank = line.trim().is_empty();
        if is_blank {
            if let Some(s) = run_start.take() {
                runs.push((s, offset));
            }
        } else if run_start.is_none() {
            run_start = Some(offset);
        }
        offset += line.len();
    }
    if let Some(s) = run_start {
        runs.push((s, offset));
    }

    for (start, end) in runs {
        let text = &source[start..end];
        let Some(label) = find_tl_label(text) else {
            continue;
        };
        if !seen.insert(label.clone()) {
            continue;
        }
        let token = format!("<{label}>");
        let body = text.replacen(&token, "", 1).trim().to_string();
        let content_hash = BlobStore::sha256_hex(&body);
        out.push(ThroughlineParagraph {
            label,
            body,
            content_hash,
            order_index: out.len() as i64,
            start,
            end,
        });
    }
    out
}

/// Find the first `<tl-...>` label token in a text run. Label characters
/// follow Typst label rules restricted to a conservative set:
/// alphanumerics, `-`, `_`, `.`.
fn find_tl_label(text: &str) -> Option<String> {
    let mut rest = text;
    while let Some(open) = rest.find("<tl-") {
        let after = &rest[open + 1..];
        if let Some(close) = after.find('>') {
            let candidate = &after[..close];
            if !candidate.is_empty()
                && candidate
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
            {
                return Some(candidate.to_string());
            }
            rest = &after[close + 1..];
        } else {
            return None;
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Staleness derivation (pure — ADR-0016 D5)
// ---------------------------------------------------------------------------

/// Derived assessment of one anchor. Never persisted (ADR-0016 D5: anchor
/// state is derived, not stored).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct AnchorAssessment {
    pub label: String,
    /// Section keys whose current body hash differs from the ledger.
    pub manuscript_ahead: Vec<String>,
    /// True when the paragraph's current hash differs from the ledger.
    pub throughline_ahead: bool,
    /// Section keys in the ledger that no longer resolve to a section.
    pub broken: Vec<String>,
    /// True when the label exists in the ledger but not in the source
    /// (paragraph deleted or label renamed) — a broken condition on the
    /// throughline side.
    pub missing_paragraph: bool,
}

impl AnchorAssessment {
    /// Summary state string: `synced | manuscript-ahead | throughline-ahead |
    /// manuscript-ahead+throughline-ahead | broken`. Broken dominates.
    pub fn state(&self) -> String {
        if !self.broken.is_empty() || self.missing_paragraph {
            return "broken".into();
        }
        match (!self.manuscript_ahead.is_empty(), self.throughline_ahead) {
            (false, false) => "synced".into(),
            (true, false) => "manuscript-ahead".into(),
            (false, true) => "throughline-ahead".into(),
            (true, true) => "manuscript-ahead+throughline-ahead".into(),
        }
    }

    pub fn is_synced(&self) -> bool {
        self.state() == "synced"
    }
}

/// Current body hash of a section. `SectionRecord.content_hash` is only set
/// for CAS-offloaded bodies, so we always hash the (rehydrated) body — the
/// CAS digest is the same function over the same bytes, so they agree when
/// both exist.
pub fn section_body_hash(record: &SectionRecord) -> String {
    match &record.content_hash {
        Some(h) => h.clone(),
        None => BlobStore::sha256_hex(&record.body),
    }
}

/// Derive the assessment of every ledger anchor against current state.
/// Pure: no store access, no writes.
pub fn derive_anchor_states(
    map: &AnchorMap,
    sections: &[SectionRecord],
    paragraphs: &[ThroughlineParagraph],
) -> Vec<AnchorAssessment> {
    let section_hashes: BTreeMap<&str, String> = sections
        .iter()
        .map(|s| (s.section_key.as_str(), section_body_hash(s)))
        .collect();
    let paragraph_hashes: BTreeMap<&str, &str> = paragraphs
        .iter()
        .map(|p| (p.label.as_str(), p.content_hash.as_str()))
        .collect();

    map.anchors
        .iter()
        .map(|(label, entry)| {
            let mut manuscript_ahead = Vec::new();
            let mut broken = Vec::new();
            for key in &entry.section_keys {
                match section_hashes.get(key.as_str()) {
                    None => broken.push(key.clone()),
                    Some(current) => {
                        let ledger = entry.manuscript_hashes.get(key);
                        if ledger.map(|l| l != current).unwrap_or(true) {
                            manuscript_ahead.push(key.clone());
                        }
                    }
                }
            }
            let (throughline_ahead, missing_paragraph) = match paragraph_hashes.get(label.as_str())
            {
                None => (false, true),
                Some(current) => (*current != entry.throughline_hash, false),
            };
            AnchorAssessment {
                label: label.clone(),
                manuscript_ahead,
                throughline_ahead,
                broken,
                missing_paragraph,
            }
        })
        .collect()
}

/// Section keys not narrated by any anchor and not marked supporting
/// (ADR-0016 D7). Pure. Order follows the section list (document order).
pub fn derive_coverage(map: &AnchorMap, sections: &[SectionRecord]) -> Vec<String> {
    let anchored: std::collections::BTreeSet<&str> = map
        .anchors
        .values()
        .flat_map(|e| e.section_keys.iter().map(String::as_str))
        .collect();
    let supporting: std::collections::BTreeSet<&str> =
        map.supporting.iter().map(String::as_str).collect();
    sections
        .iter()
        .map(|s| s.section_key.as_str())
        .filter(|k| !anchored.contains(k) && !supporting.contains(k))
        .map(String::from)
        .collect()
}

/// Rename-repair heuristic (ADR-0016 D4): a heading rename produces a new
/// section key whose BODY is (usually) unchanged. For a broken ledger key,
/// scan the document's other sections for one whose current body hash
/// equals the ledger's recorded hash for the broken key. Exactly one match
/// → a rebind candidate; zero or ambiguous → `None` (no false rebinds).
/// Pure; the result only ever feeds a review proposal, never a silent fix.
pub fn rebind_candidate(
    broken_key: &str,
    ledger_hash: Option<&str>,
    sections: &[SectionRecord],
) -> Option<String> {
    let ledger_hash = ledger_hash?;
    let matches: Vec<&SectionRecord> = sections
        .iter()
        .filter(|s| s.section_key != broken_key && section_body_hash(s) == ledger_hash)
        .collect();
    match matches.as_slice() {
        [only] => Some(only.section_key.clone()),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Store persistence (mirror item; sidecars remain authoritative on macOS)
// ---------------------------------------------------------------------------

/// A proposed fix for one broken anchor key (ADR-0016 D4).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct RepairCandidate {
    pub label: String,
    pub broken_key: String,
    /// Unambiguous rename target, if the heuristic found exactly one.
    pub rebind_to: Option<String>,
}

/// A throughline as persisted in the shared store.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ThroughlineRecord {
    pub item_id: String,
    pub document_id: String,
    pub title: String,
    /// Typst source of the narrative.
    pub source: String,
    /// The anchor map (sync ledger).
    pub anchor_map: AnchorMap,
    pub content_hash: String,
    pub anchor_map_hash: String,
    pub paragraph_count: i64,
}

/// JSON payload persisted on the item. Field names match the
/// `throughline@1.0.0` schema in impress-core (`body_content` /
/// `anchor_map_json` per the unified-store pivot parity).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct ThroughlinePayload {
    #[serde(default)]
    title: String,
    #[serde(default)]
    document_ref: Option<String>,
    #[serde(default)]
    body_content: Option<String>,
    #[serde(default)]
    anchor_map_json: Option<String>,
    #[serde(default)]
    content_hash: Option<String>,
    #[serde(default)]
    anchor_map_hash: Option<String>,
    #[serde(default)]
    paragraph_count: Option<i64>,
}

/// Persistence + derivation façade for throughlines. Wraps the same shared
/// store as `SectionStore` (sections are read for hashing/coverage).
#[derive(Clone)]
pub struct ThroughlineStore {
    sections: Arc<SectionStore>,
}

impl ThroughlineStore {
    pub fn new(sections: Arc<SectionStore>) -> Self {
        Self { sections }
    }

    fn store(&self) -> &SharedStore {
        self.sections.shared_store()
    }

    /// Deterministic item id for a document's throughline.
    pub fn item_id(document_id: Uuid) -> Uuid {
        let name = format!("{document_id}::throughline");
        Uuid::new_v5(&THROUGHLINE_ID_NAMESPACE, name.as_bytes())
    }

    /// Scaffold source for a fresh throughline (ADR-0016 D1 activation).
    pub fn scaffold_source(title: &str) -> String {
        format!(
            "= {title}\n\n\
             // One paragraph per beat of the story. Each paragraph carries a\n\
             // stable <tl-*> label; anchor labels to manuscript sections from\n\
             // the throughline pane or via set_anchor.\n\n\
             What we claim, in one paragraph. <tl-overview>\n"
        )
    }

    /// Does this document have a throughline? Cheap opt-in check
    /// (ADR-0016 D1): one keyed get, no scan, no writes.
    pub fn has_throughline(&self, document_id: Uuid) -> Result<bool, ServiceError> {
        Ok(self
            .store()
            .get_item(Self::item_id(document_id).to_string())?
            .is_some())
    }

    /// Fetch the throughline mirror for a document, if it exists.
    pub fn get_throughline(
        &self,
        document_id: Uuid,
    ) -> Result<Option<ThroughlineRecord>, ServiceError> {
        let id = Self::item_id(document_id);
        let Some(row) = self.store().get_item(id.to_string())? else {
            return Ok(None);
        };
        let payload: ThroughlinePayload = serde_json::from_str(&row.payload_json)?;
        let source = payload.body_content.unwrap_or_default();
        let anchor_map = match payload.anchor_map_json.as_deref() {
            Some(json) => AnchorMap::parse(json)?,
            None => AnchorMap::new(document_id),
        };
        Ok(Some(ThroughlineRecord {
            item_id: id.to_string(),
            document_id: document_id.to_string(),
            title: payload.title,
            source,
            anchor_map,
            content_hash: payload.content_hash.unwrap_or_default(),
            anchor_map_hash: payload.anchor_map_hash.unwrap_or_default(),
            paragraph_count: payload.paragraph_count.unwrap_or_default(),
        }))
    }

    /// Persist a throughline (source + ledger). Idempotent on `document_id`.
    /// This is the single store-side write path — creation, sidecar mirror
    /// updates, and the sync accept path all land here.
    pub fn put_throughline(
        &self,
        document_id: Uuid,
        title: &str,
        source: &str,
        anchor_map: &AnchorMap,
    ) -> Result<ThroughlineRecord, ServiceError> {
        if anchor_map.document_id != document_id.to_string() {
            return Err(ServiceError::InvalidArgument(format!(
                "anchor map document_id {} does not match {}",
                anchor_map.document_id, document_id
            )));
        }
        let map_json = anchor_map.serialize()?;
        let paragraphs = extract_paragraphs(source);
        let payload = ThroughlinePayload {
            title: title.to_string(),
            document_ref: Some(document_id.to_string()),
            body_content: Some(source.to_string()),
            anchor_map_json: Some(map_json.clone()),
            content_hash: Some(BlobStore::sha256_hex(source)),
            anchor_map_hash: Some(BlobStore::sha256_hex(&map_json)),
            paragraph_count: Some(paragraphs.len() as i64),
        };
        let id = Self::item_id(document_id);
        self.store().upsert_item(
            id.to_string(),
            THROUGHLINE_SCHEMA_REF.to_string(),
            serde_json::to_string(&payload)?,
        )?;
        Ok(ThroughlineRecord {
            item_id: id.to_string(),
            document_id: document_id.to_string(),
            title: title.to_string(),
            source: source.to_string(),
            anchor_map: anchor_map.clone(),
            content_hash: BlobStore::sha256_hex(source),
            anchor_map_hash: BlobStore::sha256_hex(&map_json),
            paragraph_count: paragraphs.len() as i64,
        })
    }

    /// Create a throughline for a document (explicit opt-in act, ADR-0016
    /// D1). Errors if one already exists — activation is deliberate, never
    /// an upsert side effect.
    pub fn create_throughline(
        &self,
        document_id: Uuid,
        title: &str,
    ) -> Result<ThroughlineRecord, ServiceError> {
        if self.has_throughline(document_id)? {
            return Err(ServiceError::InvalidArgument(format!(
                "document {document_id} already has a throughline"
            )));
        }
        let source = Self::scaffold_source(title);
        let mut map = AnchorMap::new(document_id);
        // Baseline the scaffold paragraph so it starts `synced` with no
        // anchored sections.
        for p in extract_paragraphs(&source) {
            map.anchors.insert(
                p.label.clone(),
                AnchorEntry {
                    section_keys: vec![],
                    manuscript_hashes: BTreeMap::new(),
                    throughline_hash: p.content_hash.clone(),
                },
            );
        }
        self.put_throughline(document_id, title, &source, &map)
    }

    /// Remove a document's throughline (deactivation, ADR-0016 D1).
    pub fn delete_throughline(&self, document_id: Uuid) -> Result<bool, ServiceError> {
        let id = Self::item_id(document_id);
        if self.store().get_item(id.to_string())?.is_none() {
            return Ok(false);
        }
        self.store().delete_item(id.to_string())?;
        Ok(true)
    }

    /// Derive anchor assessments for a document's throughline against the
    /// current section store. Read-only.
    pub fn anchor_states(
        &self,
        document_id: Uuid,
    ) -> Result<Option<Vec<AnchorAssessment>>, ServiceError> {
        let Some(rec) = self.get_throughline(document_id)? else {
            return Ok(None);
        };
        let sections = self.sections.list_sections(document_id, 0)?;
        let paragraphs = extract_paragraphs(&rec.source);
        Ok(Some(derive_anchor_states(
            &rec.anchor_map,
            &sections,
            &paragraphs,
        )))
    }

    /// Coverage (unanchored, non-supporting section keys). Read-only.
    pub fn coverage(&self, document_id: Uuid) -> Result<Option<Vec<String>>, ServiceError> {
        let Some(rec) = self.get_throughline(document_id)? else {
            return Ok(None);
        };
        let sections = self.sections.list_sections(document_id, 0)?;
        Ok(Some(derive_coverage(&rec.anchor_map, &sections)))
    }

    /// Repair candidates for every broken anchor of a document
    /// (ADR-0016 D4). Read-only; feeds repair proposals, never applies.
    pub fn repair_candidates(
        &self,
        document_id: Uuid,
    ) -> Result<Option<Vec<RepairCandidate>>, ServiceError> {
        let Some(rec) = self.get_throughline(document_id)? else {
            return Ok(None);
        };
        let sections = self.sections.list_sections(document_id, 0)?;
        let paragraphs = extract_paragraphs(&rec.source);
        let states = derive_anchor_states(&rec.anchor_map, &sections, &paragraphs);
        let mut out = Vec::new();
        for a in states {
            for broken_key in &a.broken {
                let ledger_hash = rec
                    .anchor_map
                    .anchors
                    .get(&a.label)
                    .and_then(|e| e.manuscript_hashes.get(broken_key))
                    .map(String::as_str);
                out.push(RepairCandidate {
                    label: a.label.clone(),
                    broken_key: broken_key.clone(),
                    rebind_to: rebind_candidate(broken_key, ledger_hash, &sections),
                });
            }
        }
        Ok(Some(out))
    }

    /// Anchor a paragraph label to a set of section keys, baselining the
    /// ledger hashes at current state (a human act — establishing the
    /// baseline is equivalent to accepting a sync, ADR-0016 D6).
    pub fn set_anchor(
        &self,
        document_id: Uuid,
        label: &str,
        section_keys: &[String],
    ) -> Result<ThroughlineRecord, ServiceError> {
        let Some(rec) = self.get_throughline(document_id)? else {
            return Err(ServiceError::InvalidArgument(format!(
                "document {document_id} has no throughline"
            )));
        };
        let paragraphs = extract_paragraphs(&rec.source);
        let paragraph = paragraphs
            .iter()
            .find(|p| p.label == label)
            .ok_or_else(|| {
                ServiceError::InvalidArgument(format!(
                    "no paragraph labeled <{label}> in throughline"
                ))
            })?;
        let sections = self.sections.list_sections(document_id, 0)?;
        let mut manuscript_hashes = BTreeMap::new();
        for key in section_keys {
            let section = sections
                .iter()
                .find(|s| &s.section_key == key)
                .ok_or_else(|| {
                    ServiceError::InvalidArgument(format!("unknown section key '{key}'"))
                })?;
            manuscript_hashes.insert(key.clone(), section_body_hash(section));
        }
        let mut map = rec.anchor_map.clone();
        map.anchors.insert(
            label.to_string(),
            AnchorEntry {
                section_keys: section_keys.to_vec(),
                manuscript_hashes,
                throughline_hash: paragraph.content_hash.clone(),
            },
        );
        // Anchoring a section supersedes any "supporting" marking.
        map.supporting.retain(|k| !section_keys.contains(k));
        self.put_throughline(document_id, &rec.title, &rec.source, &map)
    }

    /// Remove an anchor from the ledger.
    pub fn remove_anchor(
        &self,
        document_id: Uuid,
        label: &str,
    ) -> Result<ThroughlineRecord, ServiceError> {
        let Some(rec) = self.get_throughline(document_id)? else {
            return Err(ServiceError::InvalidArgument(format!(
                "document {document_id} has no throughline"
            )));
        };
        let mut map = rec.anchor_map.clone();
        map.anchors.remove(label);
        self.put_throughline(document_id, &rec.title, &rec.source, &map)
    }

    /// Mark or unmark a section as deliberate supporting detail
    /// (ADR-0016 D7).
    pub fn mark_supporting(
        &self,
        document_id: Uuid,
        section_key: &str,
        supporting: bool,
    ) -> Result<ThroughlineRecord, ServiceError> {
        let Some(rec) = self.get_throughline(document_id)? else {
            return Err(ServiceError::InvalidArgument(format!(
                "document {document_id} has no throughline"
            )));
        };
        let mut map = rec.anchor_map.clone();
        map.supporting.retain(|k| k != section_key);
        if supporting {
            map.supporting.push(section_key.to_string());
            map.supporting.sort();
        }
        self.put_throughline(document_id, &rec.title, &rec.source, &map)
    }

    /// Update the throughline source (an edit to the narrative). The ledger
    /// is NOT touched — edited paragraphs will derive `throughline-ahead`
    /// until a sync proposal is accepted (ADR-0016 D5/D6).
    pub fn update_source(
        &self,
        document_id: Uuid,
        source: &str,
    ) -> Result<ThroughlineRecord, ServiceError> {
        let Some(rec) = self.get_throughline(document_id)? else {
            return Err(ServiceError::InvalidArgument(format!(
                "document {document_id} has no throughline"
            )));
        };
        self.put_throughline(document_id, &rec.title, source, &rec.anchor_map)
    }

    /// Accept-path ledger update (ADR-0016 D6): after a sync proposal for
    /// `label` is applied, re-baseline that anchor's hashes to current
    /// state. Fails if the anchor is unknown. `document_moved` guard: the
    /// caller passes the hashes the proposal was computed against; if the
    /// current state no longer matches, the update is refused so the
    /// proposal can be invalidated and respawned rather than force-applied.
    pub fn record_sync_accepted(
        &self,
        document_id: Uuid,
        label: &str,
        expected_section_hashes: &BTreeMap<String, String>,
        expected_throughline_hash: Option<&str>,
    ) -> Result<ThroughlineRecord, ServiceError> {
        let Some(rec) = self.get_throughline(document_id)? else {
            return Err(ServiceError::InvalidArgument(format!(
                "document {document_id} has no throughline"
            )));
        };
        let mut map = rec.anchor_map.clone();
        let entry = map.anchors.get_mut(label).ok_or_else(|| {
            ServiceError::InvalidArgument(format!("no anchor for label <{label}>"))
        })?;

        let sections = self.sections.list_sections(document_id, 0)?;
        let paragraphs = extract_paragraphs(&rec.source);
        let paragraph = paragraphs
            .iter()
            .find(|p| p.label == label)
            .ok_or_else(|| {
                ServiceError::InvalidArgument(format!(
                    "no paragraph labeled <{label}> in throughline"
                ))
            })?;

        // Stale-proposal guard.
        for (key, expected) in expected_section_hashes {
            let current = sections
                .iter()
                .find(|s| &s.section_key == key)
                .map(section_body_hash);
            if current.as_deref() != Some(expected.as_str()) {
                return Err(ServiceError::InvalidArgument(format!(
                    "section '{key}' changed since the proposal was computed; \
                     proposal must be recomputed"
                )));
            }
        }
        if let Some(expected) = expected_throughline_hash {
            if paragraph.content_hash != expected {
                return Err(ServiceError::InvalidArgument(
                    "throughline paragraph changed since the proposal was computed; \
                     proposal must be recomputed"
                        .into(),
                ));
            }
        }

        let mut manuscript_hashes = BTreeMap::new();
        for key in &entry.section_keys {
            if let Some(section) = sections.iter().find(|s| &s.section_key == key) {
                manuscript_hashes.insert(key.clone(), section_body_hash(section));
            }
        }
        entry.manuscript_hashes = manuscript_hashes;
        entry.throughline_hash = paragraph.content_hash.clone();
        self.put_throughline(document_id, &rec.title, &rec.source, &map)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sections::SectionMetadata;

    fn test_store() -> (ThroughlineStore, Arc<SectionStore>, tempfile::TempDir) {
        let tmp = tempfile::tempdir().expect("tempdir");
        let sections = Arc::new(
            SectionStore::open_in_memory(tmp.path().to_path_buf()).expect("in-memory store"),
        );
        (ThroughlineStore::new(sections.clone()), sections, tmp)
    }

    fn put_test_section(sections: &SectionStore, doc: Uuid, key: &str, body: &str) {
        sections
            .put_section(
                doc,
                key,
                body,
                SectionMetadata {
                    title: Some(key.to_string()),
                    section_type: None,
                    order_index: None,
                },
            )
            .expect("put_section");
    }

    // ---- extraction ----

    #[test]
    fn extracts_labeled_paragraphs_in_order() {
        let src = "= Title\n\nWe claim X. <tl-claim>\n\nUnlabeled prose.\n\nIt matters because Y.\n<tl-why>\n";
        let ps = extract_paragraphs(src);
        assert_eq!(ps.len(), 2);
        assert_eq!(ps[0].label, "tl-claim");
        assert_eq!(ps[0].body, "We claim X.");
        assert_eq!(ps[0].order_index, 0);
        assert_eq!(ps[1].label, "tl-why");
        assert_eq!(ps[1].body, "It matters because Y.");
    }

    #[test]
    fn duplicate_labels_keep_first() {
        let src = "First. <tl-a>\n\nSecond. <tl-a>\n";
        let ps = extract_paragraphs(src);
        assert_eq!(ps.len(), 1);
        assert_eq!(ps[0].body, "First.");
    }

    #[test]
    fn ignores_non_tl_angle_tokens() {
        let src = "Compare a < b and c > d. <not-a-label>\n\nReal. <tl-real>\n";
        let ps = extract_paragraphs(src);
        assert_eq!(ps.len(), 1);
        assert_eq!(ps[0].label, "tl-real");
    }

    #[test]
    fn paragraph_hash_is_body_hash() {
        let ps = extract_paragraphs("Some text. <tl-x>\n");
        assert_eq!(ps[0].content_hash, BlobStore::sha256_hex("Some text."));
    }

    // ---- anchor map ----

    #[test]
    fn anchor_map_round_trip() {
        let doc = Uuid::new_v4();
        let mut map = AnchorMap::new(doc);
        map.anchors.insert(
            "tl-claim".into(),
            AnchorEntry {
                section_keys: vec!["intro".into()],
                manuscript_hashes: [("intro".to_string(), "abc".to_string())].into(),
                throughline_hash: "def".into(),
            },
        );
        map.supporting.push("appendix".into());
        let json = map.serialize().unwrap();
        let back = AnchorMap::parse(&json).unwrap();
        assert_eq!(map, back);
    }

    #[test]
    fn anchor_map_rejects_newer_version() {
        let json = format!(
            r#"{{"version": {}, "document_id": "x", "anchors": {{}}, "supporting": []}}"#,
            ANCHOR_MAP_VERSION + 1
        );
        assert!(AnchorMap::parse(&json).is_err());
    }

    // ---- derivation ----

    #[test]
    fn derivation_four_states() {
        let doc = Uuid::new_v4();
        let (_tl, sections, _tmp) = test_store();
        put_test_section(&sections, doc, "intro", "intro body v1");
        put_test_section(&sections, doc, "results", "results body v1");
        let recs = sections.list_sections(doc, 0).unwrap();

        let src = "P1. <tl-a>\n\nP2 edited. <tl-b>\n";
        let ps = extract_paragraphs(src);

        let mut map = AnchorMap::new(doc);
        // tl-a: ledger matches everything → synced
        map.anchors.insert(
            "tl-a".into(),
            AnchorEntry {
                section_keys: vec!["intro".into()],
                manuscript_hashes: [("intro".to_string(), BlobStore::sha256_hex("intro body v1"))]
                    .into(),
                throughline_hash: ps[0].content_hash.clone(),
            },
        );
        // tl-b: ledger has stale manuscript hash AND stale paragraph hash
        map.anchors.insert(
            "tl-b".into(),
            AnchorEntry {
                section_keys: vec!["results".into()],
                manuscript_hashes: [("results".to_string(), "old-hash".to_string())].into(),
                throughline_hash: "old-paragraph-hash".into(),
            },
        );
        // tl-c: ledger references a section that doesn't exist and a
        // paragraph that doesn't exist → broken
        map.anchors.insert(
            "tl-c".into(),
            AnchorEntry {
                section_keys: vec!["ghost".into()],
                manuscript_hashes: BTreeMap::new(),
                throughline_hash: "x".into(),
            },
        );

        let states = derive_anchor_states(&map, &recs, &ps);
        let by_label: BTreeMap<&str, &AnchorAssessment> =
            states.iter().map(|a| (a.label.as_str(), a)).collect();
        assert_eq!(by_label["tl-a"].state(), "synced");
        assert_eq!(
            by_label["tl-b"].state(),
            "manuscript-ahead+throughline-ahead"
        );
        assert_eq!(by_label["tl-c"].state(), "broken");
        assert!(by_label["tl-c"].missing_paragraph);
        assert_eq!(by_label["tl-c"].broken, vec!["ghost".to_string()]);
    }

    #[test]
    fn derivation_is_deterministic_and_pure() {
        let doc = Uuid::new_v4();
        let map = AnchorMap::new(doc);
        let a = derive_anchor_states(&map, &[], &[]);
        let b = derive_anchor_states(&map, &[], &[]);
        assert_eq!(a, b);
        assert!(a.is_empty());
    }

    #[test]
    fn coverage_excludes_anchored_and_supporting() {
        let doc = Uuid::new_v4();
        let (_tl, sections, _tmp) = test_store();
        for key in ["intro", "methods", "results", "appendix"] {
            put_test_section(&sections, doc, key, "body");
        }
        let recs = sections.list_sections(doc, 0).unwrap();
        let mut map = AnchorMap::new(doc);
        map.anchors.insert(
            "tl-a".into(),
            AnchorEntry {
                section_keys: vec!["intro".into(), "results".into()],
                ..Default::default()
            },
        );
        map.supporting.push("appendix".into());
        assert_eq!(derive_coverage(&map, &recs), vec!["methods".to_string()]);
    }

    // ---- store round-trip + opt-in ----

    #[test]
    fn create_get_delete_round_trip() {
        let doc = Uuid::new_v4();
        let (tl, _sections, _tmp) = test_store();
        assert!(!tl.has_throughline(doc).unwrap());
        assert!(tl.get_throughline(doc).unwrap().is_none());
        assert!(tl.anchor_states(doc).unwrap().is_none());
        assert!(tl.coverage(doc).unwrap().is_none());

        let rec = tl.create_throughline(doc, "My Story").unwrap();
        assert_eq!(rec.paragraph_count, 1);
        assert!(tl.has_throughline(doc).unwrap());
        // Creation is deliberate: second create errors.
        assert!(tl.create_throughline(doc, "Again").is_err());

        let back = tl.get_throughline(doc).unwrap().unwrap();
        assert_eq!(back.title, "My Story");
        assert_eq!(back.source, rec.source);
        assert_eq!(back.anchor_map, rec.anchor_map);

        // Scaffold paragraph starts synced (baselined at creation).
        let states = tl.anchor_states(doc).unwrap().unwrap();
        assert_eq!(states.len(), 1);
        assert_eq!(states[0].state(), "synced");

        assert!(tl.delete_throughline(doc).unwrap());
        assert!(!tl.has_throughline(doc).unwrap());
        assert!(!tl.delete_throughline(doc).unwrap());
    }

    #[test]
    fn set_anchor_baselines_and_manuscript_edit_goes_stale() {
        let doc = Uuid::new_v4();
        let (tl, sections, _tmp) = test_store();
        put_test_section(&sections, doc, "intro", "intro v1");
        tl.create_throughline(doc, "Story").unwrap();
        tl.set_anchor(doc, "tl-overview", &["intro".to_string()])
            .unwrap();

        let states = tl.anchor_states(doc).unwrap().unwrap();
        assert_eq!(states[0].state(), "synced");

        // Manuscript section changes → manuscript-ahead.
        put_test_section(&sections, doc, "intro", "intro v2");
        let states = tl.anchor_states(doc).unwrap().unwrap();
        assert_eq!(states[0].state(), "manuscript-ahead");
        assert_eq!(states[0].manuscript_ahead, vec!["intro".to_string()]);
    }

    #[test]
    fn throughline_edit_goes_throughline_ahead_ledger_untouched() {
        let doc = Uuid::new_v4();
        let (tl, sections, _tmp) = test_store();
        put_test_section(&sections, doc, "intro", "intro v1");
        tl.create_throughline(doc, "Story").unwrap();
        tl.set_anchor(doc, "tl-overview", &["intro".to_string()])
            .unwrap();
        let ledger_before = tl.get_throughline(doc).unwrap().unwrap().anchor_map;

        tl.update_source(doc, "A bolder claim. <tl-overview>\n")
            .unwrap();
        let rec = tl.get_throughline(doc).unwrap().unwrap();
        assert_eq!(rec.anchor_map, ledger_before, "edit must not touch ledger");
        let states = tl.anchor_states(doc).unwrap().unwrap();
        assert_eq!(states[0].state(), "throughline-ahead");
    }

    #[test]
    fn record_sync_accepted_rebaselines_and_guards_races() {
        let doc = Uuid::new_v4();
        let (tl, sections, _tmp) = test_store();
        put_test_section(&sections, doc, "intro", "intro v1");
        tl.create_throughline(doc, "Story").unwrap();
        tl.set_anchor(doc, "tl-overview", &["intro".to_string()])
            .unwrap();

        // Drift the manuscript.
        put_test_section(&sections, doc, "intro", "intro v2");
        let v2_hash = BlobStore::sha256_hex("intro v2");

        // Stale-proposal guard: expected hash mismatch is refused.
        let stale: BTreeMap<String, String> =
            [("intro".to_string(), "not-the-current-hash".to_string())].into();
        assert!(tl
            .record_sync_accepted(doc, "tl-overview", &stale, None)
            .is_err());

        // Accept with correct expectations → synced.
        let expected: BTreeMap<String, String> = [("intro".to_string(), v2_hash)].into();
        tl.record_sync_accepted(doc, "tl-overview", &expected, None)
            .unwrap();
        let states = tl.anchor_states(doc).unwrap().unwrap();
        assert_eq!(states[0].state(), "synced");
    }

    #[test]
    fn mark_supporting_round_trip() {
        let doc = Uuid::new_v4();
        let (tl, sections, _tmp) = test_store();
        put_test_section(&sections, doc, "appendix", "detail");
        tl.create_throughline(doc, "Story").unwrap();
        assert_eq!(
            tl.coverage(doc).unwrap().unwrap(),
            vec!["appendix".to_string()]
        );
        tl.mark_supporting(doc, "appendix", true).unwrap();
        assert!(tl.coverage(doc).unwrap().unwrap().is_empty());
        tl.mark_supporting(doc, "appendix", false).unwrap();
        assert_eq!(
            tl.coverage(doc).unwrap().unwrap(),
            vec!["appendix".to_string()]
        );
    }

    #[test]
    fn deterministic_item_id() {
        let doc = Uuid::parse_str("6e2a0000-0000-0000-0000-000000000000").unwrap();
        assert_eq!(
            ThroughlineStore::item_id(doc),
            ThroughlineStore::item_id(doc)
        );
        assert_ne!(
            ThroughlineStore::item_id(doc),
            ThroughlineStore::item_id(Uuid::new_v4())
        );
    }
}
