//! Tantivy schema definition for publication search

use tantivy::schema::{
    IndexRecordOption, Schema, SchemaBuilder, TextFieldIndexing, TextOptions, FAST, INDEXED,
    STORED, STRING, TEXT,
};

/// Field names for the search index
pub mod fields {
    pub const ID: &str = "id";
    pub const CITE_KEY: &str = "cite_key";
    pub const TITLE: &str = "title";
    pub const AUTHORS: &str = "authors";
    pub const ABSTRACT: &str = "abstract";
    pub const FULL_TEXT: &str = "full_text";
    pub const YEAR: &str = "year";
    pub const JOURNAL: &str = "journal";
    pub const TAGS: &str = "tags";
    pub const NOTES: &str = "notes";
    pub const DOI: &str = "doi";
    pub const ARXIV_ID: &str = "arxiv_id";
    pub const LIBRARY_ID: &str = "library_id";
}

/// Build the Tantivy schema for publications
pub fn build_schema() -> Schema {
    let mut schema_builder = SchemaBuilder::new();

    // Stored fields (returned in results)
    schema_builder.add_text_field(fields::ID, STRING | STORED);
    schema_builder.add_text_field(fields::CITE_KEY, STRING | STORED);

    // Full-text searchable with positions (for phrase queries and highlighting)
    let text_options = TextOptions::default()
        .set_indexing_options(
            TextFieldIndexing::default()
                .set_tokenizer("en_stem")
                .set_index_option(IndexRecordOption::WithFreqsAndPositions),
        )
        .set_stored();

    schema_builder.add_text_field(fields::TITLE, text_options.clone());
    schema_builder.add_text_field(fields::AUTHORS, text_options.clone());
    schema_builder.add_text_field(fields::ABSTRACT, text_options.clone());

    // Full text - indexed but not stored (too large)
    let fulltext_options = TextOptions::default().set_indexing_options(
        TextFieldIndexing::default()
            .set_tokenizer("en_stem")
            .set_index_option(IndexRecordOption::WithFreqsAndPositions),
    );
    schema_builder.add_text_field(fields::FULL_TEXT, fulltext_options);

    // Faceted/filterable fields
    schema_builder.add_u64_field(fields::YEAR, INDEXED | STORED | FAST);
    schema_builder.add_text_field(fields::JOURNAL, TEXT | STORED);
    schema_builder.add_text_field(fields::TAGS, TEXT | STORED);
    schema_builder.add_text_field(fields::NOTES, text_options);

    // Identifier fields (exact match)
    schema_builder.add_text_field(fields::DOI, STRING | STORED);
    schema_builder.add_text_field(fields::ARXIV_ID, STRING | STORED);
    schema_builder.add_text_field(fields::LIBRARY_ID, STRING | STORED);

    schema_builder.build()
}

/// Tantivy tokenizer configuration
pub fn configure_tokenizers(index: &tantivy::Index) {
    let tokenizer_manager = index.tokenizers();

    // English stemming tokenizer
    tokenizer_manager.register(
        "en_stem",
        tantivy::tokenizer::TextAnalyzer::builder(tantivy::tokenizer::SimpleTokenizer::default())
            .filter(tantivy::tokenizer::RemoveLongFilter::limit(40))
            .filter(tantivy::tokenizer::LowerCaser)
            .filter(tantivy::tokenizer::Stemmer::new(
                tantivy::tokenizer::Language::English,
            ))
            .build(),
    );
}
