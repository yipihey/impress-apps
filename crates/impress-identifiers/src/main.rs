//! CLI binary for impress-identifiers.
//!
//! Usage:
//!   impress-identifiers <doi-or-arxiv-id> [...]  # Classify identifier(s), output JSON
//!   impress-identifiers --extract < text.txt     # Extract all identifiers from stdin
//!   impress-identifiers --version

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("impress-identifiers {}", env!("CARGO_PKG_VERSION"));
        return;
    }

    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("impress-identifiers - scholarly identifier detection and validation");
        println!();
        println!("USAGE:");
        println!("  impress-identifiers <id> [...]    Classify identifier(s)");
        println!("  impress-identifiers --extract     Extract identifiers from stdin");
        println!("  impress-identifiers --version     Print version");
        println!("  impress-identifiers --help        Print this help");
        println!();
        println!("IDENTIFIER TYPES:");
        println!("  doi       10.XXXX/suffix");
        println!("  arxiv     YYMM.NNNNN or archive/NNNNNNN");
        println!("  isbn      ISBN-10 or ISBN-13 (with checksum validation)");
        return;
    }

    // --extract mode: read stdin and extract all identifiers
    if args.iter().any(|a| a == "--extract") {
        use std::io::Read;
        let mut input = String::new();
        if std::io::stdin().read_to_string(&mut input).is_err() {
            eprintln!("error: failed to read stdin");
            std::process::exit(1);
        }
        let extracted = impress_identifiers::extract_all(input);
        let json = serde_json::to_string_pretty(&extracted).unwrap_or_else(|_| "[]".to_string());
        println!("{}", json);
        return;
    }

    // Identifier classification mode: positional arguments
    let identifiers: Vec<&str> = args[1..]
        .iter()
        .filter(|a| !a.starts_with('-'))
        .map(|s| s.as_str())
        .collect();

    if identifiers.is_empty() {
        eprintln!("usage: impress-identifiers <doi|arxiv-id|isbn> [...]");
        eprintln!("       impress-identifiers --extract < text.txt");
        eprintln!("       impress-identifiers --version");
        std::process::exit(1);
    }

    let results: Vec<serde_json::Value> = identifiers
        .iter()
        .map(|id| classify_identifier(id))
        .collect();

    let output = if results.len() == 1 {
        results.into_iter().next().unwrap()
    } else {
        serde_json::Value::Array(results)
    };

    println!(
        "{}",
        serde_json::to_string_pretty(&output).unwrap_or_else(|_| "null".to_string())
    );
}

/// Classify a single identifier string using the library's validators and extractors.
fn classify_identifier(id: &str) -> serde_json::Value {
    // Normalize the raw input for DOI detection
    let normalized = impress_identifiers::normalize_doi(id.to_string());

    // Check each identifier type in priority order
    if impress_identifiers::is_valid_doi(normalized.clone()) {
        let url = impress_identifiers::identifier_url(
            impress_identifiers::IdentifierType::Doi,
            normalized.clone(),
        );
        return serde_json::json!({
            "input": id,
            "type": "doi",
            "value": normalized,
            "valid": true,
            "url": url,
            "display_name": impress_identifiers::identifier_display_name(impress_identifiers::IdentifierType::Doi),
        });
    }

    if impress_identifiers::is_valid_arxiv_id(id.to_string()) {
        let url = impress_identifiers::identifier_url(
            impress_identifiers::IdentifierType::Arxiv,
            id.to_string(),
        );
        return serde_json::json!({
            "input": id,
            "type": "arxiv",
            "value": id,
            "valid": true,
            "url": url,
            "display_name": impress_identifiers::identifier_display_name(impress_identifiers::IdentifierType::Arxiv),
        });
    }

    if impress_identifiers::is_valid_isbn(id.to_string()) {
        return serde_json::json!({
            "input": id,
            "type": "isbn",
            "value": id,
            "valid": true,
            "url": null,
            "display_name": "ISBN",
        });
    }

    // Try extracting identifiers from the input text (handles URLs and prefixes)
    let extracted = impress_identifiers::extract_all(id.to_string());
    if let Some(first) = extracted.into_iter().next() {
        return serde_json::json!({
            "input": id,
            "type": first.identifier_type,
            "value": first.value,
            "valid": true,
            "url": null,
        });
    }

    // Unknown
    serde_json::json!({
        "input": id,
        "type": "unknown",
        "value": id,
        "valid": false,
    })
}
