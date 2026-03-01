use clap::{Parser, Subcommand};
use std::io::{self, Read};

#[derive(Parser)]
#[command(
    name = "im-bibtex",
    about = "Fast BibTeX parser, formatter, and toolkit",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Parse a BibTeX file and output structured JSON
    Parse {
        /// BibTeX file to parse (use - for stdin)
        file: String,
    },
    /// Format/normalize a BibTeX file
    Format {
        /// BibTeX file to format (use - for stdin)
        file: String,
    },
    /// Decode LaTeX to Unicode
    Latex {
        /// Text with LaTeX commands to decode
        text: String,
    },
    /// Expand a journal macro abbreviation
    Journal {
        /// Journal macro (e.g., apj, mnras, \\apj)
        name: String,
    },
    /// List all known journal macros
    Journals,
    /// Validate a BibTeX file and report issues
    Validate {
        /// BibTeX file to validate (use - for stdin)
        file: String,
    },
}

fn read_input(file: &str) -> Result<String, Box<dyn std::error::Error>> {
    if file == "-" {
        let mut buf = String::new();
        io::stdin().read_to_string(&mut buf)?;
        Ok(buf)
    } else {
        Ok(std::fs::read_to_string(file)?)
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Parse { file } => {
            let input = read_input(&file)?;
            let result = im_bibtex::parse(input)?;
            println!("{}", serde_json::to_string_pretty(&result)?);
        }
        Commands::Format { file } => {
            let input = read_input(&file)?;
            let result = im_bibtex::parse(input)?;
            let strings: Vec<(String, String)> = result.strings.into_iter().collect();
            let formatted =
                im_bibtex::format_complete(&strings, &result.preambles, &result.entries);
            println!("{formatted}");
        }
        Commands::Latex { text } => {
            let decoded = im_bibtex::decode_latex(text);
            println!("{decoded}");
        }
        Commands::Journal { name } => {
            let expanded = im_bibtex::expand_journal_macro(name.clone());
            if expanded == name {
                eprintln!("Unknown journal macro: {name}");
                std::process::exit(1);
            }
            println!("{expanded}");
        }
        Commands::Journals => {
            let mut names = im_bibtex::get_all_journal_macro_names();
            names.sort();
            for name in &names {
                let expanded = im_bibtex::expand_journal_macro(name.clone());
                println!("{name:20} → {expanded}");
            }
            eprintln!("\n{} journal macros", names.len());
        }
        Commands::Validate { file } => {
            let input = read_input(&file)?;
            let result = im_bibtex::parse(input)?;

            if result.errors.is_empty() {
                println!(
                    "OK: {} entries parsed, {} string definitions",
                    result.entries.len(),
                    result.strings.len()
                );
            } else {
                for err in &result.errors {
                    eprintln!("Line {}: {}", err.line, err.message);
                }
                eprintln!(
                    "\n{} errors, {} entries parsed",
                    result.errors.len(),
                    result.entries.len()
                );
                std::process::exit(1);
            }

            // Check for entries missing key fields
            let mut warnings = 0;
            for entry in &result.entries {
                if entry.title().is_none() {
                    eprintln!("Warning: {} missing title", entry.cite_key);
                    warnings += 1;
                }
                if entry.author().is_none() {
                    eprintln!("Warning: {} missing author", entry.cite_key);
                    warnings += 1;
                }
            }
            if warnings > 0 {
                eprintln!("{warnings} warnings");
            }
        }
    }

    Ok(())
}
