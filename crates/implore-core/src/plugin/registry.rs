//! Registry for data generators.
//!
//! The registry provides compile-time registration of generators
//! with runtime lookup by ID or category.

use std::collections::HashMap;

use super::{generators, DataGenerator, GeneratorCategory, GeneratorMetadata};

/// Registry of all available data generators.
///
/// The registry is created at startup with all built-in generators registered.
/// Additional generators can be registered at runtime.
pub struct GeneratorRegistry {
    generators: Vec<Box<dyn DataGenerator>>,
    by_id: HashMap<String, usize>,
    by_category: HashMap<GeneratorCategory, Vec<usize>>,
}

impl GeneratorRegistry {
    /// Create a new registry with all built-in generators registered.
    pub fn new() -> Self {
        let mut registry = Self {
            generators: Vec::new(),
            by_id: HashMap::new(),
            by_category: HashMap::new(),
        };

        // Register all built-in generators
        registry.register_builtins();

        registry
    }

    /// Create an empty registry (for testing)
    pub fn empty() -> Self {
        Self {
            generators: Vec::new(),
            by_id: HashMap::new(),
            by_category: HashMap::new(),
        }
    }

    /// Register all built-in generators
    fn register_builtins(&mut self) {
        // Noise generators
        self.register(Box::new(generators::PerlinNoise2D::new()));
        self.register(Box::new(generators::SimplexNoise2D::new()));
        self.register(Box::new(generators::WorleyNoise2D::new()));
        self.register(Box::new(generators::PowerSpectrumNoise::new()));

        // Fractal generators
        self.register(Box::new(generators::MandelbrotSet::new()));
        self.register(Box::new(generators::JuliaSet::new()));

        // Statistical generators
        self.register(Box::new(generators::GaussianClusters::new()));
        self.register(Box::new(generators::UniformRandom::new()));

        // Function generators
        self.register(Box::new(generators::FunctionPlotter2D::new()));
        self.register(Box::new(generators::SineCosine::new()));
        self.register(Box::new(generators::DualFunction::new()));
    }

    /// Register a generator with the registry.
    pub fn register(&mut self, generator: Box<dyn DataGenerator>) {
        let index = self.generators.len();
        let metadata = generator.metadata();

        // Index by ID
        self.by_id.insert(metadata.id.clone(), index);

        // Index by category
        self.by_category
            .entry(metadata.category)
            .or_default()
            .push(index);

        self.generators.push(generator);
    }

    /// Get a generator by its ID.
    pub fn get(&self, id: &str) -> Option<&dyn DataGenerator> {
        self.by_id
            .get(id)
            .map(|&index| self.generators[index].as_ref())
    }

    /// List all available generators.
    pub fn list_all(&self) -> Vec<&GeneratorMetadata> {
        self.generators.iter().map(|g| g.metadata()).collect()
    }

    /// List generators in a specific category.
    pub fn list_by_category(&self, category: GeneratorCategory) -> Vec<&GeneratorMetadata> {
        self.by_category
            .get(&category)
            .map(|indices| {
                indices
                    .iter()
                    .map(|&i| self.generators[i].metadata())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Get all categories that have at least one generator.
    pub fn categories(&self) -> Vec<GeneratorCategory> {
        self.by_category.keys().copied().collect()
    }

    /// Get the total number of registered generators.
    pub fn len(&self) -> usize {
        self.generators.len()
    }

    /// Check if the registry is empty.
    pub fn is_empty(&self) -> bool {
        self.generators.is_empty()
    }

    /// Search generators by name (case-insensitive).
    pub fn search(&self, query: &str) -> Vec<&GeneratorMetadata> {
        let query_lower = query.to_lowercase();
        self.generators
            .iter()
            .map(|g| g.metadata())
            .filter(|m| {
                m.name.to_lowercase().contains(&query_lower)
                    || m.description.to_lowercase().contains(&query_lower)
                    || m.id.to_lowercase().contains(&query_lower)
            })
            .collect()
    }
}

impl Default for GeneratorRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_registry_creation() {
        let registry = GeneratorRegistry::new();

        // Should have built-in generators
        assert!(!registry.is_empty());
        assert!(!registry.is_empty());
    }

    #[test]
    fn test_get_by_id() {
        let registry = GeneratorRegistry::new();

        let perlin = registry.get("noise-perlin-2d");
        assert!(perlin.is_some());

        let metadata = perlin.unwrap().metadata();
        assert_eq!(metadata.id, "noise-perlin-2d");
        assert_eq!(metadata.category, GeneratorCategory::Noise);
    }

    #[test]
    fn test_list_by_category() {
        let registry = GeneratorRegistry::new();

        let noise_generators = registry.list_by_category(GeneratorCategory::Noise);
        assert!(!noise_generators.is_empty());

        for meta in noise_generators {
            assert_eq!(meta.category, GeneratorCategory::Noise);
        }
    }

    #[test]
    fn test_search() {
        let registry = GeneratorRegistry::new();

        let results = registry.search("perlin");
        assert!(!results.is_empty());

        let results = registry.search("NOISE");
        assert!(!results.is_empty());
    }

    #[test]
    fn test_categories() {
        let registry = GeneratorRegistry::new();
        let categories = registry.categories();

        assert!(categories.contains(&GeneratorCategory::Noise));
        assert!(categories.contains(&GeneratorCategory::Fractal));
    }
}
