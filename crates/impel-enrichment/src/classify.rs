//! Classification behind a trait so the LLM backing can arrive later
//! (ADR-0015 D6): today's implementation is a deterministic keyword
//! heuristic — enough to exercise the pipeline and the review checkpoint.

use async_trait::async_trait;

/// One proposed tag with a confidence in `[0, 1]`.
#[derive(Debug, Clone, PartialEq)]
pub struct Classification {
    pub tag: String,
    pub confidence: f64,
}

/// Produces tag proposals for a paper. Implementations must be pure with
/// respect to their inputs (same title/abstract → same proposals) so
/// `prompt_hash` reproducibility holds.
#[async_trait]
pub trait Classifier: Send + Sync {
    /// Identifier recorded in `agent-run.model` (e.g. `"heuristic-v1"`,
    /// `"claude-opus-4-8"`).
    fn model_id(&self) -> &str;

    async fn classify(&self, title: &str, abstract_text: &str) -> Vec<Classification>;
}

/// Keyword-table classifier. Confidence is the fraction of a tag's
/// keywords found in the text, so multi-keyword tags need corroboration.
pub struct HeuristicClassifier {
    /// `(tag, keywords)` — tag proposed when any keyword matches.
    table: Vec<(String, Vec<String>)>,
}

impl HeuristicClassifier {
    pub fn new(table: Vec<(String, Vec<String>)>) -> Self {
        Self { table }
    }

    /// A small default vocabulary for astronomy-flavored corpora — the
    /// suite's home domain. Real deployments supply their own table or an
    /// LLM-backed `Classifier`.
    pub fn default_vocabulary() -> Self {
        let t = |tag: &str, kws: &[&str]| {
            (
                tag.to_string(),
                kws.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            )
        };
        Self::new(vec![
            t("ai/topic/cosmology", &["cosmology", "dark energy", "cmb"]),
            t("ai/topic/galaxies", &["galaxy", "galaxies", "galactic"]),
            t("ai/methods/simulation", &["simulation", "hydrodynamic", "n-body"]),
            t("ai/methods/ml", &["neural network", "machine learning", "deep learning"]),
        ])
    }
}

#[async_trait]
impl Classifier for HeuristicClassifier {
    fn model_id(&self) -> &str {
        "heuristic-v1"
    }

    async fn classify(&self, title: &str, abstract_text: &str) -> Vec<Classification> {
        let text = format!("{title} {abstract_text}").to_lowercase();
        self.table
            .iter()
            .filter_map(|(tag, keywords)| {
                let hits = keywords.iter().filter(|k| text.contains(k.as_str())).count();
                if hits == 0 {
                    return None;
                }
                Some(Classification {
                    tag: tag.clone(),
                    confidence: hits as f64 / keywords.len() as f64,
                })
            })
            .collect()
    }
}
