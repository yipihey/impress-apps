use clap::{Parser, Subcommand};
use std::io::{self, Read};

#[derive(Parser)]
#[command(
    name = "im-identifiers",
    about = "Extract, validate, and resolve academic identifiers (DOI, arXiv, ISBN)",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Extract all identifiers from text
    Extract {
        /// Text to extract from (use - for stdin)
        text: String,
    },
    /// Validate an identifier
    Validate {
        /// Identifier type: doi, arxiv, isbn
        #[arg(value_name = "TYPE")]
        id_type: String,
        /// The identifier value
        value: String,
    },
    /// Normalize a DOI (strip URL prefixes, trailing punctuation)
    Normalize {
        /// DOI to normalize
        doi: String,
    },
    /// Generate a citation key from metadata
    Citekey {
        /// Author name(s)
        #[arg(short, long)]
        author: Option<String>,
        /// Publication year
        #[arg(short, long)]
        year: Option<String>,
        /// Paper title
        #[arg(short, long)]
        title: Option<String>,
    },
    /// Get the URL for an identifier
    Url {
        /// Identifier type: doi, arxiv, pmid, pmcid, bibcode
        #[arg(value_name = "TYPE")]
        id_type: String,
        /// The identifier value
        value: String,
    },
    /// Launch MCP server (JSON-RPC 2.0 over stdin/stdout)
    Serve,
    /// Configure MCP server for AI editors (Claude Code, Claude Desktop, Cursor, Zed)
    Setup {
        /// Configure only this editor (default: all detected)
        #[arg(value_enum)]
        editor: Option<im_identifiers::setup::EditorTarget>,
    },
}

fn read_input(text: &str) -> Result<String, Box<dyn std::error::Error>> {
    if text == "-" {
        let mut buf = String::new();
        io::stdin().read_to_string(&mut buf)?;
        Ok(buf)
    } else {
        Ok(text.to_string())
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Extract { text } => {
            let input = read_input(&text)?;
            let ids = im_identifiers::extract_all(input);
            println!("{}", serde_json::to_string_pretty(&ids)?);
        }
        Commands::Validate { id_type, value } => {
            let valid = match id_type.to_lowercase().as_str() {
                "doi" => im_identifiers::is_valid_doi(value.clone()),
                "arxiv" => im_identifiers::is_valid_arxiv_id(value.clone()),
                "isbn" => im_identifiers::is_valid_isbn(value.clone()),
                other => {
                    eprintln!("Unknown identifier type: {other}");
                    eprintln!("Supported: doi, arxiv, isbn");
                    std::process::exit(1);
                }
            };
            if valid {
                println!("Valid {id_type}: {value}");
            } else {
                eprintln!("Invalid {id_type}: {value}");
                std::process::exit(1);
            }
        }
        Commands::Normalize { doi } => {
            let normalized = im_identifiers::normalize_doi(doi);
            println!("{normalized}");
        }
        Commands::Citekey {
            author,
            year,
            title,
        } => {
            let key = im_identifiers::generate_cite_key(author, year, title);
            println!("{key}");
        }
        Commands::Serve => {
            im_identifiers::mcp::run_server()?;
        }
        Commands::Setup { editor } => {
            im_identifiers::setup::run_setup(editor)?;
        }
        Commands::Url { id_type, value } => {
            let id = match id_type.to_lowercase().as_str() {
                "doi" => im_identifiers::IdentifierType::Doi,
                "arxiv" => im_identifiers::IdentifierType::Arxiv,
                "pmid" => im_identifiers::IdentifierType::Pmid,
                "pmcid" => im_identifiers::IdentifierType::Pmcid,
                "bibcode" => im_identifiers::IdentifierType::Bibcode,
                "s2" | "semanticscholar" => im_identifiers::IdentifierType::SemanticScholar,
                "openalex" => im_identifiers::IdentifierType::OpenAlex,
                "dblp" => im_identifiers::IdentifierType::Dblp,
                other => {
                    eprintln!("Unknown identifier type: {other}");
                    eprintln!("Supported: doi, arxiv, pmid, pmcid, bibcode, s2, openalex, dblp");
                    std::process::exit(1);
                }
            };
            match im_identifiers::identifier_url(id, value) {
                Some(url) => println!("{url}"),
                None => {
                    eprintln!("Cannot construct URL for this identifier type");
                    std::process::exit(1);
                }
            }
        }
    }

    Ok(())
}
