//! Explicit model-backed proof. All databases and the downloaded model cache
//! belong to this test's retained temporary directory, never an app workspace.
use impress_embeddings::{EmbeddingStore, SemanticSearch, StoredChunk, StoredVector};
use impress_service_core::{
    pipeline::{self, Call, CallerIdentity},
    report::tier_a::{run_linked_tier_b_example_with_args, Outcome},
    ExampleTier, VerbDescriptor,
};

#[tokio::test]
#[ignore = "explicit isolated embedding-model proof; may download the public model into its own cache"]
async fn semantic_examples_read_owned_index() {
    let root = tempfile::tempdir().unwrap().keep();
    eprintln!("Owned semantic proof: {}", root.display());
    std::env::set_var("IMPRESS_STORE_PATH", root.join("impress.sqlite"));
    std::env::set_var("IMPRESS_EMBEDDINGS_PATH", root.join("embeddings.sqlite"));
    std::env::set_var("IMPRESS_FASTEMBED_CACHE", root.join("models"));
    let store = imbib_core::unified::store_api::ImbibStore::open(
        root.join("impress.sqlite").to_string_lossy().into_owned(),
    )
    .unwrap();
    let library = store.create_library("G3 semantic fixture".into()).unwrap();
    let ids = store.import_bibtex("@article{G3Semantic2026, title={G3 spectral line fixture}, author={Fixture, Example}, year={2026}}".into(), library.id).unwrap();
    let paper = ids.first().expect("one imported paper").clone();
    let text = "Spectral line formation in an owned synthetic atmosphere.";
    let model = SemanticSearch::new().expect("owned model cache");
    let index = EmbeddingStore::open(root.join("embeddings.sqlite").to_str().unwrap()).unwrap();
    index
        .save_chunks(&[StoredChunk {
            id: "g3-owned-chunk".into(),
            publication_id: paper.clone(),
            text: text.into(),
            page_number: Some(0),
            char_offset: 0,
            char_length: text.len() as u32,
            chunk_index: 0,
        }])
        .unwrap();
    index
        .save_vectors(&[StoredVector {
            id: "g3-owned-vector".into(),
            source_id: "g3-owned-chunk".into(),
            source_type: "chunk".into(),
            vector: model.embed_text(text).unwrap(),
            model: model.model_id().into(),
            created_at: "2026-09-28T00:00:00Z".into(),
        }])
        .unwrap();
    // Referencing the implementation links the trait inventory in this test binary.
    let _service = imbib_semantic_service::DefaultImbibSemanticService::new();
    let mut ran = 0;
    for name in ["search-papers", "get-paper-chunks", "list-indexed-papers"] {
        let verb = VerbDescriptor::find(&format!("imbib-semantic-service_{name}"))
            .expect("semantic verb linked");
        for example in verb.examples.iter().filter(|ex| ex.tier == ExampleTier::B) {
            let mut args = example.args_value();
            if name == "get-paper-chunks" {
                args["publication_id"] = paper.clone().into();
            }
            let outcome = run_linked_tier_b_example_with_args(
                verb,
                example,
                args,
                CallerIdentity::system("owned-semantic-example"),
                |args, caller| pipeline::invoke(verb, Call::new(caller, args)),
                |schema, value| {
                    jsonschema::validator_for(schema)
                        .map_err(|e| e.to_string())?
                        .validate(value)
                        .map_err(|e| e.to_string())
                },
            )
            .await;
            let Outcome::Passed { result } = outcome else {
                panic!("{name}: {outcome:?}");
            };
            let field = if name == "search-papers" {
                "results"
            } else if name == "get-paper-chunks" {
                "chunks"
            } else {
                "papers"
            };
            assert_eq!(result[field].as_array().expect("result array").len(), 1);
            ran += 1;
        }
    }
    assert_eq!(ran, 3);
}
