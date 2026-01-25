//! Semantic search using text embeddings
//!
//! Enables "find similar papers" functionality by computing
//! vector embeddings and using cosine similarity.

use fastembed::{EmbeddingModel, InitOptions, TextEmbedding};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum EmbeddingError {
    #[error("Model initialization failed: {0}")]
    InitError(String),
    #[error("Embedding generation failed: {0}")]
    EmbeddingFailed(String),
    #[error("Invalid input: {0}")]
    InvalidInput(String),
}

/// Embedding vector for a publication
#[derive(uniffi::Record, Clone, Debug)]
pub struct PublicationEmbedding {
    pub publication_id: String,
    pub vector: Vec<f32>,
    pub model: String,
}

/// Semantic search engine
pub struct SemanticSearch {
    model: TextEmbedding,
    model_name: String,
}

impl SemanticSearch {
    /// Initialize with the default model (all-MiniLM-L6-v2)
    pub fn new() -> Result<Self, EmbeddingError> {
        Self::with_model(EmbeddingModel::AllMiniLML6V2)
    }

    /// Initialize with a specific model
    pub fn with_model(model: EmbeddingModel) -> Result<Self, EmbeddingError> {
        let model_name = format!("{:?}", model);

        let options = InitOptions::new(model).with_show_download_progress(true);
        let text_embedding = TextEmbedding::try_new(options)
            .map_err(|e| EmbeddingError::InitError(e.to_string()))?;

        Ok(Self {
            model: text_embedding,
            model_name,
        })
    }

    /// Generate embedding for a publication
    ///
    /// Combines title, authors, and abstract for best results
    pub fn embed_publication(
        &self,
        publication_id: &str,
        title: &str,
        authors: &[String],
        abstract_text: Option<&str>,
    ) -> Result<PublicationEmbedding, EmbeddingError> {
        // Combine fields into a single text
        let mut text = title.to_string();

        if !authors.is_empty() {
            text.push_str(". Authors: ");
            text.push_str(&authors.join(", "));
        }

        if let Some(abstract_str) = abstract_text {
            text.push_str(". ");
            // Truncate abstract if too long (model has token limit)
            let truncated = if abstract_str.len() > 1000 {
                &abstract_str[..1000]
            } else {
                abstract_str
            };
            text.push_str(truncated);
        }

        let embeddings = self
            .model
            .embed(vec![text], None)
            .map_err(|e| EmbeddingError::EmbeddingFailed(e.to_string()))?;

        let vector = embeddings
            .into_iter()
            .next()
            .ok_or_else(|| EmbeddingError::EmbeddingFailed("No embedding returned".to_string()))?;

        Ok(PublicationEmbedding {
            publication_id: publication_id.to_string(),
            vector,
            model: self.model_name.clone(),
        })
    }

    /// Generate embeddings for multiple publications
    pub fn embed_publications(
        &self,
        publications: Vec<(String, String, Vec<String>, Option<String>)>,
    ) -> Result<Vec<PublicationEmbedding>, EmbeddingError> {
        let texts: Vec<String> = publications
            .iter()
            .map(|(_, title, authors, abstract_text)| {
                let mut text = title.clone();
                if !authors.is_empty() {
                    text.push_str(". Authors: ");
                    text.push_str(&authors.join(", "));
                }
                if let Some(abs) = abstract_text {
                    text.push_str(". ");
                    let truncated = if abs.len() > 1000 { &abs[..1000] } else { abs };
                    text.push_str(truncated);
                }
                text
            })
            .collect();

        let embeddings = self
            .model
            .embed(texts, None)
            .map_err(|e| EmbeddingError::EmbeddingFailed(e.to_string()))?;

        Ok(publications
            .into_iter()
            .zip(embeddings.into_iter())
            .map(|((id, _, _, _), vector)| PublicationEmbedding {
                publication_id: id,
                vector,
                model: self.model_name.clone(),
            })
            .collect())
    }

    /// Embed a search query
    pub fn embed_query(&self, query: &str) -> Result<Vec<f32>, EmbeddingError> {
        let embeddings = self
            .model
            .embed(vec![query.to_string()], None)
            .map_err(|e| EmbeddingError::EmbeddingFailed(e.to_string()))?;

        embeddings
            .into_iter()
            .next()
            .ok_or_else(|| EmbeddingError::EmbeddingFailed("No embedding returned".to_string()))
    }
}

/// Compute cosine similarity between two vectors
#[uniffi::export]
pub fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return 0.0;
    }

    let dot_product: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let norm_a: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let norm_b: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();

    if norm_a == 0.0 || norm_b == 0.0 {
        return 0.0;
    }

    dot_product / (norm_a * norm_b)
}

/// Find most similar publications by embedding
#[uniffi::export]
pub fn find_similar(
    query_embedding: &[f32],
    candidate_embeddings: Vec<PublicationEmbedding>,
    top_k: u32,
) -> Vec<SimilarityResult> {
    let top_k = top_k as usize;
    let mut results: Vec<SimilarityResult> = candidate_embeddings
        .into_iter()
        .map(|emb| {
            let similarity = cosine_similarity(query_embedding, &emb.vector);
            SimilarityResult {
                publication_id: emb.publication_id,
                similarity,
            }
        })
        .collect();

    // Sort by similarity descending
    results.sort_by(|a, b| {
        b.similarity
            .partial_cmp(&a.similarity)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    results.truncate(top_k);
    results
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct SimilarityResult {
    pub publication_id: String,
    pub similarity: f32,
}

/// Embedding storage format for persistence
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct StoredEmbedding {
    pub publication_id: String,
    pub vector: Vec<f32>,
    pub model: String,
    pub created_at: String,
}

impl From<PublicationEmbedding> for StoredEmbedding {
    fn from(emb: PublicationEmbedding) -> Self {
        Self {
            publication_id: emb.publication_id,
            vector: emb.vector,
            model: emb.model,
            created_at: chrono::Utc::now().to_rfc3339(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cosine_similarity() {
        let a = vec![1.0, 0.0, 0.0];
        let b = vec![1.0, 0.0, 0.0];
        assert!((cosine_similarity(&a, &b) - 1.0).abs() < 0.001);

        let c = vec![0.0, 1.0, 0.0];
        assert!(cosine_similarity(&a, &c).abs() < 0.001);
    }

    #[test]
    fn test_find_similar() {
        let query = vec![1.0, 0.0, 0.0];
        let candidates = vec![
            PublicationEmbedding {
                publication_id: "a".to_string(),
                vector: vec![0.9, 0.1, 0.0],
                model: "test".to_string(),
            },
            PublicationEmbedding {
                publication_id: "b".to_string(),
                vector: vec![0.0, 1.0, 0.0],
                model: "test".to_string(),
            },
        ];

        let results = find_similar(&query, candidates, 2u32);
        assert_eq!(results[0].publication_id, "a");
        assert!(results[0].similarity > results[1].similarity);
    }
}
