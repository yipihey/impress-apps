//! CLI binary for impress-bibtex.
//!
//! Usage:
//!   impress-bibtex [--validate] < input.bib     # Parse stdin BibTeX, output JSON
//!   impress-bibtex --version                    # Print version

use std::io::{self, Read};

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("impress-bibtex {}", env!("CARGO_PKG_VERSION"));
        return;
    }

    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("impress-bibtex - BibTeX parser and formatter");
        println!();
        println!("USAGE:");
        println!("  impress-bibtex [OPTIONS] < input.bib");
        println!();
        println!("OPTIONS:");
        println!("  --validate    Parse and report entry count; no JSON output");
        println!("  --version     Print version");
        println!("  --help        Print this help");
        println!();
        println!("OUTPUT:");
        println!("  JSON array of parsed entries (cite_key, entry_type, fields, errors)");
        return;
    }

    let validate_only = args.iter().any(|a| a == "--validate");

    let mut input = String::new();
    if io::stdin().read_to_string(&mut input).is_err() {
        eprintln!("error: failed to read stdin");
        std::process::exit(1);
    }

    // Use the library's parser — parse() is the public entry point
    match impress_bibtex::parse(input) {
        Ok(result) => {
            if validate_only {
                if result.errors.is_empty() {
                    eprintln!("ok: {} entries parsed", result.entries.len());
                } else {
                    eprintln!(
                        "ok: {} entries parsed, {} errors",
                        result.entries.len(),
                        result.errors.len()
                    );
                    std::process::exit(1);
                }
            } else {
                // Build a serializable representation from the library types.
                // BibTeXEntry and BibTeXParseResult don't derive Serialize (only via
                // the uniffi feature), so we construct a plain JSON object manually.
                let entries_json: Vec<serde_json::Value> = result
                    .entries
                    .iter()
                    .map(|e| {
                        let fields_obj: serde_json::Map<String, serde_json::Value> = e
                            .fields
                            .iter()
                            .map(|f| (f.key.clone(), serde_json::Value::String(f.value.clone())))
                            .collect();
                        serde_json::json!({
                            "cite_key": e.cite_key,
                            "entry_type": e.entry_type.as_str(),
                            "fields": fields_obj,
                        })
                    })
                    .collect();

                let output = serde_json::json!({
                    "entries": entries_json,
                    "entry_count": result.entries.len(),
                    "error_count": result.errors.len(),
                    "errors": result.errors.iter().map(|err| serde_json::json!({
                        "line": err.line,
                        "column": err.column,
                        "message": err.message,
                    })).collect::<Vec<_>>(),
                });

                match serde_json::to_string_pretty(&output) {
                    Ok(json) => println!("{}", json),
                    Err(e) => {
                        eprintln!("error: serialization failed: {}", e);
                        std::process::exit(1);
                    }
                }
            }
        }
        Err(e) => {
            eprintln!("error: {}", e);
            std::process::exit(1);
        }
    }
}
