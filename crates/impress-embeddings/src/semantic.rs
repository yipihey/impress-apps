//! Semantic search using text embeddings
//!
//! Enables "find similar papers" functionality by computing
//! vector embeddings and using cosine similarity.

use fastembed::{EmbeddingModel, InitOptions, TextEmbedding};
use serde::{Deserialize, Serialize};
use thiserror::Error;

pub use crate::PublicationEmbedding;

#[derive(Error, Debug)]
pub enum EmbeddingError {
    #[error("Model initialization failed: {0}")]
    InitError(String),
    #[error("Embedding generation failed: {0}")]
    EmbeddingFailed(String),
    #[error("Invalid input: {0}")]
    InvalidInput(String),
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
            // Use char boundary-safe truncation to avoid panics on non-ASCII text
            let truncated: String = abstract_str.chars().take(1000).collect();
            text.push_str(&truncated);
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
                    // Use char boundary-safe truncation to avoid panics on non-ASCII text
                    let truncated: String = abs.chars().take(1000).collect();
                    text.push_str(&truncated);
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
            .zip(embeddings)
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

/// Embedding storage format for persistence
#[derive(Clone, Debug, Serialize, Deserialize)]
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
