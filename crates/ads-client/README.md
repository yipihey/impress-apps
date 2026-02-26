# ads-client

A Rust client for the [NASA ADS](https://ui.adsabs.harvard.edu/) (Astrophysics Data System) / [SciX](https://scixplorer.org/) API.

Three ways to use it:

| Mode | What it does |
|------|-------------|
| **Library** (`ads_client`) | Async Rust crate — add to your `Cargo.toml` |
| **CLI** (`ads`) | Command-line tool for your terminal |
| **MCP server** (`ads serve`) | Expose ADS tools to Claude, Cursor, Zed, etc. |

One binary (`ads`) does everything. The MCP server is `ads serve`.

## Prerequisites

You need an ADS API token. Get one (free) at:
<https://ui.adsabs.harvard.edu/user/settings/token>

Then export it:

```bash
export ADS_API_TOKEN="your-token-here"
```

---

## Installation

### From source (this repo)

```bash
# Build the ads binary (includes CLI + MCP server)
cargo build -p ads-client --features cli --release
cp target/release/ads ~/.local/bin/   # or anywhere on your PATH

# Library only (for use as a Rust dependency, no binary)
cargo build -p ads-client
```

### As a Rust dependency

```toml
[dependencies]
ads-client = { git = "https://github.com/yipihey/impress-apps", version = "0.1" }
```

---

## MCP Server Setup

`ads serve` speaks [MCP](https://modelcontextprotocol.io/) (Model Context Protocol) over stdio, giving AI assistants direct access to the ADS API. It's the same `ads` binary — no separate install needed.

### Claude Code (CLI)

```bash
claude mcp add ads -- /path/to/ads serve
```

Or add manually to `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "ads": {
      "command": "/path/to/ads",
      "args": ["serve"],
      "env": {
        "ADS_API_TOKEN": "your-token-here"
      }
    }
  }
}
```

### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS)
or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "ads": {
      "command": "/path/to/ads",
      "args": ["serve"],
      "env": {
        "ADS_API_TOKEN": "your-token-here"
      }
    }
  }
}
```

### Cursor

In Cursor Settings > MCP, add:

```json
{
  "mcpServers": {
    "ads": {
      "command": "/path/to/ads",
      "args": ["serve"],
      "env": {
        "ADS_API_TOKEN": "your-token-here"
      }
    }
  }
}
```

### Zed

In Zed settings (`settings.json`):

```json
{
  "context_servers": {
    "ads": {
      "command": {
        "path": "/path/to/ads",
        "args": ["serve"],
        "env": {
          "ADS_API_TOKEN": "your-token-here"
        }
      }
    }
  }
}
```

### Verify it works

```bash
# Should print the tool list as JSON
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ADS_API_TOKEN=your-token ads serve
```

### Available MCP Tools

| Tool | Description |
|------|-------------|
| `ads_search` | Full-text search with ADS query syntax |
| `ads_bigquery` | Search within a set of known bibcodes |
| `ads_export` | Export in 17 citation formats (BibTeX, RIS, AASTeX, ...) |
| `ads_metrics` | h-index, g-index, citation counts, indicators |
| `ads_library` | Create/list/edit/delete personal ADS libraries |
| `ads_library_documents` | Add/remove papers from libraries |
| `ads_citation_helper` | Find co-cited papers you might be missing |
| `ads_network` | Author collaboration & paper citation networks |
| `ads_object_search` | Resolve object names (M31, NGC 1234) via SIMBAD/NED |
| `ads_resolve_reference` | Convert free-text citations to bibcodes |
| `ads_resolve_links` | Resolve full-text, data, and reference links |

### MCP Resources

| URI | Content |
|-----|---------|
| `ads://fields` | Searchable and returnable ADS field names |
| `ads://syntax` | ADS query syntax quick reference |

---

## CLI Examples

All examples assume `ADS_API_TOKEN` is set in your environment.

### Searching

```bash
# Basic search
ads search "dark matter"

# Search by author
ads search 'author:"Einstein"'

# Author + year range
ads search 'author:"Weinberg" year:[1965 TO 1975]'

# First-author search, most cited first
ads search 'first_author:"Perlmutter" supernova' --sort "citation_count desc"

# Title search
ads search 'title:"cosmological constant problem"'

# Abstract search
ads search 'abs:"gravitational waves" year:2016'

# Combine fields with boolean operators
ads search 'author:"Hawking" AND title:"black hole" AND year:[1970 TO 1980]'

# Refereed papers only
ads search 'author:"Witten" property:refereed' --rows 20

# Papers about an astronomical object
ads search 'object:"Crab Nebula" year:[2020 TO 2025]'

# Search by journal (bibstem)
ads search 'bibstem:ApJ year:2024 title:"exoplanet atmosphere"'

# Search by DOI
ads search 'doi:"10.1103/PhysRevLett.116.061102"'

# Search by arXiv ID
ads search 'identifier:arXiv:1602.03837'

# Search by ORCID
ads search 'orcid:0000-0002-1825-0097'

# Open access papers only
ads search 'title:"machine learning" AND property:openaccess year:2024'

# Get more results
ads search "galaxy clusters weak lensing" --rows 50

# Output as JSON (for scripting)
ads search 'author:"Planck Collaboration" year:2018' --output json

# Custom fields
ads search 'author:"Einstein" year:1905' --fields "bibcode,title,citation_count"
```

### Exporting citations

```bash
# BibTeX (default)
ads export 2023ApJ...123..456A

# Multiple papers
ads export 2023ApJ...123..456A 2024MNRAS.789..012B 1998AJ....116.1009R

# Different formats
ads export 2023ApJ...123..456A --format bibtex
ads export 2023ApJ...123..456A --format aastex
ads export 2023ApJ...123..456A --format mnras
ads export 2023ApJ...123..456A --format ris
ads export 2023ApJ...123..456A --format ieee
ads export 2023ApJ...123..456A --format endnote

# Save to file
ads export 2023ApJ...123..456A 2024MNRAS.789..012B --format bibtex > refs.bib

# Pipe a search into an export (with jq)
ads search 'author:"Einstein" year:1905' --output json \
  | jq -r '.papers[].bibcode' \
  | xargs ads export --format bibtex
```

### References and citations

```bash
# Papers referenced by a paper
ads refs 2023ApJ...123..456A

# Papers that cite a paper
ads cites 2023ApJ...123..456A

# Show more results
ads refs 1998AJ....116.1009R --rows 100

# Similar papers (content-based)
ads similar 2023ApJ...123..456A

# JSON output for further processing
ads cites 2023ApJ...123..456A --output json | jq '.papers | length'
```

### Citation metrics

```bash
# Metrics for one paper
ads metrics 2023ApJ...123..456A

# Metrics for a set of papers (h-index, g-index, etc.)
ads metrics 2023ApJ...123..456A 2024MNRAS.789..012B 1998AJ....116.1009R
```

Sample output:
```json
{
  "basic_stats": {
    "total": { "number_of_papers": 3, "total_citations": 5821 }
  },
  "indicators": {
    "h": 3, "g": 3, "i10": 3, "tori": 142.7
  }
}
```

### Resolving references

```bash
# Free-text reference to bibcode
ads resolve "Einstein 1905 Annalen der Physik 17 891"

# Multiple references
ads resolve \
  "Perlmutter et al. 1999 ApJ 517 565" \
  "Riess et al. 1998 AJ 116 1009"

# JSON output
ads resolve "Weinberg 1989 Rev Mod Phys 61 1" --output json
```

### Astronomical objects

```bash
# Find papers about an object
ads objects "M31"

# Multiple objects
ads objects "M31" "NGC 1234" "Crab Nebula"
```

### Link resolution

```bash
# All links for a paper (full-text, data, etc.)
ads links 2023ApJ...123..456A

# Specific link type
ads links 2023ApJ...123..456A --link-type esource
ads links 2023ApJ...123..456A --link-type data
```

### Library management

```bash
# List your libraries
ads libraries list

# Get library details (includes bibcodes)
ads libraries get abc123def

# Create a library
ads libraries create "My Reading List" --description "Papers to read this week"

# Create a public library
ads libraries create "Dark Energy Review" --description "Key papers" --public

# Delete a library
ads libraries delete abc123def

# JSON output
ads libraries list --output json
```

### MCP server

```bash
# Start MCP server (reads JSON-RPC from stdin, writes to stdout)
ads serve
```

This is the same entry point used by Claude, Cursor, Zed, etc. (see MCP Server Setup above).

---

## Library Usage (Rust)

### Basic search

```rust
use ads_client::AdsClient;

#[tokio::main]
async fn main() -> ads_client::error::Result<()> {
    let client = AdsClient::from_env()?;

    let results = client.search("author:\"Einstein\" year:1905", 10).await?;
    for paper in &results.papers {
        println!("{} ({}) — {} citations",
            paper.title,
            paper.year.unwrap_or(0),
            paper.citation_count.unwrap_or(0),
        );
    }
    Ok(())
}
```

### Query builder

```rust
use ads_client::{AdsClient, QueryBuilder};

let query = QueryBuilder::new()
    .first_author("Weinberg")
    .and()
    .title("cosmological constant")
    .and()
    .property("refereed")
    .build();
// → first_author:"Weinberg" AND title:"cosmological constant" AND property:refereed

let results = client.search(&query, 20).await?;
```

### Export BibTeX

```rust
let bibtex = client.export_bibtex(&["2023ApJ...123..456A", "1998AJ....116.1009R"]).await?;
println!("{}", bibtex);

// Other formats
use ads_client::ExportFormat;
let ris = client.export(&["2023ApJ...123..456A"], ExportFormat::Ris, None).await?;
```

### References and citations

```rust
let refs = client.references("2023ApJ...123..456A", 50).await?;
let cites = client.citations("2023ApJ...123..456A", 50).await?;
let similar = client.similar("2023ApJ...123..456A", 10).await?;
```

### Metrics

```rust
let metrics = client.metrics(&["2023ApJ...123..456A"]).await?;
if let Some(indicators) = &metrics.indicators {
    println!("h-index: {:?}", indicators.h);
}
```

### Custom base URL (for SciX or testing)

```rust
let client = AdsClient::new("my-token")
    .with_base_url("https://api.scixplorer.org/v1");
```

---

## ADS Query Syntax Quick Reference

| Pattern | Meaning |
|---------|---------|
| `author:"Einstein"` | Author search |
| `first_author:"Einstein"` | First author only |
| `title:"dark matter"` | Title words |
| `abs:"gravitational waves"` | Abstract words |
| `full:"spectroscopy"` | Full text |
| `year:2023` | Exact year |
| `year:[2020 TO 2023]` | Year range |
| `bibcode:2023ApJ...` | ADS bibcode |
| `doi:"10.1234/..."` | DOI |
| `identifier:arXiv:2301.12345` | arXiv ID |
| `bibstem:ApJ` | Journal abbreviation |
| `object:"M31"` | Astronomical object |
| `orcid:0000-0002-...` | ORCID identifier |
| `property:refereed` | Refereed papers |
| `property:openaccess` | Open access |
| `doctype:article` | Document type |

**Boolean operators:** `AND`, `OR`, `NOT`, parentheses for grouping
**Functional operators:** `citations(bibcode:X)`, `references(bibcode:X)`, `similar(bibcode:X)`, `trending(bibcode:X)`
**Wildcards:** `author:"Eins*"`, `title:galax?`

**Sort options:** `date desc` (default), `citation_count desc`, `score desc`, `read_count desc`

---

## Export Formats

| Format | Flag | Description |
|--------|------|-------------|
| `bibtex` | `--format bibtex` | BibTeX (default) |
| `bibtexabs` | `--format bibtexabs` | BibTeX with abstracts |
| `aastex` | `--format aastex` | AAS journals (ApJ, AJ, etc.) |
| `icarus` | `--format icarus` | Icarus journal |
| `mnras` | `--format mnras` | MNRAS journal |
| `soph` | `--format soph` | Solar Physics journal |
| `ris` | `--format ris` | RIS (Reference Manager) |
| `endnote` | `--format endnote` | EndNote |
| `medlars` | `--format medlars` | MEDLARS/PubMed |
| `ieee` | `--format ieee` | IEEE |
| `csl` | `--format csl` | CSL-JSON |
| `dcxml` | `--format dcxml` | Dublin Core XML |
| `refxml` | `--format refxml` | ADS Reference XML |
| `refabsxml` | `--format refabsxml` | ADS Ref + Abstract XML |
| `votable` | `--format votable` | VOTable |
| `rss` | `--format rss` | RSS feed |
| `custom` | `--format custom` | Custom format |

---

## Rate Limiting

The ADS API allows 5,000 requests/day and 5 requests/second. `ads-client` handles rate limiting automatically:

- A token-bucket rate limiter enforces 5 req/s locally
- ADS rate limit headers (`x-ratelimit-remaining`, `x-ratelimit-reset`) are respected
- If rate-limited (HTTP 429), the error includes the retry-after duration

---

## Architecture

```
┌─────────────────────────────────┐
│  ads binary                     │  ← Single binary, one install
│  ┌────────────┐ ┌────────────┐  │
│  │ CLI (clap) │ │ MCP server │  │  ads search … / ads serve
│  └────────────┘ └────────────┘  │
├─────────────────────────────────┤
│  ads_client library             │  ← Async Rust API
│  ┌──────────┐ ┌──────────────┐  │
│  │ AdsClient│ │ QueryBuilder │  │
│  └──────────┘ └──────────────┘  │
│  ┌──────────┐ ┌──────────────┐  │
│  │ Parser   │ │ Rate Limiter │  │
│  └──────────┘ └──────────────┘  │
├─────────────────────────────────┤
│  reqwest + tokio                │  ← HTTP + async runtime
└─────────────────────────────────┘
         │
         ▼
   ADS API (api.adsabs.harvard.edu/v1)
```

## License

MIT
