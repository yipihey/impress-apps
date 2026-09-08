//! Source priority for enrichment merge tie-breaking.
//!
//! Mirrors `EnrichmentSource` (`EnrichmentTypes.swift`) plus the broader set
//! of sources used by `BuiltIn/*` plugins. The default ordering is:
//!
//! ```text
//! ADS > Crossref > arXiv > OpenAlex > PubMed > Semantic Scholar > DBLP > WoS > Unknown
//! ```
//!
//! Rationale (from the Swift code and accompanying docs):
//! - ADS is canonical for astronomy/physics and has the richest field coverage.
//! - Crossref provides authoritative DOI metadata.
//! - arXiv is the source of truth for preprint identifiers.
//! - OpenAlex aggregates across many providers.
//! - PubMed dominates biomedical metadata.
//! - Semantic Scholar / DBLP / WoS round out CS and bibliometric coverage.
//!
//! The default order is configurable per-user in the Swift settings (`EnrichmentSettings.sourcePriority`).

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Stable string IDs for the enrichment sources we know about. New sources
/// can be added without breaking serialization.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct EnrichmentSourceId(pub String);

impl EnrichmentSourceId {
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into().to_lowercase())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<&str> for EnrichmentSourceId {
    fn from(s: &str) -> Self {
        Self::new(s)
    }
}

impl From<String> for EnrichmentSourceId {
    fn from(s: String) -> Self {
        Self::new(s)
    }
}

/// Ordered priority list. Earlier sources win field-level conflicts.
///
/// `SourcePriority::default()` returns the canonical
/// `ADS > Crossref > arXiv > OpenAlex > PubMed > Semantic Scholar > DBLP > WoS`
/// ordering.
#[derive(Debug, Clone)]
pub struct SourcePriority {
    /// Ordered list; index 0 is highest priority.
    order: Vec<EnrichmentSourceId>,
    /// Cache: source id → rank (0 = highest). Recomputed on construction.
    rank_cache: HashMap<EnrichmentSourceId, usize>,
}

impl SourcePriority {
    /// Build a priority list. Duplicates in `order` are kept (first
    /// occurrence wins). Unknown sources passed to `rank()` get
    /// `usize::MAX`.
    pub fn new(order: Vec<EnrichmentSourceId>) -> Self {
        let mut rank_cache = HashMap::with_capacity(order.len());
        for (i, src) in order.iter().enumerate() {
            // Only record the *first* index for each source.
            rank_cache.entry(src.clone()).or_insert(i);
        }
        Self { order, rank_cache }
    }

    /// Rank of a source (0 = highest). Returns `usize::MAX` for unknowns,
    /// so they always lose tie-breaks to any known source.
    pub fn rank(&self, source: &EnrichmentSourceId) -> usize {
        self.rank_cache.get(source).copied().unwrap_or(usize::MAX)
    }

    /// True if `a` has strictly higher priority than `b`.
    pub fn outranks(&self, a: &EnrichmentSourceId, b: &EnrichmentSourceId) -> bool {
        self.rank(a) < self.rank(b)
    }

    /// Read-only access to the ordered list.
    pub fn ordered(&self) -> &[EnrichmentSourceId] {
        &self.order
    }
}

impl Default for SourcePriority {
    fn default() -> Self {
        Self::new(vec![
            EnrichmentSourceId::new("ads"),
            EnrichmentSourceId::new("crossref"),
            EnrichmentSourceId::new("arxiv"),
            EnrichmentSourceId::new("openalex"),
            EnrichmentSourceId::new("pubmed"),
            EnrichmentSourceId::new("semanticscholar"),
            EnrichmentSourceId::new("dblp"),
            EnrichmentSourceId::new("wos"),
        ])
    }
}

// ---------------------------------------------------------------------------
// Cross-process preferences
// ---------------------------------------------------------------------------

/// The shared enrichment preferences file inside a workspace.
///
/// A FILE rather than `UserDefaults`, because the two processes that need this
/// number cannot share a defaults domain: imbib writes its settings to its own
/// app domain, and `impel-taskd` is a different, sandboxed executable that
/// cannot read it. Since D1 made impel the enrichment authority whenever it is
/// installed, a setting only imbib can see is a setting the enricher ignores —
/// which is exactly what happened: the daemon ran on
/// [`SourcePriority::default`] while the user's configured order sat unread in
/// imbib's preferences.
///
/// Same shape as the workspace files the AI stack uses (ADR-0029's
/// `ai/preferences.json`): Rust owns the format, every app and daemon reads it.
pub fn preferences_path(workspace: impl AsRef<Path>) -> PathBuf {
    workspace
        .as_ref()
        .join("enrichment")
        .join("preferences.json")
}

/// On-disk form. Versioned so a future field cannot make an old reader guess.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct EnrichmentPreferences {
    pub version: u32,
    /// Source ids, highest priority first. Lowercased on read — imbib's own
    /// enum spells them `ads`, `crossref`, … but a hand-edited file may not.
    pub source_priority: Vec<String>,
}

/// The version this build writes and understands.
pub const PREFERENCES_VERSION: u32 = 1;

impl SourcePriority {
    /// Read the user's configured order from the workspace.
    ///
    /// `None` for every ordinary absence — no file, unreadable, malformed,
    /// a version this build does not know, or an empty list — because each of
    /// those means "no configured preference", and the caller's
    /// [`SourcePriority::default`] is the right answer for all of them. A
    /// daemon must not refuse to enrich because a preferences file has a typo.
    pub fn load_from_workspace(workspace: impl AsRef<Path>) -> Option<Self> {
        let bytes = std::fs::read(preferences_path(workspace)).ok()?;
        let prefs: EnrichmentPreferences = serde_json::from_slice(&bytes).ok()?;
        if prefs.version != PREFERENCES_VERSION || prefs.source_priority.is_empty() {
            return None;
        }
        Some(Self::with_preferred_prefix(&prefs.source_priority))
    }

    /// The user's chosen sources first, in their order; every other source
    /// this build knows keeps its default rank behind them.
    ///
    /// A prefix, NOT a replacement, because the two vocabularies are not the
    /// same size: imbib's settings enum offers `ads`, `wos` and `openalex`,
    /// while the default order also ranks `crossref`, `arxiv`, `pubmed`,
    /// `semanticscholar` and `dblp`. Taking the mirrored list literally would
    /// drop those five to `usize::MAX` — below every known source — so
    /// metadata the user never expressed an opinion about would start losing
    /// merges it used to win, purely because they reordered the three they
    /// were offered.
    pub fn with_preferred_prefix(preferred: &[String]) -> Self {
        let mut order: Vec<EnrichmentSourceId> =
            preferred.iter().map(EnrichmentSourceId::new).collect();
        let mut seen: std::collections::HashSet<EnrichmentSourceId> =
            order.iter().cloned().collect();
        for fallback in Self::default().order {
            if seen.insert(fallback.clone()) {
                order.push(fallback);
            }
        }
        Self::new(order)
    }

    /// Write this order where every app and daemon can read it.
    pub fn save_to_workspace(&self, workspace: impl AsRef<Path>) -> std::io::Result<()> {
        let path = preferences_path(workspace);
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let prefs = EnrichmentPreferences {
            version: PREFERENCES_VERSION,
            source_priority: self.ordered().iter().map(|s| s.0.clone()).collect(),
        };
        let json = serde_json::to_vec_pretty(&prefs)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        std::fs::write(path, json)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_order_matches_swift() {
        let p = SourcePriority::default();
        assert_eq!(p.rank(&"ads".into()), 0);
        assert_eq!(p.rank(&"crossref".into()), 1);
        assert_eq!(p.rank(&"arxiv".into()), 2);
        assert_eq!(p.rank(&"openalex".into()), 3);
        assert_eq!(p.rank(&"pubmed".into()), 4);
        assert_eq!(p.rank(&"semanticscholar".into()), 5);
        assert_eq!(p.rank(&"dblp".into()), 6);
        assert_eq!(p.rank(&"wos".into()), 7);
    }

    #[test]
    fn case_insensitive() {
        let p = SourcePriority::default();
        assert_eq!(p.rank(&"ADS".into()), 0);
        assert_eq!(p.rank(&"Crossref".into()), 1);
    }

    #[test]
    fn unknown_source_is_lowest() {
        let p = SourcePriority::default();
        assert_eq!(p.rank(&"mystery".into()), usize::MAX);
        assert!(!p.outranks(&"mystery".into(), &"ads".into()));
        assert!(p.outranks(&"ads".into(), &"mystery".into()));
    }

    #[test]
    fn outranks_strict() {
        let p = SourcePriority::default();
        assert!(p.outranks(&"ads".into(), &"crossref".into()));
        assert!(!p.outranks(&"crossref".into(), &"ads".into()));
        // Same source = not a strict outrank.
        assert!(!p.outranks(&"ads".into(), &"ads".into()));
    }

    #[test]
    fn custom_order_overrides_default() {
        let p = SourcePriority::new(vec!["openalex".into(), "ads".into()]);
        assert!(p.outranks(&"openalex".into(), &"ads".into()));
        assert_eq!(p.rank(&"crossref".into()), usize::MAX);
    }

    #[test]
    fn duplicates_in_order_keep_first_index() {
        let p = SourcePriority::new(vec!["ads".into(), "crossref".into(), "ads".into()]);
        // ADS keeps rank 0 (first occurrence), Crossref at 1.
        assert_eq!(p.rank(&"ads".into()), 0);
        assert_eq!(p.rank(&"crossref".into()), 1);
    }

    /// The exact JSON imbib's Swift settings store writes. Rust owns this
    /// format and Swift emits it by hand (no FFI, so no xcframework rebuild),
    /// which means the two can drift silently — a reader that expects a key
    /// the writer stopped emitting returns "no preference" and the daemon
    /// falls back to the default order, looking exactly like a user who never
    /// configured anything. This literal is the contract; change it here and
    /// in `EnrichmentSettingsStore.persistSourcePriorityForDaemon` together.
    #[test]
    fn the_swift_written_file_shape_parses() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("enrichment")).unwrap();
        std::fs::write(
            preferences_path(dir.path()),
            r#"{"version":1,"source_priority":["crossref","ads","arxiv"]}"#,
        )
        .unwrap();

        let loaded = SourcePriority::load_from_workspace(dir.path()).expect("parses");
        assert_eq!(
            loaded.rank(&"crossref".into()),
            0,
            "the user put Crossref first"
        );
        assert_eq!(loaded.rank(&"ads".into()), 1);
        assert_eq!(loaded.rank(&"arxiv".into()), 2);
        // …and a source the user never mentioned still outranks the unknown
        // floor, rather than being demoted by its absence.
        assert!(
            loaded.rank(&"pubmed".into()) < usize::MAX,
            "unmentioned sources keep their default standing"
        );
    }

    /// imbib's settings enum offers three sources; the default order ranks
    /// eight. Reordering the three must not silently demote the other five
    /// below every known source.
    #[test]
    fn a_configured_prefix_does_not_demote_the_sources_it_omits() {
        let configured = SourcePriority::with_preferred_prefix(&["openalex".to_string()]);
        assert_eq!(configured.rank(&"openalex".into()), 0);

        for source in SourcePriority::default().ordered() {
            assert!(
                configured.rank(source) < usize::MAX,
                "{} fell off the list entirely",
                source.as_str()
            );
        }
        // Relative order among the untouched sources is preserved.
        assert!(configured.rank(&"ads".into()) < configured.rank(&"crossref".into()));
        assert!(configured.rank(&"crossref".into()) < configured.rank(&"arxiv".into()));
    }

    #[test]
    fn a_saved_order_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let configured = SourcePriority::new(vec!["openalex".into(), "ads".into()]);
        configured.save_to_workspace(dir.path()).unwrap();

        let loaded = SourcePriority::load_from_workspace(dir.path()).expect("round trip");
        assert_eq!(loaded.rank(&"openalex".into()), 0);
        assert_eq!(loaded.rank(&"ads".into()), 1);
        assert!(
            loaded.rank(&"crossref".into()) > 1,
            "the rest follow behind"
        );
    }

    /// Every ordinary absence reads as "no preference", never as an error: a
    /// daemon that refused to enrich because a preferences file had a typo
    /// would be worse than one that used the default order.
    #[test]
    fn absent_malformed_and_unknown_versions_all_mean_no_preference() {
        let dir = tempfile::tempdir().unwrap();
        assert!(
            SourcePriority::load_from_workspace(dir.path()).is_none(),
            "no file"
        );

        std::fs::create_dir_all(dir.path().join("enrichment")).unwrap();
        for bad in [
            "not json at all",
            r#"{"version":99,"source_priority":["ads"]}"#,
            r#"{"version":1,"source_priority":[]}"#,
        ] {
            std::fs::write(preferences_path(dir.path()), bad).unwrap();
            assert!(
                SourcePriority::load_from_workspace(dir.path()).is_none(),
                "should read as no preference: {bad}"
            );
        }
    }
}
